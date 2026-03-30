<#
.SYNOPSIS
    Test runner script for WinRE Health Toolkit

.DESCRIPTION
    Runs all tests with proper configuration, generates coverage reports,
    and provides summary statistics.

.PARAMETER TestPath
    Path to tests directory. Defaults to Tests/

.PARAMETER Tag
    Tags to include in test run

.PARAMETER ExcludeTag
    Tags to exclude from test run

.PARAMETER Coverage
    Generate code coverage report

.PARAMETER Output
    Output verbosity (Detailed, Normal, Minimal)

.PARAMETER CI
    Run in CI/CD mode with XML output

.EXAMPLE
    .\Invoke-TestSuite.ps1
    Run all tests with default settings

.EXAMPLE
    .\Invoke-TestSuite.ps1 -Tag "Unit" -Coverage
    Run unit tests with coverage report

.EXAMPLE
    .\Invoke-TestSuite.ps1 -CI
    Run in CI/CD mode

.NOTES
    Version: 1.0.0
    Requires: Pester 5.0+
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$TestPath = "$PSScriptRoot/Tests",

    [Parameter()]
    [string[]]$Tag,

    [Parameter()]
    [string[]]$ExcludeTag = @('Slow', 'RequiresAzure', 'RequiresNinja'),

    [Parameter()]
    [switch]$Coverage,

    [Parameter()]
    [ValidateSet('Detailed', 'Normal', 'Minimal')]
    [string]$Output = 'Normal',

    [Parameter()]
    [switch]$CI,

    [Parameter()]
    [string]$OutputFile = "$PSScriptRoot/test-results.xml"
)

# Ensure Pester is available
$pesterModule = Get-Module -Name Pester -ListAvailable | 
    Where-Object { $_.Version -ge [Version]'5.0.0' } | 
    Select-Object -First 1

if (-not $pesterModule) {
    Write-Error "Pester 5.0+ is required. Install with: Install-Module -Name Pester -MinimumVersion 5.0.0 -Force"
    exit 1
}

Import-Module Pester -MinimumVersion 5.0.0 -ErrorAction Stop

Write-Host "=== WinRE Health Toolkit Test Suite ===" -ForegroundColor Cyan
Write-Host "Test Path: $TestPath" -ForegroundColor Gray
Write-Host "Pester Version: $($pesterModule.Version)" -ForegroundColor Gray
Write-Host ""

# Configure Pester
$pesterConfig = New-PesterConfiguration

# Paths
$pesterConfig.Run.Path = $TestPath
$pesterConfig.Run.Exit = $CI.IsPresent

# Output
$pesterConfig.Output.Verbosity = $Output

# Test filtering
if ($Tag) {
    $pesterConfig.Filter.Tag = $Tag
    Write-Host "Including tags: $($Tag -join ', ')" -ForegroundColor Yellow
}

if ($ExcludeTag -and -not $CI) {
    $pesterConfig.Filter.ExcludeTag = $ExcludeTag
    Write-Host "Excluding tags: $($ExcludeTag -join ', ')" -ForegroundColor Yellow
}

# CI mode
if ($CI) {
    $pesterConfig.TestResult.Enabled = $true
    $pesterConfig.TestResult.OutputFormat = 'JUnitXml'
    $pesterConfig.TestResult.OutputPath = $OutputFile
    Write-Host "CI Mode: Writing results to $OutputFile" -ForegroundColor Yellow
}

# Code coverage
if ($Coverage) {
    $pesterConfig.CodeCoverage.Enabled = $true
    $pesterConfig.CodeCoverage.Path = @(
        "$PSScriptRoot/Scripts/*.psm1",
        "$PSScriptRoot/Scripts/Modules/*.psm1"
    )
    $pesterConfig.CodeCoverage.OutputFormat = 'JaCoCo'
    $pesterConfig.CodeCoverage.OutputPath = "$PSScriptRoot/coverage.xml"
    Write-Host "Code Coverage: Enabled" -ForegroundColor Yellow
}

Write-Host ""

# Run tests
$startTime = Get-Date
$result = Invoke-Pester -Configuration $pesterConfig

$endTime = Get-Date
$duration = $endTime - $startTime

# Display summary
Write-Host ""
Write-Host "=== Test Summary ===" -ForegroundColor Cyan
Write-Host "Duration: $($duration.TotalSeconds.ToString('F2')) seconds" -ForegroundColor Gray
Write-Host "Total Tests: $($result.TotalCount)" -ForegroundColor White
Write-Host "Passed: $($result.PassedCount)" -ForegroundColor Green
Write-Host "Failed: $($result.FailedCount)" -ForegroundColor $(if ($result.FailedCount -gt 0) { 'Red' } else { 'Gray' })
Write-Host "Skipped: $($result.SkippedCount)" -ForegroundColor Yellow
Write-Host "Not Run: $($result.NotRunCount)" -ForegroundColor Gray

