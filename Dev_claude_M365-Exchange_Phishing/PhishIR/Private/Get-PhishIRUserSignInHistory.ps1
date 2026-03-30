function Get-PhishIRUserSignInHistory {
    <#
    .SYNOPSIS
    Retrieve Microsoft Entra ID sign-in logs for users who received phishing emails.

    .DESCRIPTION
    Queries Microsoft Graph API to retrieve sign-in activity for specified users, typically
    those who received Excel attachments with malicious hyperlinks. Helps identify if
    compromised credentials were used post-phishing attempt.

    This function is designed for phishing incident response workflows where tracking
    user authentication activity is critical for detecting account compromise.

    Prerequisites:
    - Microsoft Graph PowerShell SDK (Connect-MgGraph)
    - Required Graph Scopes: AuditLog.Read.All, Directory.Read.All
    - User must have appropriate role (Security Reader or Global Reader minimum)

    .PARAMETER UserPrincipalNames
    Array of user email addresses (UPNs) to query sign-in history for.
    Typically extracted from EmailEvents or provided from incident response workflow.

    .PARAMETER DaysBack
    Number of days to look back for sign-in activity (default: 7 days, max: 30 days).
    Graph API retention for sign-in logs is typically 30 days.

    .PARAMETER IncludeRiskySignIns
    Include only risky sign-ins (based on Microsoft Entra ID Protection risk detections).

    .PARAMETER IncludeFailures
    Include failed sign-in attempts in addition to successful authentications.

    .PARAMETER ExportCsv
    Export results to CSV file for evidence collection or SIEM ingestion.

    .EXAMPLE
    $recipients = @("user1@contoso.com", "user2@contoso.com")
    Get-PhishIRUserSignInHistory -UserPrincipalNames $recipients -DaysBack 14

    Retrieve 14 days of sign-in history for specified users.

    Output:
    UserPrincipalName    : user1@contoso.com
    CreatedDateTime      : 2025-11-19T08:15:22Z
    AppDisplayName       : Office 365 Exchange Online
    IPAddress            : 203.0.113.45
    Location             : Seattle, Washington, US
    ClientAppUsed        : Browser
    Status               : Success
    RiskLevelAggregated  : none
    DeviceDetail         : Windows 11, Chrome 119

    .EXAMPLE
    # Check sign-ins after phishing email was delivered
    $phishDelivery = Get-Date "2025-11-19T10:00:00Z"
    Get-PhishIRUserSignInHistory -UserPrincipalNames @("cfo@contoso.com") -DaysBack 1 |
        Where-Object { $_.CreatedDateTime -gt $phishDelivery } |
        Format-Table UserPrincipalName, CreatedDateTime, IPAddress, Location, Status

    .EXAMPLE
    # Export risky sign-ins to CSV for evidence
    Get-PhishIRUserSignInHistory -UserPrincipalNames $targetUsers -IncludeRiskySignIns -ExportCsv ".\risky-signins.csv"

    .EXAMPLE
    # Integrated workflow: Extract recipients from email hunt, check their sign-ins
    $kqlQuery = @"
    EmailEvents
    | where Subject contains "Invoice"
    | where AttachmentCount > 0
    | where FileName endswith ".xlsx"
    | distinct RecipientEmailAddress
"@
    $recipients = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/security/runHuntingQuery" -Body @{ Query = $kqlQuery }
    $upns = $recipients.Results | Select-Object -ExpandProperty RecipientEmailAddress
    Get-PhishIRUserSignInHistory -UserPrincipalNames $upns -DaysBack 7 -ExportCsv ".\phishing-campaign-signins.csv"

    .NOTES
    Graph API Limits:
    - Sign-in logs retained for 30 days
    - Rate limits: 1000 requests/hour per app per tenant
    - Use -Filter for large result sets to avoid pagination issues

    Risk Detection Types:
    - unfamiliarFeatures: Unusual location/device/IP
    - anonymizedIPAddress: Anonymous IP (Tor, VPN, proxy)
    - maliciousIPAddress: Known malicious IP
    - atypicalTravel: Impossible travel between locations
    - malwareInfectedDeviceSignIn: Malware on device
    - suspiciousInbox: Suspicious inbox rules detected

    Security Considerations:
    - Requires privileged access (Security Reader role minimum)
    - Log all queries for audit trail
    - PII data - handle per compliance requirements (GDPR, etc.)
    - Redact IP addresses in reports if required

    .LINK
    Add-PhishIRIncidentRecord
    Get-PhishIRExcelHyperlinks
    Get-PhishIRMacroHunt
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias('UPN', 'UserEmail', 'EmailAddress')]
        [string[]]$UserPrincipalNames,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 30)]
        [int]$DaysBack = 7,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeRiskySignIns,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeFailures,

        [Parameter(Mandatory = $false)]
        [string]$ExportCsv,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 100)]
        [int]$BatchSize = 10
    )

    begin {
        # Verify Graph connection
        try {
            $context = Get-MgContext -ErrorAction Stop
            if (-not $context) {
                throw "Not connected to Microsoft Graph. Run Connect-MgGraph first."
            }

            # Check required scopes
            $requiredScopes = @('AuditLog.Read.All', 'Directory.Read.All')
            $hasScopes = $requiredScopes | Where-Object { $context.Scopes -contains $_ }
            if ($hasScopes.Count -ne $requiredScopes.Count) {
                Write-Warning "Missing required scopes. Connect with: Connect-MgGraph -Scopes 'AuditLog.Read.All','Directory.Read.All'"
            }
        }
        catch {
            throw "Microsoft Graph connection required. Install module: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser"
        }

        # Load batch size from config if not explicitly provided
        if ($PSBoundParameters.ContainsKey('BatchSize') -eq $false) {
            try {
                $config = Get-PhishIRConfig -Section 'SignInTracking'
                if ($config -and $config.BatchSize) {
                    $BatchSize = $config.BatchSize
                }
            } catch {
                # Fallback to default if config unavailable
                $BatchSize = 10
            }
        }

        $allResults = @()
        $allUsers = @()
        $startDate = (Get-Date).AddDays(-$DaysBack).ToString('yyyy-MM-ddTHH:mm:ssZ')
        
        Write-Verbose "Querying sign-ins from $startDate onwards"
        Write-Verbose "Batch size: $BatchSize users per request"
    }

    process {
        # Collect all users from pipeline
        $allUsers += $UserPrincipalNames
    }

    end {
        if ($allUsers.Count -eq 0) {
            Write-Warning "No users provided for sign-in query"
            return
        }

        Write-Verbose "Processing $($allUsers.Count) total user(s) in batches of $BatchSize"

        # Split users into batches
        $batches = @()
        for ($i = 0; $i -lt $allUsers.Count; $i += $BatchSize) {
            $endIndex = [Math]::Min($i + $BatchSize - 1, $allUsers.Count - 1)
            $batches += ,@($allUsers[$i..$endIndex])
        }

        Write-Verbose "Created $($batches.Count) batch(es)"

        # Process each batch
        foreach ($batch in $batches) {
            Write-Verbose "Processing batch of $($batch.Count) user(s)"

            try {
                # Build batch filter (OR query for all users in batch)
                $userFilters = $batch | ForEach-Object { "userPrincipalName eq '$_'" }
                $filter = "(" + ($userFilters -join ' or ') + ") and createdDateTime ge $startDate"

                if ($IncludeRiskySignIns) {
                    $filter += " and riskLevelAggregated ne 'none'"
                }

                if (-not $IncludeFailures) {
                    $filter += " and status/errorCode eq 0"
                }

                Write-Verbose "Batch filter: $filter"

                # Query sign-in logs via Graph API (single call for entire batch)
                $signIns = Get-MgAuditLogSignIn -Filter $filter -Top 1000 -All -ErrorAction Stop

                foreach ($signIn in $signIns) {
                    $result = [PSCustomObject]@{
                        UserPrincipalName       = $signIn.UserPrincipalName
                        CreatedDateTime         = $signIn.CreatedDateTime
                        AppDisplayName          = $signIn.AppDisplayName
                        IPAddress               = $signIn.IPAddress
                        Location                = "$($signIn.Location.City), $($signIn.Location.State), $($signIn.Location.CountryOrRegion)"
                        ClientAppUsed           = $signIn.ClientAppUsed
                        Status                  = if ($signIn.Status.ErrorCode -eq 0) { 'Success' } else { "Failed ($($signIn.Status.ErrorCode))" }
                        FailureReason           = $signIn.Status.FailureReason
                        RiskLevelAggregated     = $signIn.RiskLevelAggregated
                        RiskState               = $signIn.RiskState
                        RiskDetail              = $signIn.RiskDetail
                        DeviceOS                = $signIn.DeviceDetail.OperatingSystem
                        DeviceBrowser           = $signIn.DeviceDetail.Browser
                        IsCompliant             = $signIn.DeviceDetail.IsCompliant
                        IsManaged               = $signIn.DeviceDetail.IsManaged
                        ConditionalAccessStatus = $signIn.ConditionalAccessStatus
                        AuthenticationMethods   = ($signIn.AuthenticationDetails | ForEach-Object { $_.AuthenticationMethod }) -join ', '
                    }

                    $allResults += $result
                    
                    # Highlight suspicious activity
                    if ($result.RiskLevelAggregated -ne 'none') {
                        Write-Warning "⚠ Risky sign-in detected: $($result.UserPrincipalName) from $($result.IPAddress) at $($result.CreatedDateTime)"
                    }
                }

                Write-Verbose "Retrieved $($signIns.Count) sign-in(s) from batch of $($batch.Count) user(s)"
                
                # Rate limiting between batches
                if ($batches.IndexOf($batch) -lt ($batches.Count - 1)) {
                    Start-Sleep -Milliseconds 500
                }
            }
            catch {
                Write-Warning "Failed to retrieve sign-ins for batch: $($_.Exception.Message)"
                Write-Verbose "Batch users: $($batch -join ', ')"
            }
        }

        if ($allResults.Count -eq 0) {
            Write-Warning "No sign-in records found for specified users in the last $DaysBack days"
            return
        }

        Write-Host "`n✓ Retrieved $($allResults.Count) sign-in record(s) across $($allUsers.Count) user(s)" -ForegroundColor Green

        # Summary statistics
        $riskyCount = ($allResults | Where-Object { $_.RiskLevelAggregated -ne 'none' }).Count
        $failedCount = ($allResults | Where-Object { $_.Status -ne 'Success' }).Count

        if ($riskyCount -gt 0) {
            Write-Host "⚠ Found $riskyCount risky sign-in(s)" -ForegroundColor Yellow
        }
        if ($failedCount -gt 0) {
            Write-Host "ℹ Found $failedCount failed sign-in attempt(s)" -ForegroundColor Cyan
        }

        # Export to CSV if requested
        if ($ExportCsv) {
            try {
                $allResults | Export-Csv -Path $ExportCsv -NoTypeInformation -Force
                Write-Host "✓ Exported to: $ExportCsv" -ForegroundColor Green
            }
            catch {
                Write-Warning "Failed to export CSV: $($_.Exception.Message)"
            }
        }

        return $allResults
    }
}
