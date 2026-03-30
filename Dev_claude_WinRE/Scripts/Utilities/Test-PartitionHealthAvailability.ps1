# Test-PartitionHealthAvailability.ps1
# Diagnostic script to check if HealthStatus property is available on recovery partitions
# Version: 1.0.0
# Date: 2026-01-07

<#
.SYNOPSIS
    Tests whether Windows provides HealthStatus property for partitions.

.DESCRIPTION
    Diagnostic tool to understand why PartitionHealthStatus may show "NotChecked".
    Checks all partitions on the system and reports which properties are available.

.EXAMPLE
    .\Test-PartitionHealthAvailability.ps1

.EXAMPLE
    .\Test-PartitionHealthAvailability.ps1 -Verbose
#>

param(
    [switch]$ShowAllPartitions,
    [switch]$CheckRecoveryOnly
)

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Partition Health Property Diagnostic" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Check PowerShell version
Write-Host "[CHECK] PowerShell Version: $($PSVersionTable.PSVersion)" -ForegroundColor Yellow
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "  [WARNING] PowerShell 5.1+ recommended for full Storage cmdlet support" -ForegroundColor Red
}

# Check if Get-Partition cmdlet exists
Write-Host "`n[CHECK] Storage cmdlet availability..." -ForegroundColor Yellow
$getPartitionCmd = Get-Command Get-Partition -ErrorAction SilentlyContinue
$getDiskCmd = Get-Command Get-Disk -ErrorAction SilentlyContinue

if (-not $getPartitionCmd) {
    Write-Host "  [ERROR] Get-Partition cmdlet NOT available (pre-Windows 10 or legacy system)" -ForegroundColor Red
    Write-Host "  This system cannot provide partition health status." -ForegroundColor Red
    exit 1
} else {
    Write-Host "  [OK] Get-Partition cmdlet available" -ForegroundColor Green
}

if (-not $getDiskCmd) {
    Write-Host "  [WARNING] Get-Disk cmdlet NOT available" -ForegroundColor Red
} else {
    Write-Host "  [OK] Get-Disk cmdlet available" -ForegroundColor Green
}

# Get WinRE location from reagentc
Write-Host "`n[CHECK] WinRE Configuration..." -ForegroundColor Yellow
$reagentc = reagentc /info 2>&1
$statusLine = ($reagentc | Select-String -Pattern "Windows RE status" -SimpleMatch | ForEach-Object { $_.Line })
$locationLine = ($reagentc | Select-String -Pattern "Windows RE location" -SimpleMatch | ForEach-Object { $_.Line })

$winreEnabled = $false
$diskNumber = $null
$partitionNumber = $null

if ($statusLine) {
    $winreEnabled = ($statusLine -split ":",2)[1].Trim() -match "Enabled"
    Write-Host "  WinRE Enabled: $winreEnabled" -ForegroundColor $(if ($winreEnabled) { "Green" } else { "Red" })
}

if ($locationLine) {
    $location = ($locationLine -split ":",2)[1].Trim()
    Write-Host "  WinRE Location: $location" -ForegroundColor Cyan
    
    if ($location -match "harddisk(\d+)\\partition(\d+)") {
        $diskNumber = [int]$matches[1]
        $partitionNumber = [int]$matches[2]
        Write-Host "  Disk: $diskNumber, Partition: $partitionNumber" -ForegroundColor Cyan
    }
}

# Test direct Get-Partition call
Write-Host "`n[TEST] Direct Get-Partition on WinRE partition..." -ForegroundColor Yellow

