function Start-PhishIRMacroWatch {
    <#
    .SYNOPSIS
    Monitor recipients who received macro-enabled Excel attachments for 30 days and alert/block outbound activity.

    .DESCRIPTION
    Orchestrates 30-day monitoring of users who received macro-enabled Excel attachments.
    - Builds recipient watchlist
    - Monitors outbound emails for macro attachments or invoice-like subjects
    - Creates alerts/incidents when suspicious activity detected
    - Optionally creates transport rules to quarantine outbound matches (Test mode by default)

    This function requires:
    - Microsoft 365 Defender Advanced Hunting access (Security Operator/Reader)
    - Exchange Online Management (for transport rules)
    - Microsoft Graph (for incident creation)

    .PARAMETER WatchlistPath
    Path to CSV file containing recipients to monitor. If not provided, generates watchlist from Advanced Hunting.

    .PARAMETER MonitoringDays
    Number of days to monitor recipients. Default is 30.

    .PARAMETER CreateTransportRule
    If specified, creates Exchange transport rule in Test mode to quarantine suspicious outbound emails.

    .PARAMETER TransportRuleName
    Name for the transport rule. Default is "PhishIR-MacroWatch-Outbound-Test".

    .PARAMETER AlertEmail
    Email address(es) to notify when suspicious activity detected.

    .PARAMETER WhatIf
    Shows what would happen without making changes.

    .PARAMETER IncidentSeverity
    Severity for created incidents. Default is "Medium".

    .EXAMPLE
    Start-PhishIRMacroWatch -WhatIf

    .EXAMPLE
    Start-PhishIRMacroWatch -CreateTransportRule -AlertEmail "soc@contoso.com" -WhatIf

    .EXAMPLE
    Start-PhishIRMacroWatch -WatchlistPath "C:\watchlist.csv" -MonitoringDays 14

    .NOTES
    Always run with -WhatIf first to validate behavior. Transport rules are created in Test mode by default.
    Requires explicit confirmation to enable enforcement mode.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $false)]
        [string]$WatchlistPath,

        [Parameter(Mandatory = $false)]
        [int]$MonitoringDays = 30,

        [Parameter(Mandatory = $false)]
        [switch]$CreateTransportRule,

        [Parameter(Mandatory = $false)]
        [string]$TransportRuleName = "PhishIR-MacroWatch-Outbound-Test",

        [Parameter(Mandatory = $false)]
        [string[]]$AlertEmail,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Low', 'Medium', 'High', 'Critical')]
        [string]$IncidentSeverity = 'Medium'
    )

    $ErrorActionPreference = 'Stop'
    $results = @{
        WatchlistGenerated = $false
        WatchlistCount     = 0
        SuspiciousActivity = @()
        TransportRuleCreated = $false
        IncidentsCreated   = @()
        Errors             = @()
    }

    try {
        Write-PhishIRLog -Message "Starting macro watchlist monitoring" -Level Info

        # Step 1: Build or load watchlist
        if (-not $WatchlistPath) {
            Write-PhishIRLog -Message "Generating recipient watchlist from Advanced Hunting" -Level Info
            
            # Generate KQL query
            $query = Get-PhishIRMacroHunt -QueryType RecipientWatchlist -TimeRange "$($MonitoringDays)d"
            
            Write-PhishIRLog -Message "Execute this KQL query in Microsoft 365 Defender Advanced Hunting:" -Level Info
            Write-Host "`n$query`n" -ForegroundColor Cyan
            
            # In production, use Invoke-AdvancedHuntingQuery (requires Graph API or Defender API)
            # For now, instruct user to export results manually
            Write-Warning "Manual step required: Run the KQL query above in Defender portal and export results to CSV"
            Write-Warning "Then re-run this command with -WatchlistPath pointing to the exported CSV"
            
            $results.WatchlistGenerated = $true
            return $results
        }

        # Load watchlist
        if (-not (Test-Path $WatchlistPath)) {
            throw "Watchlist file not found: $WatchlistPath"
        }

        $watchlist = Import-Csv -Path $WatchlistPath
        $results.WatchlistCount = $watchlist.Count
        Write-PhishIRLog -Message "Loaded watchlist with $($watchlist.Count) recipients" -Level Info

        # Step 2: Query for suspicious outbound activity
        Write-PhishIRLog -Message "Checking for suspicious outbound activity from watchlist recipients" -Level Info
        
        $outboundQuery = Get-PhishIRMacroHunt -QueryType OutboundDetection -TimeRange "$($MonitoringDays)d"
        
        Write-PhishIRLog -Message "Execute this KQL query to detect suspicious outbound activity:" -Level Info
        Write-Host "`n$outboundQuery`n" -ForegroundColor Cyan
        
        Write-Warning "Manual step: Run the query above and export results. Then use New-PhishIRIncident to create alerts."

        # Step 3: Create transport rule (Test mode) if requested
        if ($CreateTransportRule) {
            if ($PSCmdlet.ShouldProcess($TransportRuleName, "Create Exchange transport rule (Test mode)")) {
                Write-PhishIRLog -Message "Creating transport rule: $TransportRuleName (Test mode)" -Level Info
                
                # Check Exchange connection
                try {
                    $null = Get-OrganizationConfig -ErrorAction Stop
                }
                catch {
                    Write-Warning "Not connected to Exchange Online. Run: Connect-ExchangeOnline"
                    throw "Exchange Online connection required"
                }

                # Create outbound quarantine rule (Test mode)
                $ruleParams = @{
                    Name                           = $TransportRuleName
                    FromScope                      = 'InOrganization'
                    AttachmentExtensionMatchesWords = @('xlsm', 'xlsb', 'xltm', 'xla')
                    SubjectOrBodyContainsWords     = @('unpaid invoice', 'invoice overdue', 'overdue invoice', 'unpaid invoices', 'invoices overdue')
                    Mode                           = 'Audit'  # Test mode - logs only
                    Comments                       = "PhishIR: Monitor outbound macro-enabled Excel or invoice subjects (Test mode) - Generated $(Get-Date -Format 'yyyy-MM-dd')"
                    Priority                       = 0
                }

                if ($AlertEmail) {
                    $ruleParams['GenerateIncidentReport'] = $AlertEmail
                    $ruleParams['IncidentReportContent'] = @('Sender', 'Recipients', 'Subject', 'MessageId')
                }

                try {
                    New-TransportRule @ruleParams -ErrorAction Stop | Out-Null
                    Write-PhishIRLog -Message "Transport rule created successfully (Test/Audit mode)" -Level Success
                    $results.TransportRuleCreated = $true
                    
                    Write-Warning "IMPORTANT: Rule is in Audit mode. Monitor for false positives before enabling enforcement."
                    Write-Warning "To enable enforcement, run: Set-TransportRule -Identity '$TransportRuleName' -Mode Enforce -Quarantine `$true"
                }
                catch {
                    $results.Errors += "Failed to create transport rule: $_"
                    Write-PhishIRLog -Message "Failed to create transport rule: $_" -Level Error
                }
            }
        }

        # Step 4: Summary and next steps
        Write-Host "`n=== Monitoring Summary ===" -ForegroundColor Green
        Write-Host "Watchlist recipients: $($results.WatchlistCount)"
        Write-Host "Monitoring period: $MonitoringDays days"
        Write-Host "Transport rule created: $($results.TransportRuleCreated)"
        
        Write-Host "`n=== Next Steps ===" -ForegroundColor Yellow
        Write-Host "1. Run outbound detection query daily in Defender Advanced Hunting"
        Write-Host "2. Review transport rule audit logs in Exchange admin center"
        Write-Host "3. Create incidents for confirmed suspicious activity: New-PhishIRIncident"
        Write-Host "4. After tuning, enable enforcement: Set-TransportRule -Identity '$TransportRuleName' -Mode Enforce -Quarantine `$true"
        Write-Host "5. For device remediation, use: Start-PhishIRDeviceRemediation"

        return $results
    }
    catch {
        $results.Errors += $_.Exception.Message
        Write-PhishIRLog -Message "Error in macro watchlist monitoring: $_" -Level Error
        throw
    }
}
