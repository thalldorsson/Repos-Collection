<#
.SYNOPSIS
    Generates mock WinRE health data for testing dashboards and queries.

.DESCRIPTION
    Creates realistic mock data for the WinRE Health Monitoring solution.
    Generates device health records with various vulnerability states, 
    manufacturers, models, and trend data for testing dashboards,
    queries, and demonstrations without production data.

.PARAMETER DeviceCount
    Number of mock devices to generate. Default: 100

.PARAMETER VulnerabilityRate
    Percentage of devices that should be vulnerable (0-100). Default: 15

.PARAMETER OutputPath
    Path to save the JSON output file. Default: C:\Temp\mock-winre-data.json

.PARAMETER SendToLogAnalytics
    If specified, sends data directly to Log Analytics instead of file.

.PARAMETER WorkspaceId
    Log Analytics Workspace ID (required if SendToLogAnalytics is specified).

.PARAMETER WorkspaceKey
    Log Analytics Workspace Key (required if SendToLogAnalytics is specified).

.PARAMETER IncludeTrendData
    Generate historical trend data for each device. Default: $true

.PARAMETER DaysOfHistory
    Number of days of historical data to generate. Default: 30

.EXAMPLE
    .\New-MockData.ps1 -DeviceCount 100 -VulnerabilityRate 15
    Generates 100 mock devices with 15% vulnerability rate to default output path.

.EXAMPLE
    .\New-MockData.ps1 -DeviceCount 500 -OutputPath "C:\Test\mock-data.json"
    Generates 500 mock devices to custom output path.

.EXAMPLE
    .\New-MockData.ps1 -SendToLogAnalytics -WorkspaceId "abc123" -WorkspaceKey "key123"
    Generates mock data and sends directly to Log Analytics.

.NOTES
    Author: WinRE Health Monitor Team
    Version: 1.4.0
    Purpose: Testing dashboards, queries, and demonstrations
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 10000)]
    [int]$DeviceCount = 100,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 100)]
    [double]$VulnerabilityRate = 15,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "C:\Temp\mock-winre-data.json",

    [Parameter(Mandatory = $false)]
    [switch]$SendToLogAnalytics,

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceId,

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceKey,

    [Parameter(Mandatory = $false)]
    [bool]$IncludeTrendData = $true,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 90)]
    [int]$DaysOfHistory = 30
)

# Import LogAnalyticsIngestion module for Azure Log Analytics ingestion
$laModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\LogAnalyticsIngestion.psm1'
if (Test-Path $laModulePath) {
    Import-Module $laModulePath -Force -ErrorAction SilentlyContinue
} else {
    Write-Warning "LogAnalyticsIngestion module not found at: $laModulePath. Azure ingestion will not be available."
}

#region Configuration Data
$Script:Manufacturers = @(
    @{ Name = "Dell Inc."; Weight = 35 }
    @{ Name = "HP"; Weight = 30 }
    @{ Name = "Lenovo"; Weight = 25 }
    @{ Name = "Microsoft Corporation"; Weight = 10 }
)

$Script:ModelsByManufacturer = @{
    "Dell Inc." = @(
        "Latitude 7420", "Latitude 7430", "Latitude 5520", "Latitude 5530",
        "Precision 5570", "Precision 7670", "OptiPlex 7090", "OptiPlex 3090",
        "XPS 15 9520", "XPS 13 9315"
    )
    "HP" = @(
        "EliteBook 840 G8", "EliteBook 850 G8", "EliteBook 840 G9", "EliteBook 860 G9",
        "ProBook 450 G9", "ProBook 650 G9", "ZBook Fury 15 G8", "ZBook Studio G9",
        "EliteDesk 800 G9", "ProDesk 600 G6"
    )
    "Lenovo" = @(
        "ThinkPad X1 Carbon Gen 10", "ThinkPad X1 Carbon Gen 11", "ThinkPad T14 Gen 3",
        "ThinkPad T16 Gen 1", "ThinkPad E15 Gen 4", "ThinkPad L15 Gen 3",
        "ThinkCentre M90q Gen 3", "ThinkCentre M70q Gen 3"
    )
    "Microsoft Corporation" = @(
        "Surface Laptop 4", "Surface Laptop 5", "Surface Laptop Studio",
        "Surface Pro 8", "Surface Pro 9", "Surface Go 3"
    )
}

