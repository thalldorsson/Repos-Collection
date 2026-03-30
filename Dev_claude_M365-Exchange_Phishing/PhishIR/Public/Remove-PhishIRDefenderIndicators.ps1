function Remove-PhishIRDefenderIndicators {
    <#
    .SYNOPSIS
    Remove URL/domain threat intelligence indicators from Microsoft Defender for Endpoint.

    .DESCRIPTION
    Deletes threat intelligence indicators (tiIndicators) from Microsoft Graph Security API to 
    remove URL/domain blocks, allow-lists, or warnings in Defender for Endpoint.
    
    Use cases:
    - Remove indicators for resolved threats
    - Clean up false positives
    - Rollback accidental block lists
    - Expire indicators before their automatic expiration date
    
    All deletions require explicit confirmation to prevent accidental removal of active security controls.

    .PARAMETER IndicatorId
    Array of indicator IDs to remove. Get indicator IDs via Get-PhishIRDefenderIndicators.

    .PARAMETER All
    Remove all URL/domain indicators (Block, Allow, Warn, Audit).
    Requires confirmation phrase. Use with extreme caution.

    .PARAMETER Action
    When used with -All, limit removal to specific action type (Block, Allow, Warn, Audit).
    Example: Remove all Allow-list indicators only.

    .PARAMETER RemovalConfirmation
    Required confirmation phrase: "CONFIRM: Remove URL block indicators approved by [Name]"
    Must be provided for all removal operations.

    .PARAMETER WhatIf
    Shows what would be removed without deleting indicators.

    .EXAMPLE
    Get-PhishIRDefenderIndicators -Action Block -ThreatType Phishing | Select-Object -First 5 | Remove-PhishIRDefenderIndicators -RemovalConfirmation "CONFIRM: Remove URL block indicators approved by John Doe" -WhatIf

    Preview removal of first 5 phishing block indicators without deleting.

    .EXAMPLE
    Remove-PhishIRDefenderIndicators -IndicatorId "abc123", "def456" -RemovalConfirmation "CONFIRM: Remove URL block indicators approved by SOC Lead"

    Remove specific indicators by ID.

    .EXAMPLE
    $expiredIndicators = Get-PhishIRDefenderIndicators -ShowExpired | Where-Object { [DateTime]::Parse($_.ExpirationDateTime) -lt (Get-Date).AddDays(-30) }
    $expiredIndicators | ForEach-Object { $_.Id } | Remove-PhishIRDefenderIndicators -RemovalConfirmation "CONFIRM: Remove URL block indicators approved by Admin"

    Remove indicators expired more than 30 days ago.

    .EXAMPLE
    Remove-PhishIRDefenderIndicators -All -Action Allow -RemovalConfirmation "CONFIRM: Remove URL block indicators approved by Security Manager" -WhatIf

    Preview removal of all allow-list indicators.

    .NOTES
    Requires:
    - Microsoft.Graph.Beta.Security module
    - Connect-MgGraph -Scopes "ThreatIndicators.ReadWrite.OwnedBy"
    
    Graph API endpoint: DELETE https://graph.microsoft.com/beta/security/tiIndicators/{id}
    
    Deletion is immediate but endpoint propagation may take up to 2 hours.
    Deleted indicators cannot be recovered; create new indicators if needed.

    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ById')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ById', ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('Id')]
        [string[]]$IndicatorId,

        [Parameter(Mandatory = $true, ParameterSetName = 'All')]
        [switch]$All,

        [Parameter(Mandatory = $false, ParameterSetName = 'All')]
        [ValidateSet('Block', 'Allow', 'Warn', 'Audit')]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [string]$RemovalConfirmation
    )

    begin {
        $ErrorActionPreference = 'Stop'
        $results = @{
            IndicatorsRemoved = @()
            Errors            = @()
        }

        # Safety check: require confirmation phrase
        if (-not $RemovalConfirmation -or $RemovalConfirmation -notmatch '^CONFIRM:\s+Remove URL block indicators approved by\s+.+$') {
            throw "Removal requires -RemovalConfirmation parameter with format: 'CONFIRM: Remove URL block indicators approved by [Name]'"
        }
        Write-PhishIRLog -Message "Indicator removal confirmed: $RemovalConfirmation" -Level Warning

        # Check Microsoft Graph connection
        try {
            $context = Get-MgContext -ErrorAction Stop
            if (-not $context) {
                throw "Not connected to Microsoft Graph"
            }
            
            # Verify required permission
            $requiredScope = "ThreatIndicators.ReadWrite.OwnedBy"
            if ($context.Scopes -notcontains $requiredScope) {
                Write-Warning "Missing required Graph permission: $requiredScope"
                Write-Warning "Run: Connect-MgGraph -Scopes 'ThreatIndicators.ReadWrite.OwnedBy'"
                throw "Missing Graph API permission: $requiredScope"
            }
            
            Write-PhishIRLog -Message "Microsoft Graph connection verified (ThreatIndicators.ReadWrite.OwnedBy)" -Level Info
        }
        catch {
            Write-Warning "Not connected to Microsoft Graph or missing permissions"
            Write-Warning "Run: Connect-MgGraph -Scopes 'ThreatIndicators.ReadWrite.OwnedBy'"
            throw "Microsoft Graph connection required with ThreatIndicators.ReadWrite.OwnedBy permission"
        }

        # If -All is specified, retrieve all indicators matching criteria
        if ($PSCmdlet.ParameterSetName -eq 'All') {
            Write-PhishIRLog -Message "Retrieving all URL/domain indicators for removal" -Level Warning
            
            $getParams = @{
                IndicatorType = 'All'
            }
            
            if ($Action) {
                $getParams.Action = $Action
                Write-PhishIRLog -Message "Filtering to Action=$Action only" -Level Info
            }
            
            $allIndicators = Get-PhishIRDefenderIndicators @getParams
            
            if (-not $allIndicators -or $allIndicators.Count -eq 0) {
                Write-Warning "No indicators found matching criteria"
                return $results
            }
            
            $IndicatorId = $allIndicators | ForEach-Object { $_.Id }
            Write-PhishIRLog -Message "Found $($IndicatorId.Count) indicator(s) to remove" -Level Warning
        }

        Write-PhishIRLog -Message "Preparing to remove $($IndicatorId.Count) indicator(s)" -Level Warning
    }

    process {
        try {
            foreach ($id in $IndicatorId) {
                # Retrieve indicator details before deletion (for logging/WhatIf)
                try {
                    $uri = "https://graph.microsoft.com/beta/security/tiIndicators/$id"
                    $indicator = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
                    
                    $indicatorValue = if ($indicator.url) { $indicator.url }
                                     elseif ($indicator.domainName) { $indicator.domainName }
                                     elseif ($indicator.networkIPv4) { $indicator.networkIPv4 }
                                     elseif ($indicator.networkIPv6) { $indicator.networkIPv6 }
                                     else { 'Unknown' }
                    
                    $indicatorType = if ($indicator.url) { 'URL' }
                                    elseif ($indicator.domainName) { 'Domain' }
                                    elseif ($indicator.networkIPv4 -or $indicator.networkIPv6) { 'IP' }
                                    else { 'Other' }
                }
                catch {
                    Write-Warning "Indicator not found or inaccessible: $id"
                    $results.Errors += "Indicator not found: $id"
                    continue
                }

                # WhatIf preview
                if ($WhatIfPreference) {
                    Write-Host "`n[WhatIf] Would remove indicator:" -ForegroundColor Cyan
                    Write-Host "  ID: $id" -ForegroundColor Yellow
                    Write-Host "  Type: $indicatorType" -ForegroundColor Gray
                    Write-Host "  Value: $indicatorValue" -ForegroundColor Gray
                    Write-Host "  Action: $($indicator.action)" -ForegroundColor Gray
                    Write-Host "  ThreatType: $($indicator.threatType)" -ForegroundColor Gray
                    Write-Host "  Description: $($indicator.description)" -ForegroundColor Gray
                    continue
                }

                # Delete indicator
                if ($PSCmdlet.ShouldProcess("$indicatorType indicator $indicatorValue (ID: $id)", "Remove from Defender")) {
                    try {
                        $deleteUri = "https://graph.microsoft.com/beta/security/tiIndicators/$id"
                        Invoke-MgGraphRequest -Method DELETE -Uri $deleteUri -ErrorAction Stop
                        
                        $results.IndicatorsRemoved += [PSCustomObject]@{
                            Id          = $id
                            Type        = $indicatorType
                            Value       = $indicatorValue
                            Action      = $indicator.action
                            ThreatType  = $indicator.threatType
                            Description = $indicator.description
                            RemovedAt   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                        }
                        
                        Write-PhishIRLog -Message "Removed indicator: $indicatorValue (ID: $id)" -Level Success
                        Write-Host "✅ Removed $indicatorType indicator: $indicatorValue" -ForegroundColor Green
                    }
                    catch {
                        $errMsg = $_.Exception.Message
                        $results.Errors += "Failed to remove indicator ${id}: $errMsg"
                        Write-PhishIRLog -Message "Failed to remove indicator ${id}: $errMsg" -Level Error
                        Write-Warning "Failed to remove indicator $id : $errMsg"
                    }
                }
            }
        }
        catch {
            $results.Errors += $_.Exception.Message
            Write-PhishIRLog -Message "Error in Remove-PhishIRDefenderIndicators: $_" -Level Error
            throw
        }
    }

    end {
        if ($WhatIfPreference) {
            Write-Host "`n=== WhatIf Summary ===" -ForegroundColor Cyan
            Write-Host "Would remove $($IndicatorId.Count) indicator(s)" -ForegroundColor Yellow
            Write-Host "No changes made" -ForegroundColor Green
            return $results
        }

        Write-Host "`n=== Indicator Removal Summary ===" -ForegroundColor Green
        Write-Host "Total indicators processed: $($IndicatorId.Count)"
        Write-Host "Successfully removed: $($results.IndicatorsRemoved.Count)"
        Write-Host "Errors: $($results.Errors.Count)"
        
        if ($results.IndicatorsRemoved.Count -gt 0) {
            Write-Host "`nRemoved indicators:" -ForegroundColor Cyan
            $results.IndicatorsRemoved | Format-Table -Property Type, Value, Action, ThreatType, RemovedAt -AutoSize
        }
        
        if ($results.Errors.Count -gt 0) {
            Write-Host "`nErrors:" -ForegroundColor Red
            $results.Errors | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        }
        
        Write-Host "`n=== Important Notes ===" -ForegroundColor Yellow
        Write-Host "• Deletion is immediate but endpoint propagation may take up to 2 hours"
        Write-Host "• Deleted indicators cannot be recovered"
        Write-Host "• Create new indicators if removal was accidental"
        Write-Host "• Verify removal in Defender portal: Settings > Endpoints > Indicators"

        return $results
    }
}
