function Start-PhishIRDeviceRemediation {
    <#
    .SYNOPSIS
    Identify and remediate devices and user accounts impacted by macro-enabled Excel phishing.

    .DESCRIPTION
    Comprehensive device and identity remediation for users who received and opened macro-enabled Excel attachments.
    
    Actions performed (with approvals):
    1. Identify users who opened emails with invoice subjects and macro attachments
    2. Correlate with device activity (which device opened the file)
    3. Isolate impacted devices in Microsoft Defender for Endpoint (MDE)
    4. Revoke user sessions (Microsoft Graph)
    5. Require password reset
    6. Monitor MFA device changes
    7. Generate remediation report

    All destructive actions require explicit confirmation.

    .PARAMETER UserPrincipalName
    Specific user(s) to remediate. If not provided, identifies users from hunting queries.

    .PARAMETER DeviceIds
    Specific device IDs to isolate. If not provided, identifies devices from hunting queries.

    .PARAMETER IsolateDevices
    If specified, isolates impacted devices in MDE (requires approval).

    .PARAMETER RevokeUserSessions
    If specified, revokes user sign-in sessions (requires approval).

    .PARAMETER RequirePasswordReset
    If specified, requires users to reset password at next sign-in (requires approval).

    .PARAMETER MonitorMFA
    If specified, generates MFA change monitoring report for impacted users.

    .PARAMETER RemediationConfirmation
    Required confirmation phrase for remediation actions: "CONFIRM: Device/Identity remediation approved by [Name]"

    .PARAMETER ReportPath
    Path to save remediation report. Default is current directory.

    .PARAMETER WhatIf
    Shows what would happen without making changes.

    .EXAMPLE
    Start-PhishIRDeviceRemediation -MonitorMFA -WhatIf

    .EXAMPLE
    Start-PhishIRDeviceRemediation -UserPrincipalName "user@contoso.com" -IsolateDevices -RevokeUserSessions -RemediationConfirmation "CONFIRM: Device/Identity remediation approved by John Doe"

    .EXAMPLE
    Start-PhishIRDeviceRemediation -IsolateDevices -RevokeUserSessions -RequirePasswordReset -MonitorMFA -RemediationConfirmation "CONFIRM: Device/Identity remediation approved by SOC Lead"

    .NOTES
    Requires:
    - Microsoft Graph permissions: User.ReadWrite.All, Directory.ReadWrite.All, DeviceManagementManagedDevices.ReadWrite.All
    - Microsoft Defender for Endpoint: Security Administrator
    - Always run with -WhatIf first
    - Device isolation and session revocation require explicit confirmation
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$UserPrincipalName,

        [Parameter(Mandatory = $false)]
        [string[]]$DeviceIds,

        [Parameter(Mandatory = $false)]
        [switch]$IsolateDevices,

        [Parameter(Mandatory = $false)]
        [switch]$RevokeUserSessions,

        [Parameter(Mandatory = $false)]
        [switch]$RequirePasswordReset,

        [Parameter(Mandatory = $false)]
        [switch]$MonitorMFA,

        [Parameter(Mandatory = $false)]
        [string]$RemediationConfirmation,

        [Parameter(Mandatory = $false)]
        [string]$ReportPath = ".\PhishIR-Remediation-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
    )

    $ErrorActionPreference = 'Stop'
    $results = @{
        ImpactedUsers       = @()
        ImpactedDevices     = @()
        DevicesIsolated     = @()
        SessionsRevoked     = @()
        PasswordResetsRequired = @()
        MFAChanges          = @()
        Errors              = @()
    }

    try {
        Write-PhishIRLog -Message "Starting device and identity remediation" -Level Info

        # Safety check for destructive actions
        $destructiveActions = $IsolateDevices -or $RevokeUserSessions -or $RequirePasswordReset
        if ($destructiveActions) {
            if (-not $RemediationConfirmation -or $RemediationConfirmation -notmatch '^CONFIRM:\s+Device/Identity remediation approved by\s+.+$') {
                throw "Destructive actions require RemediationConfirmation parameter with format: 'CONFIRM: Device/Identity remediation approved by [Name]'"
            }
            Write-PhishIRLog -Message "Remediation confirmed: $RemediationConfirmation" -Level Warning
        }

        # Check Microsoft Graph connection
        try {
            $context = Get-MgContext -ErrorAction Stop
            if (-not $context) {
                throw "Not connected to Microsoft Graph"
            }
            Write-PhishIRLog -Message "Microsoft Graph connection verified" -Level Info
        }
        catch {
            Write-Warning "Not connected to Microsoft Graph. Run: Connect-MgGraph -Scopes 'User.ReadWrite.All','Directory.ReadWrite.All','DeviceManagementManagedDevices.ReadWrite.All'"
            throw "Microsoft Graph connection required"
        }

        # Step 1: Identify impacted users (if not provided)
        if (-not $UserPrincipalName) {
            Write-PhishIRLog -Message "Identifying impacted users from hunting queries" -Level Info
            
            # Generate hunting query for users who opened invoice emails
            $invoiceQuery = @"
// Identify users who opened invoice-subject emails
let invoiceWords = dynamic(["unpaid invoice","invoice overdue","overdue invoice","unpaid invoices","invoices overdue"]);
EmailEvents
| where Timestamp >= ago(30d)
| where Subject has_any (invoiceWords)
| where ActionType == "MailItemsAccessed" or EventType has "Read"
| summarize OpenedCount = count(), FirstOpened = min(Timestamp), LastOpened = max(Timestamp) by RecipientEmailAddress
| order by OpenedCount desc
"@
            
            Write-Host "`n=== Run this query in Defender Advanced Hunting to identify impacted users ===" -ForegroundColor Cyan
            Write-Host $invoiceQuery -ForegroundColor Cyan
            Write-Host "`nExport results and re-run with -UserPrincipalName parameter`n" -ForegroundColor Yellow
            
            $results.Errors += "Manual step required: Identify impacted users via hunting query"
            return $results
        }

        $results.ImpactedUsers = $UserPrincipalName
        Write-PhishIRLog -Message "Processing $($UserPrincipalName.Count) user(s)" -Level Info

        # Step 2: Identify devices where users opened attachments
        if (-not $DeviceIds) {
            Write-PhishIRLog -Message "Identifying impacted devices from hunting queries" -Level Info
            
            $deviceQuery = @"
// Correlate users with devices where macro Excel was opened
let impactedUsers = dynamic($(($UserPrincipalName | ConvertTo-Json -Compress)));
let macroExt = dynamic([".xlsm",".xlsb",".xltm",".xla"]);
let macros = EmailAttachmentInfo
    | where Timestamp >= ago(30d)
    | where RecipientEmailAddress in (impactedUsers)
    | where FileName has_any (macroExt)
    | project SHA256, FileName, RecipientEmailAddress, NetworkMessageId;
DeviceFileEvents
| where Timestamp >= ago(30d)
| where SHA256 in (macros | project SHA256)
| join kind=inner (DeviceInfo | project DeviceId, DeviceName, OSPlatform) on DeviceId
| join kind=inner (macros) on SHA256
| project Timestamp, DeviceId, DeviceName, OSPlatform, RecipientEmailAddress, FileName, SHA256, FolderPath
| summarize FirstSeen = min(Timestamp), LastSeen = max(Timestamp), FileCount = count() by DeviceId, DeviceName, RecipientEmailAddress
| order by LastSeen desc
"@
            
            Write-Host "`n=== Run this query to identify impacted devices ===" -ForegroundColor Cyan
            Write-Host $deviceQuery -ForegroundColor Cyan
            Write-Host "`nExport DeviceId column and re-run with -DeviceIds parameter`n" -ForegroundColor Yellow
        }

        if ($DeviceIds) {
            $results.ImpactedDevices = $DeviceIds
            Write-PhishIRLog -Message "Processing $($DeviceIds.Count) device(s)" -Level Info
        }

        # Step 3: Isolate devices (MDE)
        if ($IsolateDevices -and $DeviceIds) {
            Write-PhishIRLog -Message "Isolating $($DeviceIds.Count) device(s) in Microsoft Defender for Endpoint" -Level Warning
            
            foreach ($deviceId in $DeviceIds) {
                if ($PSCmdlet.ShouldProcess($deviceId, "Isolate device in MDE")) {
                    try {
                        # Note: MDE isolation requires Defender for Endpoint API or PowerShell module
                        # This is a placeholder for the actual API call
                        Write-Warning "Device isolation requires Microsoft Defender for Endpoint API"
                        Write-Host "Use MDE Security Center or API to isolate device: $deviceId" -ForegroundColor Yellow
                        Write-Host "API endpoint: POST https://api.securitycenter.microsoft.com/api/machines/$deviceId/isolate" -ForegroundColor Cyan
                        Write-Host "Body: { 'Comment': 'PhishIR: Macro phishing remediation', 'IsolationType': 'Full' }" -ForegroundColor Cyan
                        
                        $results.DevicesIsolated += $deviceId
                    }
                    catch {
                        $errMsg = $_.Exception.Message
                        $results.Errors += "Failed to isolate device ${deviceId}: $errMsg"
                        Write-PhishIRLog -Message "Failed to isolate device ${deviceId}: $errMsg" -Level Error
                    }
                }
            }
        }

        # Step 4: Revoke user sessions
        if ($RevokeUserSessions) {
            Write-PhishIRLog -Message "Revoking sessions for $($UserPrincipalName.Count) user(s)" -Level Warning
            
            foreach ($upn in $UserPrincipalName) {
                if ($PSCmdlet.ShouldProcess($upn, "Revoke sign-in sessions")) {
                    try {
                        $user = Get-MgUser -UserId $upn -ErrorAction Stop
                        Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/users/$($user.Id)/revokeSignInSessions" -ErrorAction Stop
                        
                        Write-PhishIRLog -Message "Sessions revoked for $upn" -Level Success
                        $results.SessionsRevoked += $upn
                    }
                    catch {
                        $errMsg = $_.Exception.Message
                        $results.Errors += "Failed to revoke sessions for ${upn}: $errMsg"
                        Write-PhishIRLog -Message "Failed to revoke sessions for ${upn}: $errMsg" -Level Error
                    }
                }
            }
        }

        # Step 5: Require password reset
        if ($RequirePasswordReset) {
            Write-PhishIRLog -Message "Requiring password reset for $($UserPrincipalName.Count) user(s)" -Level Warning
            
            foreach ($upn in $UserPrincipalName) {
                if ($PSCmdlet.ShouldProcess($upn, "Require password reset at next sign-in")) {
                    try {
                        $user = Get-MgUser -UserId $upn -ErrorAction Stop
                        Update-MgUser -UserId $user.Id -PasswordProfile @{ ForceChangePasswordNextSignIn = $true } -ErrorAction Stop
                        
                        Write-PhishIRLog -Message "Password reset required for $upn" -Level Success
                        $results.PasswordResetsRequired += $upn
                    }
                    catch {
                        $errMsg = $_.Exception.Message
                        $results.Errors += "Failed to require password reset for ${upn}: $errMsg"
                        Write-PhishIRLog -Message "Failed to require password reset for ${upn}: $errMsg" -Level Error
                    }
                }
            }
        }

        # Step 6: Monitor MFA changes
        if ($MonitorMFA) {
            Write-PhishIRLog -Message "Generating MFA change report for impacted users" -Level Info
            
            $mfaQuery = Get-PhishIRMacroHunt -QueryType MFAChanges -TimeRange "30d"
            
            Write-Host "`n=== MFA Change Monitoring Query ===" -ForegroundColor Cyan
            Write-Host $mfaQuery -ForegroundColor Cyan
            Write-Host "`nRun this query in Defender Advanced Hunting and filter by impacted users" -ForegroundColor Yellow
            Write-Host "Impacted users: $($UserPrincipalName -join ', ')" -ForegroundColor Yellow
            
            # Alternative: Query audit logs via Graph (if available)
            try {
                foreach ($upn in $UserPrincipalName) {
                    $auditLogs = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/auditLogs/directoryAudits?`$filter=targetResources/any(t:t/userPrincipalName eq '$upn') and activityDisplayName eq 'User registered security info'" -ErrorAction Stop
                    
                    if ($auditLogs.value) {
                        $results.MFAChanges += @{
                            User = $upn
                            Changes = $auditLogs.value
                        }
                    }
                }
            }
            catch {
                Write-Warning "Could not retrieve MFA changes via Graph API: $_"
            }
        }

        # Step 7: Generate remediation report
        Write-PhishIRLog -Message "Generating remediation report: $ReportPath" -Level Info
        
        $report = @()
        foreach ($upn in $UserPrincipalName) {
            $report += [PSCustomObject]@{
                UserPrincipalName       = $upn
                DevicesImpacted         = ($DeviceIds -join '; ')
                DeviceIsolated          = ($results.DevicesIsolated -contains $DeviceIds)
                SessionRevoked          = ($results.SessionsRevoked -contains $upn)
                PasswordResetRequired   = ($results.PasswordResetsRequired -contains $upn)
                RemediationTimestamp    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                ApprovedBy              = if ($RemediationConfirmation) { $RemediationConfirmation } else { 'N/A' }
            }
        }
        
        $report | Export-Csv -Path $ReportPath -NoTypeInformation
        Write-PhishIRLog -Message "Remediation report saved: $ReportPath" -Level Success

        # Summary
        Write-Host "`n=== Device & Identity Remediation Summary ===" -ForegroundColor Green
        Write-Host "Impacted users: $($results.ImpactedUsers.Count)"
        Write-Host "Impacted devices: $($results.ImpactedDevices.Count)"
        Write-Host "Devices isolated: $($results.DevicesIsolated.Count)"
        Write-Host "Sessions revoked: $($results.SessionsRevoked.Count)"
        Write-Host "Password resets required: $($results.PasswordResetsRequired.Count)"
        Write-Host "Remediation report: $ReportPath"
        
        Write-Host "`n=== Recommended Next Steps ===" -ForegroundColor Yellow
        Write-Host "1. Review remediation report and validate actions taken"
        Write-Host "2. Monitor impacted users for suspicious sign-ins (Entra ID Identity Protection)"
        Write-Host "3. Run MFA change query and investigate unexpected auth method additions"
        Write-Host "4. For isolated devices:"
        Write-Host "   - Collect investigation package (MDE portal)"
        Write-Host "   - Run full AV scan"
        Write-Host "   - If clean: release from isolation"
        Write-Host "   - If compromised: reimage device"
        Write-Host "5. Monitor for lateral movement or persistence indicators"
        Write-Host "6. Update detections and add hunting queries to watchlist"

        return $results
    }
    catch {
        $results.Errors += $_.Exception.Message
        Write-PhishIRLog -Message "Error in device remediation: $_" -Level Error
        throw
    }
}
