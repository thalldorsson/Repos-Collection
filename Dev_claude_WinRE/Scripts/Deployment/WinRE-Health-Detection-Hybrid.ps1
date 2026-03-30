<#
Hybrid wrapper for WinRE Health Detection

This wrapper reads Azure workspace credentials from NinjaOne script variables or environment variables
and invokes the canonical detection script located at `Scripts/Detection/WinRE-Health-Detection-NinjaOne.ps1`.

Do NOT commit secrets. The wrapper expects the workspace id/key to come from NinjaOne org variables or the environment.
#>

Param(
    [switch]$ForceAzure
)

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$canonical = Join-Path $PSScriptRoot "..\Detection\WinRE-Health-Detection-NinjaOne.ps1"

Write-Host "Hybrid wrapper starting..." -ForegroundColor Cyan

# Read from NinjaOne variables if available
function Get-NinjaVar {
    param([string]$name)
    if (Get-Command -Name Ninja-Property-Get -ErrorAction SilentlyContinue) {
        try {
            return Ninja-Property-Get -Name $name -ErrorAction Stop
        } catch { return $null }
    }
    return $null
}

$workspaceId = Get-NinjaVar -name 'LA_WORKSPACE_ID'
$workspaceKey = Get-NinjaVar -name 'LA_WORKSPACE_KEY'
$enableAzure = Get-NinjaVar -name 'ENABLE_AZURE_LOGGING'

if (-not $workspaceId) { $workspaceId = $env:LA_WORKSPACE_ID }
if (-not $workspaceKey) { $workspaceKey = $env:LA_WORKSPACE_KEY }
if (-not $enableAzure) { $enableAzure = $env:ENABLE_AZURE_LOGGING }

if ($ForceAzure) { $enableAzure = $true }

Write-Host "Azure logging enabled:" $enableAzure

if (Test-Path $canonical) {
    if ($enableAzure -and $workspaceId -and $workspaceKey) {
        Write-Host "Calling detection script with Azure parameters..."
        & $canonical -WorkspaceId $workspaceId -WorkspaceKey $workspaceKey -EnableAzure -OutputStdOut
    } else {
        Write-Host "Calling detection script in local/NinjaOne mode..."
        & $canonical
    }
} else {
    Write-Error "Canonical detection script not found at $canonical. Ensure repo layout matches and upload the canonical script to Scripts/Detection/."
    exit 2
}
