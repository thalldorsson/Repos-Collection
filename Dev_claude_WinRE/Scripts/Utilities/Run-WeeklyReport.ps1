#Requires -Version 5.1

<#
.SYNOPSIS
  Weekly WinRE health report generator for Task Scheduler.

.DESCRIPTION
  Authenticates to NinjaOne API, exports top-risk devices to CSV, 
  and emails report to stakeholders.
  
  Designed to run unattended via Windows Task Scheduler.

.PARAMETER Region
  NinjaOne region (us, eu, oc, ca). Default: us.

.PARAMETER TopCount
  Number of top-risk devices to export. Default: 50.

.PARAMETER OutputDir
  Directory for CSV and log files. Default: C:\Reports\WinRE

.PARAMETER EmailTo
  Recipient email address(es) for report. Separate multiple with commas.

.PARAMETER EmailFrom
  Sender email address.

.PARAMETER SmtpServer
  SMTP server for email delivery.

.PARAMETER SmtpPort
  SMTP port. Default: 25.

.PARAMETER SmtpUseSsl
  Use SSL/TLS for SMTP connection.

.PARAMETER SmtpCredential
  PSCredential for authenticated SMTP (if required).

.EXAMPLE
  .\Run-WeeklyReport.ps1

.EXAMPLE
  .\Run-WeeklyReport.ps1 -TopCount 100 -EmailTo "team@contoso.com"

.NOTES
  Author: Thorsteinn Halldorsson
  Version: 1.0.0
  Date: 2025-12-12
  
  Prerequisites:
  - NinjaOne API credentials stored in NinjaOneCreds.xml (same directory)
  - Export-NinjaTopRiskCsv.ps1 in Scripts/Utilities/
  - Network access to NinjaOne API and SMTP server
  
  Setup:
  1. Run once to create credentials file:
       $ClientId = "your-client-id"
       $ClientSecret = "your-client-secret" | ConvertTo-SecureString -AsPlainText -Force
       @{ ClientId = $ClientId; ClientSecret = ($ClientSecret | ConvertFrom-SecureString) } | Export-Clixml -Path .\NinjaOneCreds.xml
  2. Create scheduled task to run this script weekly
#>

[CmdletBinding()]
param(
    [ValidateSet('us','eu','oc','ca')]
    [string]$Region = 'us',
    
    [ValidateRange(1,1000)]
    [int]$TopCount = 50,
    
    [string]$OutputDir = 'C:\Reports\WinRE',
    
    [string]$EmailTo,
    
    [string]$EmailFrom,
    
    [string]$SmtpServer,
    
    [int]$SmtpPort = 25,
    
    [switch]$SmtpUseSsl,
    
    [PSCredential]$SmtpCredential,
    
    [switch]$SkipEmail
)

$ErrorActionPreference = 'Stop'

#region Configuration
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$CredPath = Join-Path $ScriptRoot "NinjaOneCreds.xml"
$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogPath = Join-Path $OutputDir "WeeklyReport-$Timestamp.log"

# Ensure output directory exists
if (-not (Test-Path $OutputDir)) {
    Write-Host "Creating output directory: $OutputDir" -ForegroundColor Yellow
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}

# Start transcript for logging
Start-Transcript -Path $LogPath -Append
Write-Host "=== WinRE Weekly Report Generator ===" -ForegroundColor Cyan
Write-Host "Start Time: $(Get-Date)" -ForegroundColor Gray
Write-Host "Region: $Region" -ForegroundColor Gray
Write-Host "Top Count: $TopCount" -ForegroundColor Gray
Write-Host "Output Dir: $OutputDir" -ForegroundColor Gray
Write-Host ""
#endregion

#region Validate Email Parameters
if (-not $SkipEmail) {
    if (-not $EmailTo) {
        Write-Host "⚠️  No EmailTo specified; skipping email (use -SkipEmail to suppress this warning)" -ForegroundColor Yellow
        $SkipEmail = $true
    }
    
    if (-not $SkipEmail -and (-not $EmailFrom -or -not $SmtpServer)) {
        Write-Host "⚠️  EmailFrom and SmtpServer required for email; skipping email" -ForegroundColor Yellow
        $SkipEmail = $true
    }
}
#endregion

