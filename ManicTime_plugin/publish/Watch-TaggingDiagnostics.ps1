# Watches the plugin diagnostics folder for tag-save results.
# Run this, then click "Apply tag" in the ManicTime plugin UI.
#
# Usage:
#   .\publish\Watch-TaggingDiagnostics.ps1

[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$storageRoot = Join-Path $env:LOCALAPPDATA 'Finkit\ManicTime\Plugins\Storage\Custom.MyWorklogAutoTagger\Content\Diagnostics'
$cacheRoot = Join-Path $env:LOCALAPPDATA 'Finkit\ManicTime\Plugins\Cache\Custom.MyWorklogAutoTagger\Lib\Diagnostics'

Write-Host "Watching for tagging diagnostics..." -ForegroundColor Cyan
Write-Host "Storage diagnostics: $storageRoot"
Write-Host "Cache/assembly diagnostics: $cacheRoot"

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)

function LatestHit([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    return Get-ChildItem -LiteralPath $dir -File -Filter 'tagging-save-*.txt' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

$initialStorage = LatestHit $storageRoot
$initialCache = LatestHit $cacheRoot

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500

    $s = LatestHit $storageRoot
    $c = LatestHit $cacheRoot

    if ($s -and (!$initialStorage -or $s.FullName -ne $initialStorage.FullName)) {
        Write-Host "New diagnostics file (storage): $($s.FullName)" -ForegroundColor Green
        Get-Content -LiteralPath $s.FullName -Raw | Write-Host
        exit 0
    }

    if ($c -and (!$initialCache -or $c.FullName -ne $initialCache.FullName)) {
        Write-Host "New diagnostics file (cache): $($c.FullName)" -ForegroundColor Green
        Get-Content -LiteralPath $c.FullName -Raw | Write-Host
        exit 0
    }
}

Write-Host "Timed out after $TimeoutSeconds seconds without seeing a new tagging diagnostics file." -ForegroundColor Yellow
exit 2
