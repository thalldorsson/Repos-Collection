<#
.SYNOPSIS
    Establishes performance baselines for the WinRE Health Toolkit

.DESCRIPTION
    Runs comprehensive performance benchmarks and saves results as baselines
    for future regression testing.

.PARAMETER OutputPath
    Path to save baseline results

.PARAMETER Iterations
    Number of iterations for each benchmark

.PARAMETER Force
    Overwrite existing baseline file

.EXAMPLE
    .\Set-PerformanceBaseline.ps1 -OutputPath "Tests/Performance/Results/baseline.json"

.NOTES
    Version: 1.0.0
    Requires: Pester 5.0+
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputPath = "$PSScriptRoot/Tests/Performance/Results/baseline.json",

    [Parameter()]
    [int]$Iterations = 100,

    [Parameter()]
    [switch]$Force
)

# Ensure output directory exists
$outputDir = Split-Path -Path $OutputPath -Parent
if ($outputDir -and -not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

# Check if baseline already exists
if ((Test-Path $OutputPath) -and -not $Force) {
    Write-Error "Baseline file already exists at: $OutputPath"
    Write-Host "Use -Force to overwrite existing baseline." -ForegroundColor Yellow
    exit 1
}

Write-Host "=== Establishing Performance Baselines ===" -ForegroundColor Cyan
Write-Host "This will run comprehensive benchmarks and save results as baselines." -ForegroundColor Gray
Write-Host "Iterations per test: $Iterations" -ForegroundColor Gray
Write-Host ""

# Import modules
Import-Module "$PSScriptRoot/Tests/Performance/PerformanceBenchmark.psm1" -Force
Import-Module "$PSScriptRoot/Tests/TestHarness.psm1" -Force

$modulePath = "$PSScriptRoot/Scripts"
$results = @()

# Test 1: JSON Serialization
Write-Host "Running: JSON Serialization..." -ForegroundColor Yellow
$healthData = New-MockWinREHealthData
$perf = Measure-Performance -Name "JSON Serialization" -Iterations $Iterations -WarmupRuns 10 -ScriptBlock {
    $healthData | ConvertTo-Json -Depth 5 | Out-Null
}
$results += $perf
Write-Host "  ✓ Complete - Avg: $($perf.AvgMs)ms" -ForegroundColor Green

# Test 2: History File Read
Write-Host "Running: History File Read..." -ForegroundColor Yellow
$testDir = New-TestDirectory
$historyFile = Join-Path $testDir "history.json"
$history = 1..30 | ForEach-Object { New-MockWinREHealthData }
$history | ConvertTo-Json | Set-Content -Path $historyFile

$perf = Measure-Performance -Name "History File Read" -Iterations 50 -WarmupRuns 5 -ScriptBlock {
    Get-Content $historyFile -Raw | ConvertFrom-Json | Out-Null
}
$results += $perf
Write-Host "  ✓ Complete - Avg: $($perf.AvgMs)ms" -ForegroundColor Green
Remove-TestDirectory -Path $testDir

# Test 3: Trend Direction Calculation
Write-Host "Running: Trend Direction Calculation..." -ForegroundColor Yellow
Import-Module "$modulePath/TrendAnalysis.psm1" -Force
$dataPoints = 1..100 | ForEach-Object { $_ * 10 }

$perf = Measure-Performance -Name "Trend Direction Calculation" -Iterations $Iterations -WarmupRuns 10 -ScriptBlock {
    Get-TrendDirection -DataPoints $dataPoints | Out-Null
}
$results += $perf
Write-Host "  ✓ Complete - Avg: $($perf.AvgMs)ms" -ForegroundColor Green
Remove-Module TrendAnalysis -ErrorAction SilentlyContinue

# Test 4: Partition Trend Calculation
Write-Host "Running: Partition Trend Calculation..." -ForegroundColor Yellow
Import-Module "$modulePath/TrendAnalysis.psm1" -Force
$testDir = New-TestDirectory
$historyFile = Join-Path $testDir "history.json"

$history = 1..30 | ForEach-Object {
    @{
        Timestamp = (Get-Date).AddDays(-$_).ToString('o')
        PartitionFreeMB = 500 - $_
    }
}
$history | ConvertTo-Json | Set-Content -Path $historyFile

$perf = Measure-Performance -Name "Partition Trend Calculation" -Iterations 20 -WarmupRuns 2 -ScriptBlock {
    Get-PartitionFreeSpaceTrend -HistoryFilePath $historyFile | Out-Null
}
$results += $perf
Write-Host "  ✓ Complete - Avg: $($perf.AvgMs)ms" -ForegroundColor Green
Remove-TestDirectory -Path $testDir
Remove-Module TrendAnalysis -ErrorAction SilentlyContinue

# Test 5: Device Criticality Classification
Write-Host "Running: Device Criticality Classification..." -ForegroundColor Yellow
Import-Module "$modulePath/DeviceCriticality.psm1" -Force
$deviceInfo = @{
    ComputerName = 'TEST-DEVICE'
    UserRole = 'Developer'
    Department = 'Engineering'
}

$perf = Measure-Performance -Name "Device Criticality Classification" -Iterations $Iterations -WarmupRuns 10 -ScriptBlock {
    Get-DeviceCriticality -DeviceInfo $deviceInfo | Out-Null
}
$results += $perf
Write-Host "  ✓ Complete - Avg: $($perf.AvgMs)ms" -ForegroundColor Green
Remove-Module DeviceCriticality -ErrorAction SilentlyContinue

# Test 6: Device List Prioritization (100 devices)
Write-Host "Running: Device List Prioritization (100 devices)..." -ForegroundColor Yellow
Import-Module "$modulePath/DeviceCriticality.psm1" -Force
$devices = 1..100 | ForEach-Object {
    @{
        ComputerName = "DEVICE-$_"
        UserRole = @('Employee', 'Developer', 'Executive', 'Admin')[$_ % 4]
        Department = @('IT', 'Finance', 'Marketing', 'Executive')[$_ % 4]
    }
}

$perf = Measure-Performance -Name "Device List Prioritization (100 devices)" -Iterations 10 -WarmupRuns 2 -ScriptBlock {
    Get-PrioritizedDeviceList -Devices $devices | Out-Null
}
$results += $perf
Write-Host "  ✓ Complete - Avg: $($perf.AvgMs)ms" -ForegroundColor Green
Remove-Module DeviceCriticality -ErrorAction SilentlyContinue

# Test 7: Module Load - TrendAnalysis
Write-Host "Running: TrendAnalysis Module Load..." -ForegroundColor Yellow
$perf = Measure-Performance -Name "TrendAnalysis Module Load" -Iterations 5 -ScriptBlock {
    Import-Module "$modulePath/TrendAnalysis.psm1" -Force
    Remove-Module TrendAnalysis -Force
}
$results += $perf
Write-Host "  ✓ Complete - Avg: $($perf.AvgMs)ms" -ForegroundColor Green

# Test 8: Module Load - DeviceCriticality
Write-Host "Running: DeviceCriticality Module Load..." -ForegroundColor Yellow
$perf = Measure-Performance -Name "DeviceCriticality Module Load" -Iterations 5 -ScriptBlock {
    Import-Module "$modulePath/DeviceCriticality.psm1" -Force
    Remove-Module DeviceCriticality -Force
}
$results += $perf
Write-Host "  ✓ Complete - Avg: $($perf.AvgMs)ms" -ForegroundColor Green

# Test 9: Mock Data Generation
Write-Host "Running: Mock Data Generation..." -ForegroundColor Yellow
$perf = Measure-Performance -Name "Mock Data Generation" -Iterations $Iterations -WarmupRuns 10 -ScriptBlock {
    New-MockWinREHealthData | Out-Null
}
$results += $perf
Write-Host "  ✓ Complete - Avg: $($perf.AvgMs)ms" -ForegroundColor Green

# Save results
Write-Host ""
Write-Host "Saving baselines to: $OutputPath" -ForegroundColor Cyan
$results | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath

# Display summary
Write-Host ""
Write-Host "=== Baseline Summary ===" -ForegroundColor Cyan
$results | ForEach-Object {
    Write-Host "  $($_.Name): $($_.AvgMs)ms (Min: $($_.MinMs)ms, Max: $($_.MaxMs)ms)" -ForegroundColor Gray
}

Write-Host ""
Write-Host "✓ Baselines established successfully!" -ForegroundColor Green
Write-Host "  File: $OutputPath" -ForegroundColor Gray
Write-Host "  Tests: $($results.Count)" -ForegroundColor Gray
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Commit baseline file to repository" -ForegroundColor Gray
Write-Host "  2. Run regression tests: Invoke-Pester -Path Tests\Performance\Regression.Performance.Tests.ps1" -ForegroundColor Gray
Write-Host "  3. Review baselines in PERFORMANCE-BASELINES.md" -ForegroundColor Gray

# Cleanup
Remove-Module PerformanceBenchmark -ErrorAction SilentlyContinue
Remove-Module TestHarness -ErrorAction SilentlyContinue
