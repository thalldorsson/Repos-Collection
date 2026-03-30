#Requires -Version 5.1

<#
.SYNOPSIS
  Creates encrypted credentials file for automated NinjaOne reporting.

.DESCRIPTION
  Prompts for NinjaOne API credentials and saves them in an encrypted format
  using Windows Data Protection API (DPAPI). The encrypted file can only be
  read by the same user on the same machine.
  
  This file is used by Run-WeeklyReport.ps1 for unattended automation.

.PARAMETER OutputPath
  Path to save credentials file. Default: NinjaOneCreds.xml in script directory.

.PARAMETER ClientId
  Optional: NinjaOne API Client ID. If not provided, will prompt.

.PARAMETER ClientSecret
  Optional: NinjaOne API Client Secret (SecureString). If not provided, will prompt.

.EXAMPLE
  .\Setup-NinjaReportCredentials.ps1
  
  Prompts for credentials and saves to NinjaOneCreds.xml.

.EXAMPLE
  $Secret = Read-Host "Client Secret" -AsSecureString
  .\Setup-NinjaReportCredentials.ps1 -ClientId "abc123" -ClientSecret $Secret

.NOTES
  Author: Thorsteinn Halldorsson
  Version: 1.0.0
  Date: 2025-12-12
  
  Security Notes:
  - Credentials are encrypted using DPAPI (machine/user specific)
  - File cannot be decrypted by different user or on different machine
  - Do not copy credentials file between systems
  - Regenerate credentials file if changing user context for scheduled tasks
  
  Prerequisites:
  - NinjaOne API application created (Admin → Apps → API)
  - Client ID and Secret obtained from NinjaOne
#>

[CmdletBinding()]
param(
    [string]$OutputPath,
    
    [string]$ClientId,
    
    [SecureString]$ClientSecret
)

$ErrorActionPreference = 'Stop'

#region Configuration
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $OutputPath) {
    $OutputPath = Join-Path $ScriptRoot "NinjaOneCreds.xml"
}

Write-Host "=== NinjaOne Report Credentials Setup ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "This script will create an encrypted credentials file for automated reporting." -ForegroundColor Gray
Write-Host "The file will be saved to: $OutputPath" -ForegroundColor Gray
Write-Host ""
#endregion

#region Get NinjaOne API Credentials
Write-Host "NinjaOne API Credentials" -ForegroundColor Yellow
Write-Host "────────────────────────" -ForegroundColor Gray
Write-Host ""

# Prompt for Client ID if not provided
if (-not $ClientId) {
    Write-Host "Obtain these from: NinjaOne Console → Admin → Apps → API" -ForegroundColor DarkGray
    Write-Host ""
    $ClientId = Read-Host "Enter Client ID"
    
    if ([string]::IsNullOrWhiteSpace($ClientId)) {
        Write-Host "❌ Client ID cannot be empty" -ForegroundColor Red
        exit 1
    }
}

