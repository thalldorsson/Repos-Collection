# WinRE Health Detection Script (Enhanced, Cross-Vendor, Intune/Log Analytics Ready)
# Author: GitHub Copilot (GPT-5)
# Date: 2025-11-17

# Output file path (for Log Analytics ingestion)
$OutputDir = "C:\ProgramData\WinREHealth"
$OutputFile = Join-Path $OutputDir "WinREHealthStatus.json"
$LogFile = Join-Path $OutputDir "WinREHealthDetection.log"
$HistoryFile = Join-Path $OutputDir "WinREHealthHistory.json"
${WorkspaceIdFile} = Join-Path $OutputDir "la.id"
${WorkspaceKeyFile} = Join-Path $OutputDir "la.key"
$LogType = "WinREHealth"
${ScriptVersion} = "1.2.0-intune"
${SchemaVersion} = "2025-11-17"

# Ensure output directory exists
if (!(Test-Path $OutputDir)) { New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null }

# Performance tracking
$scriptStartTime = Get-Date

function Write-Log {
    param([string]$Message)
    Add-Content -Path $LogFile -Value "$(Get-Date -Format o): $Message"
}

function Test-PendingReboot {
    try {
        $paths = @(
            'HKLM:SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
            'HKLM:SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
            'HKLM:SYSTEM\CurrentControlSet\Control\Session Manager' # PendingFileRenameOperations
        )
        foreach ($p in $paths) {
            if (Test-Path $p) {
                if ($p -like '*Session Manager') {
                    $val = (Get-ItemProperty -Path $p -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue)
                    if ($null -ne $val) { return $true }
                } else {
                    return $true
                }
            }
        }
        return $false
    } catch { return $false }
}

