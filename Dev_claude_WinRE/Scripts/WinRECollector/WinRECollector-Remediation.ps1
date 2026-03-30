#Requires -Version 5.1
<#
.SYNOPSIS
  WinRE Health Remediation Script - For Intune Proactive Remediations.
.DESCRIPTION
  Runs when detection script returns non-zero (non-compliant).
  Attempts to enable WinRE and collects health data, sending to Log Analytics.
  
  Requires environment variables or parameters:
  - LA_WORKSPACE_ID: Azure Log Analytics Workspace ID
  - LA_WORKSPACE_KEY: Azure Log Analytics Workspace Key (base64)
  
.NOTES
  Version: 1.0.0
  Schema Version: 2024-12-04
  
.EXAMPLE
  & .\WinRECollector-Remediation.ps1
#>

param(
    [string]$WorkspaceId = $env:LA_WORKSPACE_ID,
    [string]$WorkspaceKey = $env:LA_WORKSPACE_KEY
)

# Import LogAnalyticsIngestion module for Azure Log Analytics ingestion
$laModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\LogAnalyticsIngestion.psm1'
if (Test-Path $laModulePath) {
    Import-Module $laModulePath -Force -ErrorAction SilentlyContinue
} else {
    Write-Warning "LogAnalyticsIngestion module not found at: $laModulePath. Azure ingestion will not be available."
}

$ErrorActionPreference = 'Continue'

#region Helper Functions (minimal subset from WinRECollector.ps1)

# Send-ToLogAnalytics function now imported from LogAnalyticsIngestion.psm1 module

#endregion

Write-Host "Starting WinRE Health Remediation..."

# Attempt to enable WinRE
try {
    Write-Host "Attempting to enable WinRE..."
    $output = & reagentc /enable 2>&1 | Out-String
    Write-Host "reagentc /enable: $output"
}
catch {
    Write-Host "reagentc /enable failed: $_"
}

# Wait a moment for changes to settle
Start-Sleep -Seconds 2

# Collect post-remediation status
try {
    $reagentOutput = & reagentc /info 2>&1 | Out-String
    $payload = @{
        ComputerName = $env:COMPUTERNAME
        Timestamp = (Get-Date).ToUniversalTime().ToString('o')
        ScriptVersion = '1.0.0'
        SchemaVersion = '2024-12-04'
        RemedationAction = 'reagentc /enable executed'
        WinREStatus = $reagentOutput
        CollectionMethod = 'Intune-Remediation'
    }
    
    $result = Send-ToLogAnalytics -Payload $payload -WorkspaceId $WorkspaceId -WorkspaceKey $WorkspaceKey
    if ($result) {
        Write-Host "Remediation data sent to Log Analytics successfully."
    }
    else {
        Write-Host "Failed to send remediation data to Log Analytics."
    }
}
catch {
    Write-Host "Post-remediation collection error: $_"
}

Write-Host "WinRE Health Remediation completed."
exit 0
