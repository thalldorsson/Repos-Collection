# WinRE Health Detection Script (Enhanced, Cross-Vendor, Intune/Log Analytics Ready)
# Author: GitHub Copilot (GPT-4.1)
# Date: 2025-11-11

# Output file path (for Log Analytics ingestion)
$OutputDir = "C:\ProgramData\WinREHealth"
$OutputFile = Join-Path $OutputDir "WinREHealthStatus.json"
$LogFile = Join-Path $OutputDir "WinREHealthDetection.log"
$HistoryFile = Join-Path $OutputDir "WinREHealthHistory.json"

# Ensure output directory exists
if (!(Test-Path $OutputDir)) { New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null }

# Performance tracking
$scriptStartTime = Get-Date

function Write-Log {
    param([string]$Message)
    Add-Content -Path $LogFile -Value "$(Get-Date -Format o): $Message"
}

function Get-WinREStatus {
    $functionStartTime = Get-Date
    
    $result = @{
        Timestamp = (Get-Date -Format o)
        ComputerName = $env:COMPUTERNAME
        Manufacturer = (Get-WmiObject -Class Win32_ComputerSystem).Manufacturer
        Model = (Get-WmiObject -Class Win32_ComputerSystem).Model
        SerialNumber = (Get-WmiObject -Class Win32_BIOS).SerialNumber
        OSVersion = (Get-WmiObject -Class Win32_OperatingSystem).Version
        OSBuild = (Get-WmiObject -Class Win32_OperatingSystem).BuildNumber
        OSCaption = (Get-WmiObject -Class Win32_OperatingSystem).Caption
        Domain = (Get-WmiObject -Class Win32_ComputerSystem).Domain
        LastLoggedOnUser = (Get-WmiObject -Class Win32_ComputerSystem).UserName
        
        # Boot & Security Configuration
        SecureBootEnabled = $null
        UEFIMode = $null
        BIOSMode = $null
        
        # WinRE Core Fields
        WinREEnabled = $null
        WinRELocation = $null
        PartitionGUID = $null
        PartitionSizeMB = $null
        PartitionFreeMB = $null
        PartitionType = $null
        DiskType = $null
        RecoveryPartitionCount = 0
        WinREImageSizeMB = $null
        WinREImageVersion = $null
        BitLockerStatus = $null
        PartitionAccessible = $null
        KB5034441Vulnerable = $null
        
        # Performance Metrics
        ScriptExecutionTimeMS = $null
        ReagentcResponseTimeMS = $null
        PartitionAnalysisTimeMS = $null
        BitLockerCheckTimeMS = $null
        
        RecommendedAction = @()
        ConfidenceScore = 0
        Severity = "Unknown"
        Error = $null
    }
    try {
        # Check UEFI/BIOS Mode and Secure Boot
        try {
            $secureBoot = Confirm-SecureBootUEFI -ErrorAction Stop
            $result.SecureBootEnabled = $secureBoot
            $result.UEFIMode = $true
            $result.BIOSMode = "UEFI"
        } catch {
            # If Confirm-SecureBootUEFI fails, system is in Legacy BIOS mode
            $result.SecureBootEnabled = $false
            $result.UEFIMode = $false
            $result.BIOSMode = "Legacy"
            Write-Log "System is in Legacy BIOS mode (not UEFI)"
        }
        
        # Add recommendations based on boot mode
        if ($result.BIOSMode -eq "Legacy") {
            $result.RecommendedAction += "Legacy BIOS detected - consider upgrading to UEFI for Windows 11 compatibility"
        }
        if ($result.UEFIMode -eq $true -and $result.SecureBootEnabled -eq $false) {
            $result.RecommendedAction += "UEFI mode active but Secure Boot is disabled - enable for enhanced security"
        }
        
        # Basic WinRE status from reagentc (with performance tracking)
        $reagentcStart = Get-Date
        $reagentc = reagentc /info 2>&1
        $reagentcEnd = Get-Date
        $result.ReagentcResponseTimeMS = [math]::Round(($reagentcEnd - $reagentcStart).TotalMilliseconds, 2)
        
        $enabled = ($reagentc | Select-String "Windows RE status" | ForEach-Object { $_.Line }) -match "Enabled"
        $result.WinREEnabled = $enabled
        $location = ($reagentc | Select-String "Windows RE location" | ForEach-Object { $_.Line }) -replace ".*: ", ""
        $result.WinRELocation = $location

        # Extract drive letter from location (with performance tracking)
        $partitionAnalysisStart = Get-Date
        if ($location -match "harddisk(\d+)\\partition(\d+)") {
            $diskNumber = [int]$matches[1]
            $partitionNumber = [int]$matches[2]
            
            # Get partition details
            try {
                $partition = Get-Partition -DiskNumber $diskNumber -PartitionNumber $partitionNumber -ErrorAction SilentlyContinue
                if ($partition) {
                    $result.PartitionSizeMB = [math]::Round($partition.Size / 1MB, 2)
                    $result.PartitionType = $partition.Type
                    $result.PartitionGUID = $partition.Guid
                    
                    # Check if partition is too small (KB5034441 issue - needs ~250MB free)
                    if ($result.PartitionSizeMB -lt 250) {
                        $result.KB5034441Vulnerable = $true
                        $result.RecommendedAction += "Resize recovery partition (current: $($result.PartitionSizeMB)MB, recommended: 500MB+)"
                    } else {
                        $result.KB5034441Vulnerable = $false
                    }
                    
                    # Get disk type (SSD/HDD)
                    $disk = Get-Disk -Number $diskNumber -ErrorAction SilentlyContinue
                    if ($disk) {
                        $result.DiskType = $disk.PartitionStyle + " / " + $disk.BusType
                    }
                }
            } catch {
                Write-Log "Partition analysis failed: $($_.Exception.Message)"
            }
        }
        $partitionAnalysisEnd = Get-Date
        $result.PartitionAnalysisTimeMS = [math]::Round(($partitionAnalysisEnd - $partitionAnalysisStart).TotalMilliseconds, 2)

        # Count all recovery partitions (some devices have multiple)
        $allRecoveryPartitions = Get-Partition | Where-Object { $_.Type -eq "Recovery" }
        $result.RecoveryPartitionCount = ($allRecoveryPartitions | Measure-Object).Count
        if ($result.RecoveryPartitionCount -gt 1) {
            $result.RecommendedAction += "Multiple recovery partitions detected ($($result.RecoveryPartitionCount)) - review configuration"
        }

        # Check WinRE.wim file details
        if ($location -and (Test-Path $location)) {
            $wimPath = Join-Path $location "winre.wim"
            if (Test-Path $wimPath) {
                $wimFile = Get-Item $wimPath -ErrorAction SilentlyContinue
                if ($wimFile) {
                    $result.WinREImageSizeMB = [math]::Round($wimFile.Length / 1MB, 2)
                    $result.PartitionAccessible = $true
                    
                    # Calculate free space (partition size - wim size)
                    if ($result.PartitionSizeMB) {
                        $result.PartitionFreeMB = [math]::Round($result.PartitionSizeMB - $result.WinREImageSizeMB, 2)
                        if ($result.PartitionFreeMB -lt 100) {
                            $result.RecommendedAction += "Low free space on recovery partition ($($result.PartitionFreeMB)MB free)"
                        }
                    }
                    
                    # Try to get WIM version (requires admin/system)
                    try {
                        $wimInfo = & dism.exe /Get-WimInfo /WimFile:$wimPath /index:1 2>&1 | Out-String
                        if ($wimInfo -match "Version : ([\d\.]+)") {
                            $result.WinREImageVersion = $matches[1]
                        }
                    } catch {
                        Write-Log "Could not read WIM version: $($_.Exception.Message)"
                    }
                } else {
                    $result.PartitionAccessible = $false
                    $result.RecommendedAction += "WinRE.wim file not found or not accessible"
                }
            } else {
                $result.PartitionAccessible = $false
                $result.RecommendedAction += "WinRE.wim missing from recovery partition"
            }
        } else {
            $result.PartitionAccessible = $false
            if ($location) {
                $result.RecommendedAction += "Recovery location not accessible: $location"
            } else {
                $result.RecommendedAction += "WinRE location not configured"
            }
        }

        # BitLocker status (enhanced check with performance tracking)
        $bitlockerStart = Get-Date
        try {
            $blvs = Get-BitLockerVolume -ErrorAction SilentlyContinue
            $osVolume = $blvs | Where-Object { $_.VolumeType -eq "OperatingSystem" } | Select-Object -First 1
            if ($osVolume) {
                $result.BitLockerStatus = $osVolume.ProtectionStatus
                if ($osVolume.ProtectionStatus -eq "Off") {
                    $result.RecommendedAction += "BitLocker not enabled on OS volume"
                }
            } else {
                $result.BitLockerStatus = "Unknown"
            }
        } catch {
            $result.BitLockerStatus = "Unknown"
            Write-Log "BitLocker check failed: $($_.Exception.Message)"
        }
        $bitlockerEnd = Get-Date
        $result.BitLockerCheckTimeMS = [math]::Round(($bitlockerEnd - $bitlockerStart).TotalMilliseconds, 2)

        # Vendor-specific checks
        $manufacturer = $result.Manufacturer.ToLower()
        if ($manufacturer -match "lenovo") {
            # Lenovo-specific: Check for Lenovo Recovery partition quirks
            if ($result.RecoveryPartitionCount -eq 0) {
                $result.RecommendedAction += "Lenovo device with no recovery partition - may need factory reset option disabled"
            }
        } elseif ($manufacturer -match "dell") {
            # Dell-specific: Check for Dell Recovery partition
            if ($result.RecoveryPartitionCount -gt 2) {
                $result.RecommendedAction += "Dell device with multiple recovery partitions - verify Dell SupportAssist configuration"
            }
        } elseif ($manufacturer -match "hp|hewlett") {
            # HP-specific: Check for HP Recovery Manager
            if ($result.RecoveryPartitionCount -gt 2) {
                $result.RecommendedAction += "HP device with multiple recovery partitions - verify HP Recovery Manager configuration"
            }
        } elseif ($manufacturer -match "microsoft") {
            # Surface-specific: Surfaces often have unique partition layouts
            if ($result.PartitionSizeMB -and $result.PartitionSizeMB -lt 500) {
                $result.RecommendedAction += "Surface device with small recovery partition - consider resizing for updates"
            }
        }

        # Check if WinRE is disabled but should be enabled
        if (!$result.WinREEnabled) {
            $result.RecommendedAction += "WinRE is disabled - run 'reagentc /enable' to enable"
        }

        # Enhanced confidence scoring
        $score = 0
        if ($result.WinREEnabled) { $score += 30 }
        if ($result.PartitionAccessible) { $score += 25 }
        if ($result.BitLockerStatus -eq "On") { $score += 15 }
        if ($result.PartitionGUID) { $score += 10 }
        if ($result.WinREImageSizeMB -and $result.WinREImageSizeMB -gt 100) { $score += 10 }
        if ($result.PartitionSizeMB -and $result.PartitionSizeMB -ge 250) { $score += 5 }
        if ($result.PartitionFreeMB -and $result.PartitionFreeMB -ge 100) { $score += 5 }
        $result.ConfidenceScore = $score

        # Enhanced severity calculation
        if ($score -ge 85) { 
            $result.Severity = "Healthy" 
        } elseif ($score -ge 60) { 
            $result.Severity = "Warning" 
        } else { 
            $result.Severity = "Critical" 
        }
        
        # Override severity if KB5034441 vulnerable
        if ($result.KB5034441Vulnerable -eq $true) {
            $result.Severity = "Critical"
            $result.RecommendedAction = @("URGENT: KB5034441 vulnerable - recovery partition too small") + $result.RecommendedAction
        }
        
        # Add no action needed if healthy
        if ($result.Severity -eq "Healthy" -and $result.RecommendedAction.Count -eq 0) {
            $result.RecommendedAction += "No action required - WinRE is healthy"
        }
        
        # Calculate total script execution time
        $functionEndTime = Get-Date
        $result.ScriptExecutionTimeMS = [math]::Round(($functionEndTime - $functionStartTime).TotalMilliseconds, 2)
        
        # Performance warnings
        if ($result.ScriptExecutionTimeMS -gt 30000) {
            Write-Log "WARNING: Script execution took longer than expected: $($result.ScriptExecutionTimeMS)ms"
        }
        if ($result.ReagentcResponseTimeMS -gt 5000) {
            Write-Log "WARNING: reagentc command slow to respond: $($result.ReagentcResponseTimeMS)ms"
        }
    } catch {
        $result.Error = $_.Exception.Message
        Write-Log "Error: $($_.Exception.Message)"
    }
    return $result
}

try {
    $status = Get-WinREStatus
    $json = $status | ConvertTo-Json -Depth 4
    Set-Content -Path $OutputFile -Value $json -Encoding UTF8
    Write-Log "WinRE health status written to $OutputFile"
} catch {
    Write-Log "Fatal error: $($_.Exception.Message)"
}