# Coverage summary
if ($Coverage -and $result.CodeCoverage) {
    Write-Host ""
    Write-Host "=== Code Coverage ===" -ForegroundColor Cyan
    
    $totalCommands = $result.CodeCoverage.CommandsAnalyzedCount
    $coveredCommands = $result.CodeCoverage.CommandsExecutedCount
    $coveragePercent = if ($totalCommands -gt 0) {
        [math]::Round(($coveredCommands / $totalCommands) * 100, 2)
    } else { 0 }

    Write-Host "Commands Analyzed: $totalCommands" -ForegroundColor Gray
    Write-Host "Commands Executed: $coveredCommands" -ForegroundColor Gray
    Write-Host "Coverage: $coveragePercent%" -ForegroundColor $(
        if ($coveragePercent -ge 80) { 'Green' }
        elseif ($coveragePercent -ge 60) { 'Yellow' }
        else { 'Red' }
    )

    # Missed commands
    if ($result.CodeCoverage.CommandsMissedCount -gt 0) {
        Write-Host ""
        Write-Host "Missed Commands: $($result.CodeCoverage.CommandsMissedCount)" -ForegroundColor Yellow
        
        $missedByFile = $result.CodeCoverage.MissedCommands | 
            Group-Object File | 
            Select-Object @{N='File';E={Split-Path $_.Name -Leaf}}, Count |
            Sort-Object Count -Descending |
            Select-Object -First 5

        Write-Host "Top files with missed coverage:" -ForegroundColor Gray
        $missedByFile | Format-Table -AutoSize | Out-String | Write-Host
    }

    Write-Host "Coverage report saved to: $PSScriptRoot/coverage.xml" -ForegroundColor Gray
}

# Test failures detail
if ($result.FailedCount -gt 0) {
    Write-Host ""
    Write-Host "=== Failed Tests ===" -ForegroundColor Red
    
    foreach ($test in $result.Failed) {
        Write-Host "  ❌ $($test.ExpandedPath)" -ForegroundColor Red
        Write-Host "     $($test.ErrorRecord.Exception.Message)" -ForegroundColor Gray
    }
}

# Performance warnings
$slowTests = $result.Passed | Where-Object { $_.Duration.TotalSeconds -gt 5 } | 
    Sort-Object { $_.Duration.TotalSeconds } -Descending |
    Select-Object -First 5

if ($slowTests) {
    Write-Host ""
    Write-Host "=== Slow Tests (>5s) ===" -ForegroundColor Yellow
    foreach ($test in $slowTests) {
        Write-Host "  ⚠️  $($test.ExpandedPath) - $($test.Duration.TotalSeconds.ToString('F2'))s" -ForegroundColor Yellow
    }
    Write-Host "  Consider tagging slow tests with -Tag 'Slow'" -ForegroundColor Gray
}

# Generate test coverage report
if ($Coverage) {
    Write-Host ""
    Write-Host "Generating additional coverage reports..." -ForegroundColor Cyan
    
    # Import test harness for coverage utilities
    Import-Module "$PSScriptRoot/Tests/TestHarness.psm1" -Force -ErrorAction SilentlyContinue
    
    if (Get-Command Get-TestCoverageReport -ErrorAction SilentlyContinue) {
        $coverageReport = Get-TestCoverageReport
        
        Write-Host ""
        Write-Host "=== Module Test Coverage ===" -ForegroundColor Cyan
        Write-Host "Total Modules: $($coverageReport.TotalModules)" -ForegroundColor Gray
        Write-Host "Tested Modules: $($coverageReport.TestedModules)" -ForegroundColor Green
        Write-Host "Untested Modules: $($coverageReport.TotalModules - $coverageReport.TestedModules)" -ForegroundColor Yellow
        Write-Host "Coverage: $($coverageReport.CoveragePercent)%" -ForegroundColor $(
            if ($coverageReport.CoveragePercent -ge 80) { 'Green' }
            elseif ($coverageReport.CoveragePercent -ge 60) { 'Yellow' }
            else { 'Red' }
        )

        if ($coverageReport.UntestedModules.Count -gt 0) {
            Write-Host ""
            Write-Host "Modules without tests:" -ForegroundColor Yellow
            foreach ($module in $coverageReport.UntestedModules) {
                Write-Host "  • $module" -ForegroundColor Gray
            }
        }
    }
}

Write-Host ""

# Exit with appropriate code
if ($CI) {
    if ($result.FailedCount -gt 0) {
        Write-Host "❌ Tests FAILED" -ForegroundColor Red
        exit 1
    } else {
        Write-Host "✅ Tests PASSED" -ForegroundColor Green
        exit 0
    }
} else {
    if ($result.FailedCount -gt 0) {
        Write-Host "❌ Some tests failed. Review failures above." -ForegroundColor Red
    } else {
        Write-Host "✅ All tests passed!" -ForegroundColor Green
    }
}