$Script:OSVersions = @(
    @{ Build = "10.0.22631"; Name = "Windows 11 23H2"; Weight = 40 }
    @{ Build = "10.0.22621"; Name = "Windows 11 22H2"; Weight = 30 }
    @{ Build = "10.0.19045"; Name = "Windows 10 22H2"; Weight = 25 }
    @{ Build = "10.0.19044"; Name = "Windows 10 21H2"; Weight = 5 }
)

$Script:CriticalityLevels = @(
    @{ Level = "Critical"; Weight = 5 }
    @{ Level = "High"; Weight = 15 }
    @{ Level = "Medium"; Weight = 30 }
    @{ Level = "Standard"; Weight = 50 }
)

$Script:NamePrefixes = @(
    @{ Prefix = "LAPTOP"; Weight = 60 }
    @{ Prefix = "DESKTOP"; Weight = 25 }
    @{ Prefix = "WS"; Weight = 10 }
    @{ Prefix = "VDI"; Weight = 5 }
)
#endregion

#region Helper Functions
function Get-WeightedRandom {
    param(
        [array]$Items,
        [string]$WeightProperty = "Weight"
    )
    
    $totalWeight = ($Items | Measure-Object -Property $WeightProperty -Sum).Sum
    $random = Get-Random -Minimum 0 -Maximum $totalWeight
    $cumulative = 0
    
    foreach ($item in $Items) {
        $cumulative += $item.$WeightProperty
        if ($random -lt $cumulative) {
            return $item
        }
    }
    
    return $Items[-1]
}

function New-MockComputerName {
    $prefix = (Get-WeightedRandom -Items $Script:NamePrefixes).Prefix
    $suffix = Get-Random -Minimum 10000 -Maximum 99999
    return "$prefix-$suffix"
}

function New-MockDeviceId {
    return [Guid]::NewGuid().ToString()
}

function New-MockPartitionData {
    param(
        [bool]$IsVulnerable
    )
    
    if ($IsVulnerable) {
        # Vulnerable devices have smaller partitions
        $totalSize = Get-Random -Minimum 250 -Maximum 450
        $freeSpace = Get-Random -Minimum 20 -Maximum 100
    }
    else {
        # Healthy devices have adequate partition sizes
        $totalSize = Get-Random -Minimum 500 -Maximum 1200
        $freeSpace = Get-Random -Minimum 100 -Maximum 400
    }
    
    return @{
        TotalSizeMB = $totalSize
        FreeSpaceMB = $freeSpace
        UsedSpaceMB = $totalSize - $freeSpace
    }
}

function New-MockTrendData {
    param(
        [bool]$IsVulnerable,
        [int]$DaysOfHistory
    )
    
    if (-not $IsVulnerable) {
        return @{
            DeclineRateMBPerDay = [Math]::Round((Get-Random -Minimum -5 -Maximum 5) / 10.0, 2)
            DaysUntilCritical = 999
            TrendDirection = "Stable"
        }
    }
    
    # Vulnerable devices have declining trends
    $declineRate = [Math]::Round((Get-Random -Minimum 5 -Maximum 50) / 10.0, 2)
    $currentFree = Get-Random -Minimum 20 -Maximum 100
    $daysUntilCritical = [Math]::Max(1, [Math]::Round($currentFree / $declineRate, 0))
    
    $trendDirection = switch ($true) {
        ($declineRate -gt 2) { "Declining" }
        ($declineRate -lt -0.5) { "Growing" }
        default { "Stable" }
    }
    
    return @{
        DeclineRateMBPerDay = $declineRate
        DaysUntilCritical = [int]$daysUntilCritical
        TrendDirection = $trendDirection
    }
}

function New-MockConfidenceScore {
    param(
        [bool]$IsVulnerable,
        [string]$BitLockerStatus,
        [bool]$SecureBootEnabled,
        [bool]$UEFIMode
    )
    
    $score = 50  # Base score
    
    # Add points for security features
    if ($SecureBootEnabled) { $score += 15 }
    if ($UEFIMode) { $score += 15 }
    if ($BitLockerStatus -eq "On") { $score += 10 }
    
    # Vulnerability impacts confidence
    if ($IsVulnerable) { $score -= 10 }
    
    # Add some randomness
    $score += Get-Random -Minimum -5 -Maximum 10
    
    return [Math]::Max(0, [Math]::Min(100, $score))
}