function Get-WinREStatus {
    $functionStartTime = Get-Date
    
    $result = @{
        Timestamp = (Get-Date -Format o)
        ComputerName = $env:COMPUTERNAME
        Manufacturer = $null
        Model = $null
        SerialNumber = $null
        OSVersion = $null
        OSBuild = $null
        OSCaption = $null
        OSEdition = $null
        ReleaseId = $null
        Domain = $null
        LastLoggedOnUser = $null
        
        # Boot & Security Configuration
        SecureBootEnabled = $null
        UEFIMode = $null
        BIOSMode = $null
        
        # WinRE Core Fields
        WinREEnabled = $null
        WinRELocation = $null
        WinREBCDId = $null
        PartitionGUID = $null
        PartitionSizeMB = $null
        PartitionFreeMB = $null
        PartitionType = $null
        PartitionGptType = $null
        IsRecoveryGptGuid = $null
        IsLastPartition = $null
        AdjacentToOSPartition = $null
        SupportedMaxSizeMB = $null
        CanGrowTo500MB = $null
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
        
        # Security / Platform
        TpmPresent = $null
        TpmReady = $null
        IsVirtualMachine = $null
        PendingReboot = $null

        # Meta
        ScriptVersion = ${ScriptVersion}
        SchemaVersion = ${SchemaVersion}
        RemediationReady = $false
        RecommendedActionCode = @()
        Diagnostics = @()

        RecommendedAction = @()
        ConfidenceScore = 0
        Severity = "Unknown"
        Error = $null
    }
    try {
        # Fast system inventory via CIM (replaces deprecated Get-WmiObject)
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
        $product = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction SilentlyContinue

        if ($cs) {
            $result.Manufacturer = $cs.Manufacturer
            $result.Model = $cs.Model
            $result.Domain = $cs.Domain
            $result.LastLoggedOnUser = $cs.UserName
            # VM hint: Hyper-V or common virtualization manufacturers/models
            $vmHints = @('Microsoft Corporation','VMware, Inc.','innotek GmbH','VirtualBox','QEMU','Xen','KVM')
            $result.IsVirtualMachine = ($vmHints | ForEach-Object { ($cs.Manufacturer -like "*$_*") -or ($cs.Model -like "*$_*") }) -contains $true
        }
        if ($bios) { $result.SerialNumber = $bios.SerialNumber }
        if ($os) {
            $result.OSVersion = $os.Version
            $result.OSBuild = $os.BuildNumber
            $result.OSCaption = $os.Caption
            try { $result.OSEdition = (Get-ItemProperty 'HKLM:SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID } catch {}
            try { $result.ReleaseId = (Get-ItemProperty 'HKLM:SOFTWARE\Microsoft\Windows NT\CurrentVersion').ReleaseId } catch {}
        }

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
            $result.RecommendedActionCode += 'LEGACY_BIOS'
        }
        
        # Add recommendations based on boot mode
        if ($result.BIOSMode -eq "Legacy") {
            $result.RecommendedAction += "Legacy BIOS detected - consider upgrading to UEFI for Windows 11 compatibility"
            $result.RecommendedActionCode += 'LEGACY_BIOS'
        }
        if ($result.UEFIMode -eq $true -and $result.SecureBootEnabled -eq $false) {
            $result.RecommendedAction += "UEFI mode active but Secure Boot is disabled - enable for enhanced security"
            $result.RecommendedActionCode += 'SECURE_BOOT_DISABLED'
        }
        
        # Basic WinRE status from reagentc (with performance tracking)
        $reagentcStart = Get-Date
        $reagentc = reagentc /info 2>&1
        $reagentcEnd = Get-Date
        $result.ReagentcResponseTimeMS = [math]::Round(($reagentcEnd - $reagentcStart).TotalMilliseconds, 2)
        
        $statusLine = ($reagentc | Select-String -Pattern "Windows RE status" -SimpleMatch | ForEach-Object { $_.Line })
        $enabled = $false
        if ($statusLine) { $enabled = ($statusLine -split ":")[1].Trim() -match "Enabled" }
        if (-not $statusLine) {
            # Fallback to registry if localized output breaks parsing
            try {
                $winreReg = Get-ItemProperty -Path 'HKLM:SYSTEM\CurrentControlSet\Control\WinRE' -ErrorAction Stop
                if ($null -ne $winreReg.Enabled) { $enabled = [bool]$winreReg.Enabled }
            } catch {}
            $result.Diagnostics += 'ReagentcStatusRegFallback'
        }
        $result.WinREEnabled = $enabled
        $locationLine = ($reagentc | Select-String -Pattern "Windows RE location" -SimpleMatch | ForEach-Object { $_.Line })
        $location = $null
        if ($locationLine) { $location = ($locationLine -split ":",2)[1].Trim() }
        $bcdLine = ($reagentc | Select-String -Pattern "Boot Configuration Data (BCD) identifier" -SimpleMatch | ForEach-Object { $_.Line })
        if ($bcdLine) { $result.WinREBCDId = ($bcdLine -split ":",2)[1].Trim() }
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
                    if ($partition.GptType) { $result.PartitionGptType = $partition.GptType }

                    # Check if partition has the well-known Windows Recovery GPT type
                    $recoveryGuid = '{DE94BBA4-06D1-4D40-A16A-BFD50179D6AC}'
                    $result.IsRecoveryGptGuid = ($partition.GptType -eq $recoveryGuid)

                    # Is recovery the last partition on disk? (preferred layout)
                    $allParts = Get-Partition -DiskNumber $diskNumber -ErrorAction SilentlyContinue | Sort-Object -Property Offset
                    if ($allParts) {
                        $lastPart = $allParts[-1]
                        $result.IsLastPartition = ($lastPart.PartitionNumber -eq $partitionNumber)
                        # Adjacent to OS partition?
                        $osPart = ($allParts | Where-Object { $_.Type -eq 'Basic' -and $_.AccessPaths -like '*\\' } | Select-Object -First 1)
                        if (-not $osPart) { $osPart = ($allParts | Where-Object { $_.Type -eq 'Basic' } | Sort-Object Offset | Select-Object -Last 1) }
                        if ($osPart) { $result.AdjacentToOSPartition = (($osPart.Offset + $osPart.Size) -eq $partition.Offset) -or (($partition.Offset + $partition.Size) -eq $osPart.Offset) }
                    }
                    
                    # Compute supported max size (can we grow to >= 500MB?)
                    try {
                        $supported = Get-PartitionSupportedSize -DiskNumber $diskNumber -PartitionNumber $partitionNumber -ErrorAction SilentlyContinue
                        if ($supported) {
                            $result.SupportedMaxSizeMB = [math]::Round($supported.SizeMax/1MB,2)
                            $result.CanGrowTo500MB = ($supported.SizeMax -ge (500MB))
                        }
                    } catch {}
                    
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
                        $result.Diagnostics += 'WimInfoFailed'
                    }
                } else {
                    $result.PartitionAccessible = $false
                    $result.RecommendedAction += "WinRE.wim file not found or not accessible"
                    $result.RecommendedActionCode += 'WINRE_WIM_MISSING'
                }
            } else {
                $result.PartitionAccessible = $false
                $result.RecommendedAction += "WinRE.wim missing from recovery partition"
                $result.RecommendedActionCode += 'WINRE_WIM_MISSING'
            }
        } else {
            $result.PartitionAccessible = $false
            if ($location) {
                $result.RecommendedAction += "Recovery location not accessible: $location"
            } else {
                $result.RecommendedAction += "WinRE location not configured"
            }
        }

        # Evaluate KB5034441 vulnerability based on free space when available, else size heuristic
        if ($null -ne $result.PartitionFreeMB) {
            if ($result.PartitionFreeMB -lt 250) {
                $result.KB5034441Vulnerable = $true
                $result.RecommendedAction += "URGENT: Recovery partition has <250MB free (current: $($result.PartitionFreeMB)MB). Resize to 500MB+)"
                $result.RecommendedActionCode += 'KB5034441_RESIZE'
            } else { $result.KB5034441Vulnerable = $false }
        } elseif ($null -ne $result.PartitionSizeMB) {
            if ($result.PartitionSizeMB -lt 500) {
                $result.KB5034441Vulnerable = $true
                $result.RecommendedAction += "Recovery partition small (size: $($result.PartitionSizeMB)MB). Target 500MB+)"
                $result.RecommendedActionCode += 'KB5034441_RESIZE'
            } else { $result.KB5034441Vulnerable = $false }
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
                    $result.RecommendedActionCode += 'BITLOCKER_OFF'
                }
            } else {
                $result.BitLockerStatus = "Unknown"
            }
        } catch {
            $result.BitLockerStatus = "Unknown"
            Write-Log "BitLocker check failed: $($_.Exception.Message)"
            $result.Diagnostics += 'BitLockerCmdFailed'
        }
        $bitlockerEnd = Get-Date
        $result.BitLockerCheckTimeMS = [math]::Round(($bitlockerEnd - $bitlockerStart).TotalMilliseconds, 2)

        # TPM information (Windows 11 readiness)
        try { 
            $tpm = Get-Tpm -ErrorAction SilentlyContinue
            if ($tpm) { $result.TpmPresent = $tpm.TpmPresent; $result.TpmReady = $tpm.TpmReady }
        } catch {}

        # Pending reboot (can block partition changes)
        $result.PendingReboot = Test-PendingReboot

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
        if ($result.TpmPresent -and $result.TpmReady) { $score += 5 }
        if ($result.IsRecoveryGptGuid) { $score += 5 }
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
        # If pending reboot, flag warning (can block servicing)
        if ($result.PendingReboot -eq $true -and $result.Severity -eq 'Healthy') {
            $result.Severity = 'Warning'
            $result.RecommendedAction += 'Pending reboot detected - complete reboot before servicing WinRE.'
            $result.RecommendedActionCode += 'PENDING_REBOOT'
        }

        # Compute remediation readiness (for safe automation)
        $result.RemediationReady = ($result.KB5034441Vulnerable -eq $true -and
                                    $result.CanGrowTo500MB -eq $true -and
                                    $result.IsLastPartition -eq $true -and
                                    $result.AdjacentToOSPartition -eq $true -and
                                    $result.PendingReboot -eq $false)
        
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

    # Append to history (keep last 30 entries)
    try {
        $history = @()
        if (Test-Path $HistoryFile) {
            $history = Get-Content -Path $HistoryFile -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        }
        if ($null -eq $history) { $history = @() }
        $history = @($history) + @($status)
        if ($history.Count -gt 30) { $history = $history[($history.Count-30)..($history.Count-1)] }
        $history | ConvertTo-Json -Depth 5 | Set-Content -Path $HistoryFile -Encoding UTF8
        Write-Log "History updated at $HistoryFile"
    } catch { Write-Log "Failed to persist history: $($_.Exception.Message)" }

    # Optional: Send to Log Analytics via HTTP Data Collector if credentials present
    try {
        if ((Test-Path ${WorkspaceIdFile}) -and (Test-Path ${WorkspaceKeyFile})) {
            $workspaceId = (Get-Content ${WorkspaceIdFile} -Raw).Trim()
            $workspaceKey = (Get-Content ${WorkspaceKeyFile} -Raw).Trim()
            $sender = Join-Path $PSScriptRoot 'Send-ToLogAnalytics.ps1'
            if (Test-Path $sender) { . $sender }
            if (Get-Command -Name Send-ToLogAnalytics -ErrorAction SilentlyContinue) {
                $ok = Send-ToLogAnalytics -Data $status -WorkspaceId $workspaceId -WorkspaceKey $workspaceKey -LogType $LogType
                if ($ok) { Write-Log "Sent data to Log Analytics via HTTP" } else { Write-Log "HTTP send to Log Analytics returned failure" }
            } else {
                Write-Log "Send-ToLogAnalytics.ps1 not found or function unavailable; skipping HTTP upload"
            }
        }
    } catch { Write-Log "Log Analytics HTTP upload failed: $($_.Exception.Message)" }
    # Log total script time
    $totalElapsed = [math]::Round(((Get-Date) - $scriptStartTime).TotalMilliseconds, 2)
    Write-Log "Total Script Time: $totalElapsed ms"
} catch {
    Write-Log "Fatal error: $($_.Exception.Message)"
}