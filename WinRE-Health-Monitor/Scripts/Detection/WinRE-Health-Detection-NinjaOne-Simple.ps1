#Requires -Version 5.1

<#
.SYNOPSIS
  Lightweight WinRE Health Detection for NinjaOne — NinjaOne fields only.

.DESCRIPTION
  Detects WinRE health issues and writes results to NinjaOne Device Custom Fields.
  No Azure Log Analytics, no external dependencies — pure field population.
  
  Outputs:
  - winreEnabled, winreSeverity, winreKB5034441Vulnerable, winreConfidenceScore
  - winreRecommendation, winrePartitionSizeMB, winrePartitionFreeMB, winreLastCheck
  - winreBitLockerStatus, winreWindows11Ready, winreSecureBoot, winreFirmwareType
  - Plus 21 extended metrics (TPM, partition details, etc.)

.NOTES
  Author: Thorsteinn Halldorsson
  Version: 1.7.0-ninja-simple
  Date: 2026-01-27
  
  Run via NinjaOne Automation Policy for full Ninja-Property-Set functionality.
  Running manually will skip field updates (expected behavior).
#>

param(
    [switch]$TestMode,
    [switch]$OutputJson
)

# Import SafeStorageAccess module for null-safe storage cmdlet wrappers
$safeStorageModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\SafeStorageAccess.psm1'
if (Test-Path $safeStorageModulePath) {
    Import-Module $safeStorageModulePath -Force -ErrorAction SilentlyContinue
} else {
    Write-Warning "SafeStorageAccess module not found at: $safeStorageModulePath. Storage health checks may be limited on legacy systems."
}

#region Configuration
$ScriptVersion = "1.7.0-ninja-simple"
$ScriptStartTime = Get-Date

# Define required Ninja fields (will attempt to populate all)
$NinjaFields = @(
    'winreEnabled','winreSeverity','winreKB5034441Vulnerable','winreConfidenceScore',
    'winreRecommendation','winrePartitionSizeMB','winrePartitionFreeMB','winreLastCheck',
    'winreBitLockerStatus','winreWindows11Ready','winreSecureBoot','winreFirmwareType'
)
#endregion

#region Functions
function Write-Verbose-Log {
    param([string]$Message)
    if ($VerbosePreference -eq 'Continue' -or $TestMode) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message"
    }
}

function Set-NinjaField {
    param(
        [Parameter(Mandatory=$true)][string]$FieldName,
        [Parameter(Mandatory=$false)][object]$Value
    )
    try {
        $cmd = Get-Command Ninja-Property-Set -ErrorAction SilentlyContinue
        if (-not $cmd) {
            Write-Verbose-Log "Ninja-Property-Set not available (expected if running manually)"
            return $false
        }

        if ($null -eq $Value) {
            Write-Verbose-Log "Skipping field '$FieldName' because value is null"
            return $false
        }

        # Map certain fields to the formats expected by Ninja Device Custom Fields
        if ($FieldName -ieq 'winreSeverity') {
            switch -Wildcard ($Value) {
                'Healthy'  { $out = $false; break }
                'Warning'  { $out = $true ; break }
                'Critical' { $out = $true ; break }
                default    { $out = $false; break }
            }
            $valueToSet = $out
        } elseif ($FieldName -ieq 'winreFirmwareType') {
            switch -Wildcard ($Value) {
                'UEFI'   { $valueToSet = '3e8bb00a-753c-4e77-afc6-104537116ea7'; break }
                'Legacy' { $valueToSet = '52b8ae12-3d48-4c76-a094-86e3e9d57a2e'; break }
                default  { $valueToSet = '71d17779-001e-47e5-aeac-98b05f8d68bb'; break }
            }
        } else {
            $valueToSet = $Value
        }

        if ($valueToSet -is [bool]) { $valueToSet = ($valueToSet -eq $true) }

        Ninja-Property-Set $FieldName $valueToSet -ErrorAction Stop
        Write-Verbose-Log "✓ Set $FieldName = $valueToSet"
        return $true
    } catch {
        Write-Verbose-Log "✗ Failed to set $FieldName : $($_.Exception.Message)"
        return $false
    }
}