#region Load Credentials
try {
    Write-Host "Loading NinjaOne API credentials from $CredPath..." -ForegroundColor Yellow
    
    if (-not (Test-Path $CredPath)) {
        throw "Credentials file not found: $CredPath`n`nCreate it with:`n`$ClientId = 'your-id'`n`$ClientSecret = 'your-secret' | ConvertTo-SecureString -AsPlainText -Force`n@{ ClientId = `$ClientId; ClientSecret = (`$ClientSecret | ConvertFrom-SecureString) } | Export-Clixml -Path '$CredPath'"
    }
    
    $Creds = Import-Clixml -Path $CredPath
    
    if (-not $Creds.ClientId -or -not $Creds.ClientSecret) {
        throw "Credentials file missing ClientId or ClientSecret. Regenerate the file."
    }
    
    $ClientId = $Creds.ClientId
    $ClientSecret = $Creds.ClientSecret | ConvertTo-SecureString
    $ClientSecretPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ClientSecret)
    )
    
    Write-Host "  ✅ Credentials loaded (Client ID: $ClientId)" -ForegroundColor Green
    
} catch {
    Write-Host "  ❌ Failed to load credentials: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Troubleshooting:" -ForegroundColor Yellow
    Write-Host "1. Ensure NinjaOneCreds.xml exists in same directory as this script" -ForegroundColor Gray
    Write-Host "2. Regenerate credentials file if corrupted" -ForegroundColor Gray
    Write-Host "3. Verify file is not encrypted by different user/machine (DPAPI)" -ForegroundColor Gray
    Stop-Transcript
    exit 1
}
#endregion