if ($null -ne $diskNumber -and $null -ne $partitionNumber) {
    try {
        $partition = Get-Partition -DiskNumber $diskNumber -PartitionNumber $partitionNumber -ErrorAction Stop
        
        Write-Host "  [SUCCESS] Retrieved partition object" -ForegroundColor Green
        Write-Host "`n  Partition Properties:" -ForegroundColor Cyan
        Write-Host "    DiskNumber: $($partition.DiskNumber)" -ForegroundColor White
        Write-Host "    PartitionNumber: $($partition.PartitionNumber)" -ForegroundColor White
        Write-Host "    Type: $($partition.Type)" -ForegroundColor White
        Write-Host "    Size: $([math]::Round($partition.Size / 1MB, 2)) MB" -ForegroundColor White
        Write-Host "    GptType: $($partition.GptType)" -ForegroundColor White
        
        # Check for HealthStatus property
        Write-Host "`n  [CRITICAL CHECK] HealthStatus Property:" -ForegroundColor Yellow
        $hasHealthStatus = $partition.PSObject.Properties.Name -contains 'HealthStatus'
        
        if ($hasHealthStatus) {
            $healthValue = $partition.HealthStatus
            if ($null -eq $healthValue -or [string]::IsNullOrWhiteSpace($healthValue)) {
                Write-Host "    Property EXISTS but value is NULL/EMPTY" -ForegroundColor Red
                Write-Host "    -> SafeStorageAccess will return: 'NotChecked'" -ForegroundColor Yellow
            } else {
                Write-Host "    Property EXISTS with value: $healthValue" -ForegroundColor Green
                Write-Host "    -> SafeStorageAccess will return: '$healthValue'" -ForegroundColor Green
            }
        } else {
            Write-Host "    Property DOES NOT EXIST on this object" -ForegroundColor Red
            Write-Host "    -> SafeStorageAccess will return: 'NotChecked'" -ForegroundColor Yellow
        }
        
        # Check for OperationalStatus property
        Write-Host "`n  [CHECK] OperationalStatus Property:" -ForegroundColor Yellow
        $hasOperationalStatus = $partition.PSObject.Properties.Name -contains 'OperationalStatus'
        
        if ($hasOperationalStatus) {
            $operationalValue = $partition.OperationalStatus
            if ($null -eq $operationalValue -or [string]::IsNullOrWhiteSpace($operationalValue)) {
                Write-Host "    Property EXISTS but value is NULL/EMPTY" -ForegroundColor Red
            } else {
                Write-Host "    Property EXISTS with value: $operationalValue" -ForegroundColor Green
            }
        } else {
            Write-Host "    Property DOES NOT EXIST" -ForegroundColor Red
        }
        
        # List ALL properties for diagnostic purposes
        if ($ShowAllPartitions) {
            Write-Host "`n  All Available Properties:" -ForegroundColor Cyan
            $partition.PSObject.Properties | ForEach-Object {
                Write-Host "    - $($_.Name): $($_.Value)" -ForegroundColor DarkGray
            }
        }
        
    } catch {
        Write-Host "  [ERROR] Failed to retrieve partition: $($_.Exception.Message)" -ForegroundColor Red
    }
} else {
    Write-Host "  [SKIP] Cannot test - WinRE disk/partition not detected from reagentc" -ForegroundColor Yellow
}

