function Invoke-PhishIRQuarantine {
    <#
    .SYNOPSIS
    Quarantine incoming and outgoing emails matching macro/invoice criteria and alert IT.

    .DESCRIPTION
    Safe quarantine orchestration for emails containing:
    - Macro-enabled Excel attachments (.xlsm, .xlsb, .xltm, .xla)
    - Invoice-like subjects ("unpaid invoice", "invoice overdue", etc.)

    Supports:
    - Creating Exchange transport rules (inbound/outbound) in Test/Audit mode
    - Quarantining specific messages via Compliance Search (requires approval)
    - Alerting IT via email or incident creation
    - WhatIf reporting before enforcement

    Always starts in Test/Audit mode. Requires explicit confirmation for enforcement.

    .PARAMETER Scope
    Scope of quarantine action. Valid values:
    - InboundRule: Create transport rule for inbound emails
    - OutboundRule: Create transport rule for outbound emails
    - BothRules: Create both inbound and outbound rules
    - SpecificMessages: Quarantine specific messages by NetworkMessageId (requires MessageIds parameter)

    .PARAMETER MessageIds
    Array of NetworkMessageIds to quarantine. Required when Scope is "SpecificMessages".

    .PARAMETER RuleMode
    Transport rule mode. Valid values:
    - Audit: Log matches only (default, safe)
    - Test: Test with notifications
    - Enforce: Active quarantine (requires confirmation)

    .PARAMETER AlertEmail
    Email address(es) to notify when messages match rules.

    .PARAMETER RulePrefix
    Prefix for created transport rule names. Default is "PhishIR-Quarantine".

    .PARAMETER QuarantineConfirmation
    Required confirmation phrase for enforcement mode: "CONFIRM: Quarantine approved by [Name]"

    .PARAMETER WhatIf
    Shows what would happen without making changes.

    .EXAMPLE
    Invoke-PhishIRQuarantine -Scope BothRules -RuleMode Audit -AlertEmail "soc@contoso.com" -WhatIf

    .EXAMPLE
    Invoke-PhishIRQuarantine -Scope InboundRule -RuleMode Test -AlertEmail "soc@contoso.com"

    .EXAMPLE
    $msgIds = @("message-id-1", "message-id-2")
    Invoke-PhishIRQuarantine -Scope SpecificMessages -MessageIds $msgIds -QuarantineConfirmation "CONFIRM: Quarantine approved by John Doe"

    .NOTES
    Always run with -WhatIf first. Enforcement mode requires QuarantineConfirmation parameter.
    For Compliance Search quarantine, requires eDiscovery Manager role and legal approval.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('InboundRule', 'OutboundRule', 'BothRules', 'SpecificMessages')]
        [string]$Scope,

        [Parameter(Mandatory = $false)]
        [string[]]$MessageIds,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Audit', 'Test', 'Enforce')]
        [string]$RuleMode = 'Audit',

        [Parameter(Mandatory = $false)]
        [string[]]$AlertEmail,

        [Parameter(Mandatory = $false)]
        [string]$RulePrefix = "PhishIR-Quarantine",

        [Parameter(Mandatory = $false)]
        [string]$QuarantineConfirmation
    )

    $ErrorActionPreference = 'Stop'
    $results = @{
        RulesCreated      = @()
        MessagesPurged    = 0
        IncidentsCreated  = @()
        AlertsSent        = @()
        Errors            = @()
    }

    try {
        Write-PhishIRLog -Message "Starting quarantine operation - Scope: $Scope, Mode: $RuleMode" -Level Info

        # Safety check for enforcement mode
        if ($RuleMode -eq 'Enforce') {
            if (-not $QuarantineConfirmation -or $QuarantineConfirmation -notmatch '^CONFIRM:\s+Quarantine approved by\s+.+$') {
                throw "Enforcement mode requires QuarantineConfirmation parameter with format: 'CONFIRM: Quarantine approved by [Name]'"
            }
            Write-PhishIRLog -Message "Enforcement mode confirmed: $QuarantineConfirmation" -Level Warning
        }

        # Check Exchange connection
        try {
            $null = Get-OrganizationConfig -ErrorAction Stop
            Write-PhishIRLog -Message "Exchange Online connection verified" -Level Info
        }
        catch {
            Write-Warning "Not connected to Exchange Online. Run: Connect-ExchangeOnline"
            throw "Exchange Online connection required"
        }

        # Define common criteria
        $macroExtensions = @('xlsm', 'xlsb', 'xltm', 'xla')
        $invoiceKeywords = @('unpaid invoice', 'invoice overdue', 'overdue invoice', 'unpaid invoices', 'invoices overdue')

        # Create transport rules
        if ($Scope -in @('InboundRule', 'OutboundRule', 'BothRules')) {
            
            # Inbound rule
            if ($Scope -in @('InboundRule', 'BothRules')) {
                $inboundRuleName = "$RulePrefix-Inbound-$RuleMode"
                
                if ($PSCmdlet.ShouldProcess($inboundRuleName, "Create inbound quarantine rule (Mode: $RuleMode)")) {
                    Write-PhishIRLog -Message "Creating inbound transport rule: $inboundRuleName" -Level Info
                    
                    $inboundParams = @{
                        Name                           = $inboundRuleName
                        FromScope                      = 'NotInOrganization'
                        AttachmentExtensionMatchesWords = $macroExtensions
                        SubjectOrBodyContainsWords     = $invoiceKeywords
                        Mode                           = $RuleMode
                        Comments                       = "PhishIR: Quarantine inbound macro Excel or invoice subjects - Created $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
                        Priority                       = 0
                    }

                    if ($RuleMode -eq 'Enforce') {
                        $inboundParams['Quarantine'] = $true
                    }

                    if ($AlertEmail) {
                        $inboundParams['GenerateIncidentReport'] = $AlertEmail
                        $inboundParams['IncidentReportContent'] = @('Sender', 'Recipients', 'Subject', 'MessageId', 'AttachmentNames')
                    }

                    try {
                        # Check if rule exists
                        $existingRule = Get-TransportRule -Identity $inboundRuleName -ErrorAction SilentlyContinue
                        if ($existingRule) {
                            Write-Warning "Rule '$inboundRuleName' already exists. Updating..."
                            Set-TransportRule -Identity $inboundRuleName @inboundParams -ErrorAction Stop
                        }
                        else {
                            New-TransportRule @inboundParams -ErrorAction Stop | Out-Null
                        }
                        
                        Write-PhishIRLog -Message "Inbound rule created/updated successfully (Mode: $RuleMode)" -Level Success
                        $results.RulesCreated += $inboundRuleName
                    }
                    catch {
                        $results.Errors += "Failed to create inbound rule: $_"
                        Write-PhishIRLog -Message "Failed to create inbound rule: $_" -Level Error
                    }
                }
            }

            # Outbound rule
            if ($Scope -in @('OutboundRule', 'BothRules')) {
                $outboundRuleName = "$RulePrefix-Outbound-$RuleMode"
                
                if ($PSCmdlet.ShouldProcess($outboundRuleName, "Create outbound quarantine rule (Mode: $RuleMode)")) {
                    Write-PhishIRLog -Message "Creating outbound transport rule: $outboundRuleName" -Level Info
                    
                    $outboundParams = @{
                        Name                           = $outboundRuleName
                        FromScope                      = 'InOrganization'
                        AttachmentExtensionMatchesWords = $macroExtensions
                        SubjectOrBodyContainsWords     = $invoiceKeywords
                        Mode                           = $RuleMode
                        Comments                       = "PhishIR: Quarantine outbound macro Excel or invoice subjects - Created $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
                        Priority                       = 0
                    }

                    if ($RuleMode -eq 'Enforce') {
                        $outboundParams['Quarantine'] = $true
                    }

                    if ($AlertEmail) {
                        $outboundParams['GenerateIncidentReport'] = $AlertEmail
                        $outboundParams['IncidentReportContent'] = @('Sender', 'Recipients', 'Subject', 'MessageId', 'AttachmentNames')
                    }

                    try {
                        $existingRule = Get-TransportRule -Identity $outboundRuleName -ErrorAction SilentlyContinue
                        if ($existingRule) {
                            Write-Warning "Rule '$outboundRuleName' already exists. Updating..."
                            Set-TransportRule -Identity $outboundRuleName @outboundParams -ErrorAction Stop
                        }
                        else {
                            New-TransportRule @outboundParams -ErrorAction Stop | Out-Null
                        }
                        
                        Write-PhishIRLog -Message "Outbound rule created/updated successfully (Mode: $RuleMode)" -Level Success
                        $results.RulesCreated += $outboundRuleName
                    }
                    catch {
                        $results.Errors += "Failed to create outbound rule: $_"
                        Write-PhishIRLog -Message "Failed to create outbound rule: $_" -Level Error
                    }
                }
            }
        }

        # Quarantine specific messages via Compliance Search
        if ($Scope -eq 'SpecificMessages') {
            if (-not $MessageIds -or $MessageIds.Count -eq 0) {
                throw "MessageIds parameter required when Scope is 'SpecificMessages'"
            }

            if (-not $QuarantineConfirmation -or $QuarantineConfirmation -notmatch '^CONFIRM:\s+Quarantine approved by\s+.+$') {
                throw "Specific message quarantine requires QuarantineConfirmation parameter with format: 'CONFIRM: Quarantine approved by [Name]'"
            }

            Write-PhishIRLog -Message "Quarantining $($MessageIds.Count) specific messages" -Level Warning
            
            # Use Invoke-MailPurge from PhishIR module
            if ($PSCmdlet.ShouldProcess("$($MessageIds.Count) messages", "Quarantine via Compliance Search")) {
                try {
                    $purgeParams = @{
                        Sender                   = '*'
                        Subject                  = '*'
                        MessageIds               = $MessageIds
                        Action                   = 'SoftDelete'  # Moves to Recoverable Items (safe)
                        HardDeleteConfirmation   = $QuarantineConfirmation
                        SearchName               = "PhishIR-Quarantine-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
                    }

                    $purgeResult = Invoke-MailPurge @purgeParams
                    $results.MessagesPurged = $MessageIds.Count
                    Write-PhishIRLog -Message "Messages moved to Recoverable Items (quarantine)" -Level Success
                }
                catch {
                    $results.Errors += "Failed to quarantine messages: $_"
                    Write-PhishIRLog -Message "Failed to quarantine messages: $_" -Level Error
                }
            }
        }

        # Send alerts if configured
        if ($AlertEmail -and $results.RulesCreated.Count -gt 0) {
            Write-PhishIRLog -Message "Alert notifications will be sent to: $($AlertEmail -join ', ')" -Level Info
            $results.AlertsSent += $AlertEmail
        }

        # Summary
        Write-Host "`n=== Quarantine Operation Summary ===" -ForegroundColor Green
        Write-Host "Scope: $Scope"
        Write-Host "Mode: $RuleMode"
        Write-Host "Rules created/updated: $($results.RulesCreated.Count)"
        if ($results.RulesCreated.Count -gt 0) {
            $results.RulesCreated | ForEach-Object { Write-Host "  - $_" }
        }
        Write-Host "Messages quarantined: $($results.MessagesPurged)"
        
        if ($RuleMode -ne 'Enforce') {
            Write-Host "`n=== Next Steps ===" -ForegroundColor Yellow
            Write-Host "1. Monitor rule hits in Exchange admin center (Mail flow > Rules > View rule reports)"
            Write-Host "2. Review false positives and tune rule criteria"
            Write-Host "3. To enable enforcement, re-run with: -RuleMode Enforce -QuarantineConfirmation 'CONFIRM: Quarantine approved by [Name]'"
            Write-Host "4. Check quarantined messages: Security & Compliance Center > Quarantine"
        }
        else {
            Write-Host "`nENFORCEMENT MODE ACTIVE - Rules are quarantining matched messages" -ForegroundColor Red
        }

        return $results
    }
    catch {
        $results.Errors += $_.Exception.Message
        Write-PhishIRLog -Message "Error in quarantine operation: $_" -Level Error
        throw
    }
}