#region Run Export Script
try {
    Write-Host "Running WinRE export script..." -ForegroundColor Yellow
    
    # Locate export script (same directory or ../../Scripts/Utilities/)
    $ExportScriptPath = Join-Path $ScriptRoot "Export-NinjaTopRiskCsv.ps1"
    
    if (-not (Test-Path $ExportScriptPath)) {
        # Try alternate path (if running from C:\Scripts\WinRE\ and main repo is elsewhere)
        $AltPath = Join-Path $ScriptRoot "..\..\Scripts\Utilities\Export-NinjaTopRiskCsv.ps1"
        if (Test-Path $AltPath) {
            $ExportScriptPath = $AltPath
        } else {
            throw "Export script not found at: $ExportScriptPath or $AltPath"
        }
    }
    
    Write-Host "  Using script: $ExportScriptPath" -ForegroundColor Gray
    
    $OutputFile = Join-Path $OutputDir "WinRE-TopRisk-$(Get-Date -Format 'yyyyMMdd').csv"
    
    & $ExportScriptPath `
        -ClientId $ClientId `
        -ClientSecret $ClientSecretPlain `
        -Region $Region `
        -TopCount $TopCount `
        -OutputPath $OutputFile
    
    if (-not (Test-Path $OutputFile)) {
        throw "Export script did not create output file: $OutputFile"
    }
    
    $FileSize = (Get-Item $OutputFile).Length
    Write-Host "  ✅ Export complete: $OutputFile ($([math]::Round($FileSize/1KB, 2)) KB)" -ForegroundColor Green
    
} catch {
    Write-Host "  ❌ Export failed: $($_.Exception.Message)" -ForegroundColor Red
    Stop-Transcript
    exit 1
}
#endregion

#region Calculate Summary Statistics
try {
    Write-Host ""
    Write-Host "Calculating summary statistics..." -ForegroundColor Yellow
    
    $Data = Import-Csv -Path $OutputFile
    
    $TotalDevices = $Data.Count
    $CriticalDevices = ($Data | Where-Object { $_.Severity -eq 'Warning/Critical' }).Count
    $KB5034441Vuln = ($Data | Where-Object { $_.KB5034441Vulnerable -eq 'True' }).Count
    $Win11NotReady = ($Data | Where-Object { $_.Windows11Ready -eq 'False' }).Count
    $AvgRiskScore = [math]::Round(($Data | Measure-Object -Property RiskScore -Average).Average, 1)
    
    Write-Host "  Total Devices: $TotalDevices" -ForegroundColor Gray
    Write-Host "  Critical/Warning: $CriticalDevices" -ForegroundColor $(if ($CriticalDevices -gt 0) { 'Red' } else { 'Green' })
    Write-Host "  KB5034441 Vulnerable: $KB5034441Vuln" -ForegroundColor $(if ($KB5034441Vuln -gt 0) { 'Red' } else { 'Green' })
    Write-Host "  Windows 11 Not Ready: $Win11NotReady" -ForegroundColor Gray
    Write-Host "  Average Risk Score: $AvgRiskScore" -ForegroundColor Gray
    
} catch {
    Write-Host "  ⚠️  Could not calculate stats: $($_.Exception.Message)" -ForegroundColor Yellow
    # Non-fatal; continue to email
    $TotalDevices = 0
    $CriticalDevices = 0
    $KB5034441Vuln = 0
    $Win11NotReady = 0
    $AvgRiskScore = 0
}
#endregion

#region Email Report
if (-not $SkipEmail) {
    try {
        Write-Host ""
        Write-Host "Sending email report..." -ForegroundColor Yellow
        
        $Subject = "WinRE Weekly Health Report - $(Get-Date -Format 'yyyy-MM-dd')"
        
        $Body = @"
Weekly WinRE Health Report Summary
Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm')
Region: $Region

Key Metrics:
─────────────────────────────────
Total Devices in Report:    $TotalDevices
Critical/Warning Devices:   $CriticalDevices
KB5034441 Vulnerable:       $KB5034441Vuln
Windows 11 Not Ready:       $Win11NotReady
Average Risk Score:         $AvgRiskScore

Attached CSV contains full device list with recommendations.

Priority Actions:
─────────────────────────────────
1. Review devices with RiskScore > 70 (immediate attention)
2. Address KB5034441 vulnerable devices (security risk)
3. Plan remediation for devices with <100 MB free space

Questions? Contact IT Operations.

Report generated by: WinRE Health Monitoring Solution
CSV File: $OutputFile
"@
        
        $EmailParams = @{
            To = $EmailTo
            From = $EmailFrom
            Subject = $Subject
            Body = $Body
            Attachments = $OutputFile
            SmtpServer = $SmtpServer
            Port = $SmtpPort
            Priority = 'High'
        }
        
        if ($SmtpUseSsl) {
            $EmailParams.UseSsl = $true
        }
        
        if ($SmtpCredential) {
            $EmailParams.Credential = $SmtpCredential
        }
        
        Send-MailMessage @EmailParams
        
        Write-Host "  ✅ Email sent to $EmailTo" -ForegroundColor Green
        
    } catch {
        Write-Host "  ⚠️  Email failed (CSV still saved): $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Troubleshooting:" -ForegroundColor Yellow
        Write-Host "1. Verify SMTP server and port: $SmtpServer:$SmtpPort" -ForegroundColor Gray
        Write-Host "2. Check network connectivity to SMTP server" -ForegroundColor Gray
        Write-Host "3. Verify sender/recipient email addresses" -ForegroundColor Gray
        Write-Host "4. Use -SmtpUseSsl if server requires encryption" -ForegroundColor Gray
        Write-Host "5. Use -SmtpCredential if authentication required" -ForegroundColor Gray
        # Don't exit 1 here; report was generated, just email failed
    }
} else {
    Write-Host ""
    Write-Host "⏭️  Email skipped (use -EmailTo, -EmailFrom, -SmtpServer to enable)" -ForegroundColor Gray
}
#endregion

#region Cleanup and Summary
Write-Host ""
Write-Host "=== Report Complete ===" -ForegroundColor Cyan
Write-Host "End Time: $(Get-Date)" -ForegroundColor Gray
Write-Host "CSV: $OutputFile" -ForegroundColor Gray
Write-Host "Log: $LogPath" -ForegroundColor Gray
Write-Host ""

if ($CriticalDevices -gt 0) {
    Write-Host "⚠️  WARNING: $CriticalDevices devices require immediate attention!" -ForegroundColor Yellow
}

if ($KB5034441Vuln -gt 0) {
    Write-Host "🚨 ALERT: $KB5034441Vuln devices vulnerable to KB5034441!" -ForegroundColor Red
}

Stop-Transcript
exit 0
#endregion
