# PhishIR v2.4.1 Test Suite Runner
# Run all Pester tests for new functions

#Requires -Module Pester

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('All', 'Configuration', 'SignIn', 'Partitioning', 'Metrics', 'Secrets', 'Tenants', 'MailboxTargets', 'Approvals', 'RateLimits')]
    [string]$TestSuite = 'All',
    
    [Parameter()]
    [switch]$Detailed,
    
    [Parameter()]
    [string]$OutputPath = (Join-Path $PSScriptRoot 'TestResults')
)

Write-Host "`n=== PhishIR v2.4.1 Test Suite ===" -ForegroundColor Cyan
Write-Host "Test Suite: $TestSuite" -ForegroundColor Yellow
Write-Host "Output Path: $OutputPath`n" -ForegroundColor Yellow

# Ensure Pester is installed
$pesterModule = Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pesterModule -or $pesterModule.Version -lt [version]'5.0.0') {
    Write-Host "Installing Pester 5.x..." -ForegroundColor Yellow
    Install-Module -Name Pester -MinimumVersion 5.0.0 -Scope CurrentUser -Force -SkipPublisherCheck
    Import-Module Pester -MinimumVersion 5.0.0
} else {
    Write-Host "Pester version: $($pesterModule.Version)" -ForegroundColor Green
    Import-Module Pester -MinimumVersion 5.0.0
}

# Create output directory
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# Map test suites to test files
$testFiles = @{
    'Configuration' = 'Test-PhishIRConfiguration.Tests.ps1'
    'SignIn'        = 'Get-PhishIRUserSignInHistory.Tests.ps1'
    'Partitioning'  = 'Get-PhishIRIncidentStorePath.Tests.ps1'
    'Metrics'       = 'Send-PhishIRMetric.Tests.ps1'
    'Secrets'       = 'Get-PhishIRSecret.Tests.ps1'
    'Tenants'       = 'Get-PhishIRTenantConfig.Tests.ps1'
    'MailboxTargets' = 'Get-PhishIRMailboxTargets.Tests.ps1'
    'Approvals'     = 'Confirm-PhishIRTenantOperation.Tests.ps1'
    'RateLimits'    = 'Update-PhishIRTenantRateLimits.Tests.ps1'
}

# Select test files to run
$selectedTests = if ($TestSuite -eq 'All') {
    $testFiles.Values | ForEach-Object { Join-Path $PSScriptRoot $_ }
} else {
    @(Join-Path $PSScriptRoot $testFiles[$TestSuite])
}

Write-Host "Running tests..." -ForegroundColor Cyan
Write-Host "Test files: $($selectedTests.Count)" -ForegroundColor Yellow
foreach ($test in $selectedTests) {
    Write-Host "  - $(Split-Path $test -Leaf)" -ForegroundColor Gray
}
Write-Host ""

# Configure Pester
$pesterConfig = New-PesterConfiguration
$pesterConfig.Run.Path = $selectedTests
$pesterConfig.Run.PassThru = $true
$pesterConfig.Output.Verbosity = if ($Detailed) { 'Detailed' } else { 'Normal' }
$pesterConfig.TestResult.Enabled = $true
$pesterConfig.TestResult.OutputPath = Join-Path $OutputPath "TestResults-$(Get-Date -Format 'yyyyMMdd-HHmmss').xml"
$pesterConfig.TestResult.OutputFormat = 'NUnitXml'
$pesterConfig.CodeCoverage.Enabled = $false

# Run tests
$result = Invoke-Pester -Configuration $pesterConfig

# Summary
Write-Host "`n=== Test Summary ===" -ForegroundColor Cyan
Write-Host "Total Tests: $($result.TotalCount)" -ForegroundColor White
Write-Host "Passed: $($result.PassedCount)" -ForegroundColor Green
Write-Host "Failed: $($result.FailedCount)" -ForegroundColor $(if ($result.FailedCount -eq 0) { 'Green' } else { 'Red' })
Write-Host "Skipped: $($result.SkippedCount)" -ForegroundColor Yellow
Write-Host "Duration: $($result.Duration.TotalSeconds) seconds" -ForegroundColor White

# Exit code
if ($result.FailedCount -gt 0) {
    Write-Host "`nTests FAILED" -ForegroundColor Red
    exit 1
} else {
    Write-Host "`nAll tests PASSED" -ForegroundColor Green
    exit 0
}