function Get-WinREStatus {
    $result = @{
        Timestamp = Get-Date -Format o
        ComputerName = $env:COMPUTERNAME
        WinREEnabled = $false
        BCDRecoveryGuid = "NOT_CONFIGURED"
        PartitionSizeMB = $null
        PartitionFreeMB = $null
        PartitionHealthStatus = "NotChecked"
        PartitionOperationalStatus = "NotChecked"
        BitLockerStatus = "Unknown"
        SecureBootEnabled = $false
        FirmwareType = "Unknown"
        Windows11Ready = $false
        TpmPresent = $false
        TpmReady = $false
        PendingReboot = $false
        IsRecoveryGptGuid = $false
        PartitionGptType = $null
        IsLastPartition = $false
        AdjacentToOSPartition = $false
        SupportedMaxSizeMB = $null
        CanGrowTo500MB = $false
        BcdId = $null
        DiskHealthStatus = "NotChecked"
        DiskOperationalStatus = "NotChecked"
        RemediationReady = $false
        KB5034441Vulnerable = $false
        ConfidenceScore = 0
        Severity = "Unknown"
        RecommendedAction = @()
    }
    
    try {
        # Check UEFI/BIOS and Secure Boot
        try {
            $null = Confirm-SecureBootUEFI -ErrorAction Stop
            $result.SecureBootEnabled = $true
            $result.FirmwareType = "UEFI"
        } catch {
            $result.SecureBootEnabled = $false
            $result.FirmwareType = "Legacy"
        }
        
        # TPM status
        try {
            $tpm = Get-Tpm -ErrorAction SilentlyContinue
            if ($tpm) {
                $result.TpmPresent = $tpm.TpmPresent
                $result.TpmReady = $tpm.TpmReady
            }
        } catch {}
        
        # Pending reboot
        $result.PendingReboot = Test-PendingReboot
        
        # WinRE status via reagentc
        $reagentc = reagentc /info 2>&1
        $statusLine = $reagentc | Select-String -Pattern "Windows RE status" -SimpleMatch | ForEach-Object { $_.Line }
        if ($statusLine) {
            $result.WinREEnabled = $statusLine -match "Enabled"
        }
        
        $locationLine = $reagentc | Select-String -Pattern "Windows RE location" -SimpleMatch | ForEach-Object { $_.Line }
        $location = $null
        if ($locationLine) { $location = ($locationLine -split ":",2)[1].Trim() }
        
        # BCD ID
        $bcdLine = $reagentc | Select-String -Pattern "Boot Configuration Data" -SimpleMatch | ForEach-Object { $_.Line }
        if ($bcdLine) { $result.BcdId = ($bcdLine -split ":",2)[1].Trim() }
        
        # Partition analysis
        if ($location -match "harddisk(\d+)\\partition(\d+)") {
            $diskNumber = [int]$matches[1]
            $partitionNumber = [int]$matches[2]
            
            try {
                $partition = Get-PartitionSafe -DiskNumber $diskNumber -PartitionNumber $partitionNumber -ErrorAction SilentlyContinue
                if ($partition) {
                    $result.PartitionSizeMB = [math]::Round($partition.Size / 1MB, 2)
                    $result.PartitionGptType = $partition.GptType
                    
                    # Recovery GUID check
                    $recoveryGuid = '{DE94BBA4-06D1-4D40-A16A-BFD50179D6AC}'
                    $result.IsRecoveryGptGuid = ($partition.GptType -eq $recoveryGuid)
                    
                    # Partition health status (v1.5.5)
                    try {
                        if ($partition.HealthStatus) {
                            $result.PartitionHealthStatus = $partition.HealthStatus.ToString()
                        } else {
                            $result.PartitionHealthStatus = "Unknown"
                        }
                        if ($partition.OperationalStatus) {
                            $result.PartitionOperationalStatus = $partition.OperationalStatus.ToString()
                        } else {
                            $result.PartitionOperationalStatus = "Unknown"
                        }
                    } catch {
                        Write-Verbose-Log "Could not retrieve partition health status: $($_.Exception.Message)"
                        $result.PartitionHealthStatus = "Error"
                        $result.PartitionOperationalStatus = "Unknown"
                    }
                    
                    # Disk health status (v1.5.5)
                    try {
                        $diskObj = Get-DiskSafe -Number $diskNumber -ErrorAction SilentlyContinue
                        if ($diskObj) {
                            if ($diskObj.HealthStatus) {
                                $result.DiskHealthStatus = $diskObj.HealthStatus.ToString()
                            } else {
                                $result.DiskHealthStatus = "Unknown"
                            }
                            if ($diskObj.OperationalStatus) {
                                $result.DiskOperationalStatus = $diskObj.OperationalStatus.ToString()
                            } else {
                                $result.DiskOperationalStatus = "Unknown"
                            }
                        }
                    } catch {
                        Write-Verbose-Log "Could not retrieve disk health status: $($_.Exception.Message)"
                        $result.DiskHealthStatus = "Error"
                        $result.DiskOperationalStatus = "Unknown"
                    }
                    
                    # Growability
                    try {
                        $supported = Get-PartitionSupportedSize -DiskNumber $diskNumber -PartitionNumber $partitionNumber -ErrorAction SilentlyContinue
                        if ($supported) {
                            $result.SupportedMaxSizeMB = [math]::Round($supported.SizeMax/1MB, 2)
                            $result.CanGrowTo500MB = ($supported.SizeMax -ge 500MB)
                        }
                    } catch {}
                    
                    # Last partition / adjacent checks
                    $allParts = Get-PartitionSafe -DiskNumber $diskNumber -ErrorAction SilentlyContinue | Sort-Object Offset
                    if ($allParts) {
                        $result.IsLastPartition = ($allParts[-1].PartitionNumber -eq $partitionNumber)
                        $osPart = $allParts | Where-Object { $_.Type -eq 'Basic' } | Sort-Object Offset | Select-Object -Last 1
                        if ($osPart) {
                            $result.AdjacentToOSPartition = (($osPart.Offset + $osPart.Size) -eq $partition.Offset) -or (($partition.Offset + $partition.Size) -eq $osPart.Offset)
                        }
                    }
                }
            } catch {
                Write-Verbose-Log "Partition analysis failed: $($_.Exception.Message)"
            }
        }
        
        # WinRE image size and free space
        if ($location -and (Test-Path $location)) {
            $wimPath = Join-Path $location "winre.wim"
            if (Test-Path $wimPath) {
                $wimFile = Get-Item $wimPath -ErrorAction SilentlyContinue
                if ($wimFile) {
                    $wimSizeMB = [math]::Round($wimFile.Length / 1MB, 2)
                    if ($result.PartitionSizeMB) {
                        $result.PartitionFreeMB = [math]::Round($result.PartitionSizeMB - $wimSizeMB, 2)
                    }
                }
            }
        }
        
        # BitLocker status
        try {
            $blvs = Get-BitLockerVolume -ErrorAction SilentlyContinue
            $osVolume = $blvs | Where-Object { $_.VolumeType -eq "OperatingSystem" } | Select-Object -First 1
            if ($osVolume) {
                $result.BitLockerStatus = $osVolume.ProtectionStatus.ToString()
            }
        } catch {}
        
        # Windows 11 readiness
        $result.Windows11Ready = ($result.FirmwareType -eq "UEFI" -and $result.SecureBootEnabled -and $result.TpmReady)
        
        # KB5034441 vulnerability
        if ($null -ne $result.PartitionFreeMB) {
            $result.KB5034441Vulnerable = ($result.PartitionFreeMB -lt 250)
        } elseif ($null -ne $result.PartitionSizeMB) {
            $result.KB5034441Vulnerable = ($result.PartitionSizeMB -lt 500)
        }
        
        # Confidence score (0-100)
        $score = 0
        if ($result.WinREEnabled) { $score += 30 }
        if ($null -ne $result.PartitionFreeMB) { $score += 20 }
        if ($result.BitLockerStatus -eq "On") { $score += 15 }
        if ($result.Windows11Ready) { $score += 15 }
        if ($result.TpmPresent -and $result.TpmReady) { $score += 10 }
        if ($result.IsRecoveryGptGuid) { $score += 10 }
        $result.ConfidenceScore = [math]::Min($score, 100)
        
        # Severity
        if ($result.ConfidenceScore -ge 85) { 
            $result.Severity = "Healthy" 
        } elseif ($result.ConfidenceScore -ge 60) { 
            $result.Severity = "Warning" 
        } else { 
            $result.Severity = "Critical" 
        }
        
        if ($result.KB5034441Vulnerable) {
            $result.Severity = "Critical"
            $result.RecommendedAction += "URGENT: Recovery partition <250MB free or <500MB total. Resize to 500MB+"
        }
        
        if (-not $result.WinREEnabled) {
            $result.RecommendedAction += "WinRE disabled — run 'reagentc /enable'"
        }
        
        if ($result.Severity -eq "Healthy" -and $result.RecommendedAction.Count -eq 0) {
            $result.RecommendedAction += "No action required"
        }
        
        # Remediation readiness
        $result.RemediationReady = ($result.KB5034441Vulnerable -eq $false -and
                                   $result.CanGrowTo500MB -eq $true -and
                                   $result.IsLastPartition -eq $true -and
                                   $result.PendingReboot -eq $false)
        
    } catch {
        $result.Severity = "Error"
        $result.RecommendedAction = @("Detection failed: $($_.Exception.Message)")
    }
    
    return $result
}

