# Builds the plugin and installs it into the ManicTime Packages folder.
#
# This script is meant to make the in-client tagging proof quick to verify.
# It writes PluginSpec.json into the package root and copies published binaries to Lib/.
#
# Usage (from repo root):
#   .\publish\Build-And-InstallToManicTime.ps1

[CmdletBinding()]
param(
    [string]$Configuration = "Debug",
    [string]$Framework = "net9.0-windows",
    [string]$PluginSpecSourcePath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$pluginProject = Join-Path $repoRoot "ManicTimeWorklogPlugin\ManicTimeWorklogPlugin.csproj"
$outDir = Join-Path $PSScriptRoot "deploy-staging"

$defaultSpecRepo = Join-Path $PSScriptRoot "PluginSpec.json"
$defaultSpecInstalled = Join-Path $env:LOCALAPPDATA "Finkit\ManicTime\Plugins\Packages\Custom.MyWorklogAutoTagger\PluginSpec.json"

if ([string]::IsNullOrWhiteSpace($PluginSpecSourcePath)) {
    if (Test-Path -LiteralPath $defaultSpecRepo) {
        $PluginSpecSourcePath = $defaultSpecRepo
    }
    elseif (Test-Path -LiteralPath $defaultSpecInstalled) {
        $PluginSpecSourcePath = $defaultSpecInstalled
    }
}

Write-Host "Publishing plugin..." -ForegroundColor Cyan
& dotnet publish $pluginProject -c $Configuration -f $Framework -o $outDir | Out-Host

$spec = Read-JsonFile $PluginSpecSourcePath
if ($null -eq $spec) {
    throw "Could not find PluginSpec.json. Looked at: '$PluginSpecSourcePath'. Create 'publish/PluginSpec.json' or pass -PluginSpecSourcePath."
}

$pluginId = [string]$spec.Id
if ([string]::IsNullOrWhiteSpace($pluginId)) {
    throw "PluginSpec.json is missing required field: Id"
}

$packagesRoot = Join-Path $env:LOCALAPPDATA "Finkit\ManicTime\Plugins\Packages"
$packageRoot = Join-Path $packagesRoot $pluginId
$libDir = Join-Path $packageRoot "Lib"

Write-Host "Installing to: $packageRoot" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $libDir | Out-Null

# Write spec into package root (this is what ManicTime discovers)
$specOutPath = Join-Path $packageRoot "PluginSpec.json"
$spec | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $specOutPath -Encoding UTF8

# Copy published binaries into Lib
Copy-Item -Path (Join-Path $outDir '*') -Destination $libDir -Recurse -Force

Write-Host "Done." -ForegroundColor Green
Write-Host "Next: start ManicTime and use the plugin UI to click 'Apply tag to last N minutes'." -ForegroundColor Green
Write-Host "If tags don't show, open the diagnostics folder reported in the UI message box." -ForegroundColor Green