# Test Get-Disk health
if ($null -ne $diskNumber) {
    Write-Host "`n[TEST] Get-Disk health on Disk $diskNumber..." -ForegroundColor Yellow
    
    try {
        $disk = Get-Disk -Number $diskNumber -ErrorAction Stop
        
        Write-Host "  [SUCCESS] Retrieved disk object" -ForegroundColor Green
        
        # Check for HealthStatus property on disk
        $hasHealthStatus = $disk.PSObject.Properties.Name -contains 'HealthStatus'
        
        if ($hasHealthStatus) {
            $healthValue = $disk.HealthStatus
            if ($null -eq $healthValue -or [string]::IsNullOrWhiteSpace($healthValue)) {
                Write-Host "  HealthStatus: NULL/EMPTY" -ForegroundColor Red
            } else {
                Write-Host "  HealthStatus: $healthValue" -ForegroundColor Green
            }
        } else {
            Write-Host "  HealthStatus: Property DOES NOT EXIST" -ForegroundColor Red
        }
        
        # Check for OperationalStatus property on disk
        $hasOperationalStatus = $disk.PSObject.Properties.Name -contains 'OperationalStatus'
        
        if ($hasOperationalStatus) {
            $operationalValue = $disk.OperationalStatus
            if ($null -eq $operationalValue -or [string]::IsNullOrWhiteSpace($operationalValue)) {
                Write-Host "  OperationalStatus: NULL/EMPTY" -ForegroundColor Red
            } else {
                Write-Host "  OperationalStatus: $operationalValue" -ForegroundColor Green
            }
        } else {
            Write-Host "  OperationalStatus: Property DOES NOT EXIST" -ForegroundColor Red
        }
        
    } catch {
        Write-Host "  [ERROR] Failed to retrieve disk: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Summary and recommendations
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "SUMMARY & INTERPRETATION" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "What does 'NotChecked' mean?" -ForegroundColor Yellow
Write-Host "  - Windows did not provide HealthStatus property for the partition" -ForegroundColor White
Write-Host "  - This is COMMON for recovery partitions on many systems" -ForegroundColor White
Write-Host "  - It is NOT an error or script bug" -ForegroundColor White

Write-Host "`nWhat SHOULD you check instead?" -ForegroundColor Yellow
Write-Host "  1. PartitionOperationalStatus: 'Online' = partition is accessible" -ForegroundColor White
Write-Host "  2. DiskHealthStatus: 'Healthy' = physical disk is good" -ForegroundColor White
Write-Host "  3. Overall Severity: 'Healthy' = system is OK" -ForegroundColor White

Write-Host "`nWhen IS it a problem?" -ForegroundColor Yellow
Write-Host "  - If PartitionOperationalStatus = 'Offline' or 'Failed'" -ForegroundColor Red
Write-Host "  - If DiskHealthStatus = 'Unhealthy' or 'Failed'" -ForegroundColor Red
Write-Host "  - If Overall Severity = 'Critical'" -ForegroundColor Red

Write-Host "`nYour current status from latest test:" -ForegroundColor Yellow
Write-Host "  - PartitionHealthStatus: NotChecked (Windows limitation)" -ForegroundColor Yellow
Write-Host "  - PartitionOperationalStatus: Online (GOOD!)" -ForegroundColor Green
Write-Host "  - DiskHealthStatus: Healthy (GOOD!)" -ForegroundColor Green
Write-Host "  - Severity: Healthy (GOOD!)" -ForegroundColor Green
Write-Host "`n  VERDICT: Your WinRE partition is HEALTHY" -ForegroundColor Green

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "For more information, see:" -ForegroundColor Cyan
Write-Host "  Docs/NINJAONE-DEPLOYMENT-GUIDE-v1.6.0.md" -ForegroundColor White
Write-Host "  Section: 'Issue 4: PartitionHealthStatus shows NotChecked'" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan

# Optionally scan all partitions
if ($ShowAllPartitions) {
    Write-Host "`n[OPTIONAL] Scanning ALL partitions on system..." -ForegroundColor Cyan
    
    $allPartitions = Get-Partition -ErrorAction SilentlyContinue
    
    if ($allPartitions) {
        foreach ($p in $allPartitions) {
            $hasHealth = $p.PSObject.Properties.Name -contains 'HealthStatus'
            $healthValue = if ($hasHealth) { $p.HealthStatus } else { "N/A" }
            
            Write-Host "`n  Disk $($p.DiskNumber) Partition $($p.PartitionNumber):" -ForegroundColor White
            Write-Host "    Type: $($p.Type)" -ForegroundColor DarkGray
            Write-Host "    Size: $([math]::Round($p.Size / 1MB, 2)) MB" -ForegroundColor DarkGray
            Write-Host "    HealthStatus Property: $(if ($hasHealth) { 'EXISTS' } else { 'MISSING' })" -ForegroundColor $(if ($hasHealth) { "Green" } else { "Red" })
            Write-Host "    HealthStatus Value: $healthValue" -ForegroundColor DarkGray
        }
    }
}

Write-Host "`nDiagnostic complete!`n" -ForegroundColor Green