# Prompt for Client Secret if not provided
if (-not $ClientSecret) {
    $ClientSecret = Read-Host "Enter Client Secret" -AsSecureString
    
    # Validate not empty
    $SecretPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ClientSecret)
    )
    
    if ([string]::IsNullOrWhiteSpace($SecretPlain)) {
        Write-Host "❌ Client Secret cannot be empty" -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "✅ Credentials collected" -ForegroundColor Green
#endregion

#region Test API Credentials (Optional)
Write-Host ""
$TestApi = Read-Host "Test API credentials before saving? (y/n)"

if ($TestApi -eq 'y') {
    Write-Host ""
    Write-Host "Testing NinjaOne API authentication..." -ForegroundColor Yellow
    
    $Region = Read-Host "Enter your NinjaOne region (us/eu/oc/ca)"
    
    if ($Region -notin @('us','eu','oc','ca')) {
        $Region = 'us'
        Write-Host "  Invalid region; defaulting to 'us'" -ForegroundColor Yellow
    }
    
    $RegionEndpoints = @{
        'us' = 'https://app.ninjarmm.com'
        'eu' = 'https://eu.ninjarmm.com'
        'oc' = 'https://oc.ninjarmm.com'
        'ca' = 'https://ca.ninjarmm.com'
    }
    
    $TokenUrl = "$($RegionEndpoints[$Region])/ws/oauth/token"
    
    # Convert SecureString to plain text for API call
    $SecretPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ClientSecret)
    )
    
    $Body = @{
        grant_type = 'client_credentials'
        client_id = $ClientId
        client_secret = $SecretPlain
        scope = 'monitoring'
    }
    
    try {
        $Response = Invoke-RestMethod -Uri $TokenUrl -Method Post -Body $Body -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
        
        if ($Response.access_token) {
            Write-Host "  ✅ Authentication successful!" -ForegroundColor Green
            Write-Host "  Token received (expires in $($Response.expires_in) seconds)" -ForegroundColor Gray
        } else {
            Write-Host "  ⚠️  Authentication returned unexpected response" -ForegroundColor Yellow
        }
        
    } catch {
        Write-Host "  ❌ Authentication failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "Troubleshooting:" -ForegroundColor Yellow
        Write-Host "1. Verify Client ID and Secret are correct" -ForegroundColor Gray
        Write-Host "2. Ensure API application has 'monitoring' scope enabled" -ForegroundColor Gray
        Write-Host "3. Check region is correct for your NinjaOne instance" -ForegroundColor Gray
        Write-Host ""
        
        $Continue = Read-Host "Continue saving credentials anyway? (y/n)"
        if ($Continue -ne 'y') {
            Write-Host "Aborting." -ForegroundColor Yellow
            exit 1
        }
    }
}
#endregion

#region Save Credentials to Encrypted File
try {
    Write-Host ""
    Write-Host "Saving credentials to encrypted file..." -ForegroundColor Yellow
    
    # Create credentials object
    $CredsObject = [PSCustomObject]@{
        ClientId = $ClientId
        ClientSecret = ($ClientSecret | ConvertFrom-SecureString)
        CreatedDate = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        CreatedBy = "$env:USERDOMAIN\$env:USERNAME"
        CreatedOn = $env:COMPUTERNAME
    }
    
    # Ensure directory exists
    $OutputDir = Split-Path -Parent $OutputPath
    if ($OutputDir -and (-not (Test-Path $OutputDir))) {
        New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
    }
    
    # Save to XML (encrypted via DPAPI)
    $CredsObject | Export-Clixml -Path $OutputPath -Force
    
    Write-Host "  ✅ Credentials saved to: $OutputPath" -ForegroundColor Green
    Write-Host ""
    
} catch {
    Write-Host "  ❌ Failed to save credentials: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
#endregion

#region Display Security Notice
Write-Host "Security Notes:" -ForegroundColor Yellow
Write-Host "───────────────" -ForegroundColor Gray
Write-Host "✓ Credentials encrypted using Windows Data Protection API (DPAPI)" -ForegroundColor Green
Write-Host "✓ File can only be decrypted by: $env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME" -ForegroundColor Green
Write-Host ""
Write-Host "⚠️  Do NOT copy this file to other machines or users" -ForegroundColor Yellow
Write-Host "⚠️  Regenerate credentials file if changing scheduled task user context" -ForegroundColor Yellow
Write-Host ""
#endregion

#region Display Next Steps
Write-Host "Next Steps:" -ForegroundColor Cyan
Write-Host "───────────" -ForegroundColor Gray
Write-Host "1. Test the credentials file:" -ForegroundColor White
Write-Host "     \$Creds = Import-Clixml -Path '$OutputPath'" -ForegroundColor Gray
Write-Host "     \$Creds.ClientId" -ForegroundColor Gray
Write-Host ""
Write-Host "2. Run a manual report:" -ForegroundColor White
Write-Host "     .\Run-WeeklyReport.ps1 -SkipEmail -TopCount 10" -ForegroundColor Gray
Write-Host ""
Write-Host "3. Create a scheduled task:" -ForegroundColor White
Write-Host "     See: Docs/Weekly-Report-Generation.md" -ForegroundColor Gray
Write-Host ""
Write-Host "=== Setup Complete ===" -ForegroundColor Cyan
Write-Host ""
#endregion