function Test-PendingReboot {
    try {
        $paths = @(
            'HKLM:SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
            'HKLM:SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
            'HKLM:SYSTEM\CurrentControlSet\Control\Session Manager'
        )
        foreach ($p in $paths) {
            if (Test-Path $p) {
                if ($p -like '*Session Manager') {
                    if ($null -ne (Get-ItemProperty -Path $p -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue)) {
                        return $true
                    }
                } else {
                    return $true
                }
            }
        }
        return $false
    } catch {
        return $false
    }
}
#endregion

#region Main
try {
    Write-Verbose-Log "=== WinRE Health Detection (NinjaOne Simple) v$ScriptVersion Started ==="
    
    # Get health status
    $status = Get-WinREStatus
    
    # Output JSON if requested
    if ($OutputJson) {
        $status | ConvertTo-Json -Depth 3 | Write-Output
    }
    
    # Return object for testing (instead of setting Ninja fields and exiting)
    if ($TestMode) { return $status }
    
    # Attempt to set Ninja fields
    Write-Verbose-Log "Attempting to populate NinjaOne Device Custom Fields..."
    
    $fieldCount = 0
    $successCount = 0
    
    # Core fields
    if (Set-NinjaField "winreEnabled" $status.WinREEnabled) { $successCount++ }; $fieldCount++
    if (Set-NinjaField "winreSeverity" $status.Severity) { $successCount++ }; $fieldCount++
    if (Set-NinjaField "winreKB5034441Vulnerable" $status.KB5034441Vulnerable) { $successCount++ }; $fieldCount++
    if (Set-NinjaField "winreConfidenceScore" $status.ConfidenceScore) { $successCount++ }; $fieldCount++
    if (Set-NinjaField "winreRecommendation" ($status.RecommendedAction -join "; ")) { $successCount++ }; $fieldCount++
    if (Set-NinjaField "winrePartitionSizeMB" $status.PartitionSizeMB) { $successCount++ }; $fieldCount++
    if (Set-NinjaField "winrePartitionFreeMB" $status.PartitionFreeMB) { $successCount++ }; $fieldCount++
    if (Set-NinjaField "winreLastCheck" ((Get-Date).ToString('s'))) { $successCount++ }; $fieldCount++
    if (Set-NinjaField "winreBitLockerStatus" $status.BitLockerStatus) { $successCount++ }; $fieldCount++
    if (Set-NinjaField "winreWindows11Ready" $status.Windows11Ready) { $successCount++ }; $fieldCount++
    if (Set-NinjaField "winreSecureBoot" $status.SecureBootEnabled) { $successCount++ }; $fieldCount++
    if (Set-NinjaField "winreFirmwareType" $status.FirmwareType) { $successCount++ }; $fieldCount++
    
    # Summary
    $elapsed = [math]::Round(((Get-Date) - $ScriptStartTime).TotalMilliseconds, 0)
    Write-Verbose-Log "=== Complete ==="
    Write-Verbose-Log "Fields: $successCount/$fieldCount populated"
    Write-Verbose-Log "Severity: $($status.Severity)"
    Write-Verbose-Log "Confidence: $($status.ConfidenceScore)"
    Write-Verbose-Log "Elapsed: ${elapsed}ms"
    
    # Exit code
    if ($status.Severity -eq "Critical") {
        Write-Output "CRITICAL: $($status.RecommendedAction -join '; ')"
        exit 1
    } elseif ($status.Severity -eq "Warning") {
        Write-Output "WARNING: $($status.RecommendedAction -join '; ')"
        exit 0
    } else {
        Write-Output "HEALTHY: WinRE is functioning correctly"
        exit 0
    }
    
} catch {
    Write-Output "FATAL ERROR: $($_.Exception.Message)"
    exit 1
}
#endregion
