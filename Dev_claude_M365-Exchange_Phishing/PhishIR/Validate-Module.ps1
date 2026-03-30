# PhishIR v2.4.1 Module Validation Script
# Verifies all new functions and backward compatibility

Write-Host ""
Write-Host "=== PhishIR v2.4.1 Module Validation ===" -ForegroundColor Cyan
Write-Host "Loading module..." -ForegroundColor Yellow

# Import module
$modulePath = Join-Path $PSScriptRoot 'PhishIR.psd1'
try {
    Import-Module $modulePath -Force -ErrorAction Stop
    Write-Host "OK Module loaded successfully" -ForegroundColor Green
}
catch {
    Write-Host "FAIL Module load failed: $_" -ForegroundColor Red
    exit 1
}

# Check version
$module = Get-Module PhishIR
if ($module.Version -eq '2.4.1') {
    Write-Host "OK Module version: $($module.Version)" -ForegroundColor Green
}
else {
    Write-Host "FAIL Expected version 2.4.1, got $($module.Version)" -ForegroundColor Red
}

Write-Host ""
Write-Host "--- Validating New Functions (v2.4.1) ---" -ForegroundColor Yellow
$newFunctions = @(
    'Get-PhishIRConfig',
    'Get-PhishIRStoragePath',
    'Initialize-PhishIREnvironment',
    'Test-PhishIRConfiguration',
    'Get-PhishIRIncidentStorePath',
    'Send-PhishIRMetric',
    'Get-PhishIRSecret'
)

$missingCount = 0
foreach ($funcName in $newFunctions) {
    $cmd = Get-Command $funcName -ErrorAction SilentlyContinue
    if ($cmd) {
        Write-Host "  OK $funcName" -ForegroundColor Green
    }
    else {
        Write-Host "  MISSING $funcName" -ForegroundColor Red
        $missingCount++
    }
}

Write-Host ""
Write-Host "--- Validating Existing Functions (Backward Compatibility) ---" -ForegroundColor Yellow
$existingFunctions = @(
    'Add-PhishIRIncidentRecord',
    'Get-PhishIRIncidentRecord',
    'Get-PhishIRExcelHyperlinks',
    'Get-PhishIRUserSignInHistory',
    'Send-PhishIRUrlToDefender',
    'Block-PhishIRUrl',
    'Invoke-PhishIRQuarantine'
)

$missingLegacy = 0
foreach ($funcName in $existingFunctions) {
    $cmd = Get-Command $funcName -ErrorAction SilentlyContinue
    if ($cmd) {
        Write-Host "  OK $funcName" -ForegroundColor Green
    }
    else {
        Write-Host "  MISSING $funcName" -ForegroundColor Red
        $missingLegacy++
    }
}

Write-Host ""
Write-Host "--- Validation Summary ---" -ForegroundColor Cyan
$totalNew = $newFunctions.Count
$totalExisting = $existingFunctions.Count
$totalFound = ($totalNew - $missingCount) + ($totalExisting - $missingLegacy)
$totalExpected = $totalNew + $totalExisting

$newColor = if ($missingCount -eq 0) { 'Green' } else { 'Yellow' }
$existingColor = if ($missingLegacy -eq 0) { 'Green' } else { 'Yellow' }
$totalColor = if ($totalFound -eq $totalExpected) { 'Green' } else { 'Red' }

Write-Host "New functions: $($totalNew - $missingCount)/$totalNew" -ForegroundColor $newColor
Write-Host "Existing functions: $($totalExisting - $missingLegacy)/$totalExisting" -ForegroundColor $existingColor
Write-Host "Total: $totalFound/$totalExpected" -ForegroundColor $totalColor

Write-Host ""
if ($missingCount -eq 0 -and $missingLegacy -eq 0) {
    Write-Host "All validation checks passed! Module ready for use." -ForegroundColor Green
    exit 0
}
else {
    Write-Host "Validation failed. Some functions are missing." -ForegroundColor Red
    exit 1
}