# Send-ToLogAnalytics function now imported from LogAnalyticsIngestion.psm1 module

#endregion

#region Main Logic
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " WinRE Health Mock Data Generator v1.4.0" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Validate parameters for Log Analytics
if ($SendToLogAnalytics) {
    if (-not $WorkspaceId -or -not $WorkspaceKey) {
        throw "WorkspaceId and WorkspaceKey are required when using -SendToLogAnalytics"
    }
    Write-Host "Mode: Send to Log Analytics" -ForegroundColor Yellow
}
else {
    Write-Host "Mode: Output to file" -ForegroundColor Yellow
    
    # Ensure output directory exists
    $outputDir = Split-Path -Parent $OutputPath
    if ($outputDir -and -not (Test-Path $outputDir)) {
        New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
        Write-Host "Created directory: $outputDir" -ForegroundColor Gray
    }
}

Write-Host "Generating $DeviceCount mock devices with $VulnerabilityRate% vulnerability rate..." -ForegroundColor Yellow
Write-Host ""

$mockData = @()
$vulnerableCount = 0
$healthyCount = 0

for ($i = 1; $i -le $DeviceCount; $i++) {
    # Progress indicator
    if ($i % 100 -eq 0 -or $i -eq $DeviceCount) {
        $pct = [Math]::Round(($i / $DeviceCount) * 100, 0)
        Write-Host "`r  Progress: $i/$DeviceCount ($pct%)" -NoNewline -ForegroundColor Gray
    }
    
    # Determine if this device is vulnerable
    $isVulnerable = (Get-Random -Minimum 0 -Maximum 100) -lt $VulnerabilityRate
    
    if ($isVulnerable) { $vulnerableCount++ } else { $healthyCount++ }
    
    # Select manufacturer and model
    $manufacturer = (Get-WeightedRandom -Items $Script:Manufacturers).Name
    $model = $Script:ModelsByManufacturer[$manufacturer] | Get-Random
    
    # Select OS version
    $osInfo = Get-WeightedRandom -Items $Script:OSVersions
    
    # Select criticality
    $criticality = (Get-WeightedRandom -Items $Script:CriticalityLevels).Level
    
    # Generate partition data
    $partition = New-MockPartitionData -IsVulnerable $isVulnerable
    
    # Generate trend data
    $trend = if ($IncludeTrendData) {
        New-MockTrendData -IsVulnerable $isVulnerable -DaysOfHistory $DaysOfHistory
    }
    else {
        $null
    }
    
    # Generate security settings
    $secureBootEnabled = (Get-Random -Minimum 0 -Maximum 100) -lt 90  # 90% have SecureBoot
    $uefiMode = (Get-Random -Minimum 0 -Maximum 100) -lt 95  # 95% are UEFI
    $bitLockerStatus = if ((Get-Random -Minimum 0 -Maximum 100) -lt 80) { "On" } else { "Off" }
    
    # Generate confidence score
    $confidenceScore = New-MockConfidenceScore -IsVulnerable $isVulnerable `
        -BitLockerStatus $bitLockerStatus -SecureBootEnabled $secureBootEnabled -UEFIMode $uefiMode
    
    # Determine severity
    $severity = switch ($true) {
        ($isVulnerable -and $criticality -in @("Critical", "High")) { "Critical" }
        ($isVulnerable -and $partition.FreeSpaceMB -lt 50) { "High" }
        ($isVulnerable) { "Medium" }
        default { "Low" }
    }
    
    # Determine remediation readiness
    $remediationReady = $isVulnerable -and 
        ((Get-Random -Minimum 0 -Maximum 100) -lt 80) -and 
        ($partition.FreeSpaceMB -gt 30)
    
    # Build device record
    $deviceRecord = @{
        Timestamp                    = (Get-Date).AddHours(-(Get-Random -Minimum 0 -Maximum 24)).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        DeviceId                     = New-MockDeviceId
        ComputerName                 = New-MockComputerName
        Manufacturer                 = $manufacturer
        Model                        = $model
        SerialNumber                 = "SN$(Get-Random -Minimum 100000000 -Maximum 999999999)"
        OSVersion                    = $osInfo.Name
        OSBuild                      = $osInfo.Build
        KB5034441Vulnerable          = $isVulnerable
        WinREEnabled                 = -not $isVulnerable -or ((Get-Random -Minimum 0 -Maximum 100) -lt 95)
        WinRELocation                = "\\?\GLOBALROOT\device\harddisk0\partition$(Get-Random -Minimum 3 -Maximum 6)\Recovery\WindowsRE"
        PartitionSizeMB              = $partition.TotalSizeMB
        PartitionFreeMB              = $partition.FreeSpaceMB
        PartitionUsedMB              = $partition.UsedSpaceMB
        SecureBootEnabled            = $secureBootEnabled
        UEFIMode                     = $uefiMode
        BitLockerStatus              = $bitLockerStatus
        ConfidenceScore              = $confidenceScore
        Severity                     = $severity
        DeviceCriticality            = $criticality
        RemediationReady             = $remediationReady
        IsVirtualMachine             = (Get-Random -Minimum 0 -Maximum 100) -lt 10  # 10% VMs
        PendingReboot                = (Get-Random -Minimum 0 -Maximum 100) -lt 5   # 5% pending
        ScriptVersion                = "1.4.0"
        ExecutionMode                = "Mock"
    }
    
    # Add trend data if enabled
    if ($trend) {
        $deviceRecord.PartitionFreeTrendMBPerDay = $trend.DeclineRateMBPerDay
        $deviceRecord.DaysUntilSpaceCritical = $trend.DaysUntilCritical
        $deviceRecord.TrendDirection = $trend.TrendDirection
    }
    
    $mockData += $deviceRecord
}

Write-Host "`n" -NoNewline
Write-Host ""
Write-Host "Generation complete!" -ForegroundColor Green
Write-Host "  Total devices: $DeviceCount" -ForegroundColor White
Write-Host "  Vulnerable:    $vulnerableCount ($([Math]::Round($vulnerableCount / $DeviceCount * 100, 1))%)" -ForegroundColor Yellow
Write-Host "  Healthy:       $healthyCount ($([Math]::Round($healthyCount / $DeviceCount * 100, 1))%)" -ForegroundColor Green
Write-Host ""

# Output the data
if ($SendToLogAnalytics) {
    Write-Host "Sending data to Log Analytics..." -ForegroundColor Yellow
    
    # Send in batches of 100
    $batchSize = 100
    $batches = [Math]::Ceiling($mockData.Count / $batchSize)
    
    for ($b = 0; $b -lt $batches; $b++) {
        $start = $b * $batchSize
        $batch = $mockData | Select-Object -Skip $start -First $batchSize
        $json = $batch | ConvertTo-Json -Depth 10
        
        try {
            $success = Send-ToLogAnalytics -WorkspaceId $WorkspaceId -WorkspaceKey $WorkspaceKey `
                -LogType "WinREHealth" -JsonBody $json
            
            if ($success) {
                Write-Host "  Batch $($b + 1)/$batches sent successfully" -ForegroundColor Gray
            }
            else {
                Write-Warning "  Batch $($b + 1)/$batches may have failed"
            }
        }
        catch {
            Write-Error "Failed to send batch $($b + 1): $_"
        }
        
        # Small delay between batches
        if ($b -lt ($batches - 1)) {
            Start-Sleep -Milliseconds 500
        }
    }
    
    Write-Host ""
    Write-Host "✓ Data sent to Log Analytics workspace" -ForegroundColor Green
    Write-Host "  Workspace ID: $WorkspaceId" -ForegroundColor Gray
    Write-Host "  Table: WinREHealth_CL" -ForegroundColor Gray
}
else {
    # Output to file
    $mockData | ConvertTo-Json -Depth 10 | Out-File -FilePath $OutputPath -Encoding UTF8
    
    Write-Host "✓ Data saved to: $OutputPath" -ForegroundColor Green
    
    $fileSize = (Get-Item $OutputPath).Length / 1KB
    Write-Host "  File size: $([Math]::Round($fileSize, 1)) KB" -ForegroundColor Gray
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Mock Data Generation Complete" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Return summary for pipeline usage
return @{
    TotalDevices     = $DeviceCount
    VulnerableCount  = $vulnerableCount
    HealthyCount     = $healthyCount
    VulnerabilityRate = [Math]::Round($vulnerableCount / $DeviceCount * 100, 1)
    OutputPath       = if (-not $SendToLogAnalytics) { $OutputPath } else { $null }
    SentToLogAnalytics = $SendToLogAnalytics.IsPresent
}
#endregion
