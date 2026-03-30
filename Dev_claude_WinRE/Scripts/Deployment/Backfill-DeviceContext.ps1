<#
Backfill script for Phase 2 device-context fields.
Usage (local test):
  pwsh -File .\Scripts\Deployment\Backfill-DeviceContext.ps1 -WorkspaceId <id> -WorkspaceKey <key>
Note: This re-invokes the canonical NinjaOne detector to push enriched records to Log Analytics.
#>
param(
    [Parameter(Mandatory=$true)][string]$WorkspaceId,
    [Parameter(Mandatory=$true)][string]$WorkspaceKey,
    [string]$LogType = 'WinREHealthV2'
)

$scriptPath = Join-Path $PSScriptRoot '..\Detection\WinRE-Health-Detection-NinjaOne.ps1'
if (-not (Test-Path $scriptPath)) { throw "Detector not found at $scriptPath" }

Write-Host "Running detector once to backfill device context fields..." -ForegroundColor Cyan

& $scriptPath -WorkspaceId $WorkspaceId -WorkspaceKey $WorkspaceKey -ENABLE_AZURE_LOGGING:$true -OutputStdOut:$false -Ephemeral:$true -LogType $LogType

Write-Host "Backfill run complete. Push via RMM policy for fleet-wide coverage." -ForegroundColor Green
