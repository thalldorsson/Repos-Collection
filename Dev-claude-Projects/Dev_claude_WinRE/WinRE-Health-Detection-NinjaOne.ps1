# WinRE Health Detection Script for NinjaOne RMM
# Author: GitHub Copilot (GPT-5)
# Date: 2025-11-17
# Version: 1.2 NinjaOne Edition (enhanced analysis + remediation flags)

#region Configuration
$OutputDir = "C:\ProgramData\WinREHealth"
$LogFile = Join-Path $OutputDir "WinREHealthDetection.log"
$scriptStartTime = Get-Date
${ScriptVersion} = "1.2.0-ninja"
${SchemaVersion} = "2025-11-17"

# Ensure output directory exists
if (!(Test-Path $OutputDir)) { New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null }
#endregion

#region Functions
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogFile -Value "${timestamp}: $Message"
}

function Send-ToLogAnalytics {
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Data,
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceId,
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceKey,
        [Parameter(Mandatory=$true)]
        [string]$LogType
    )
    
    try {
        # Build the JSON body
        $json = $Data | ConvertTo-Json -Depth 10 -Compress
        $body = [System.Text.Encoding]::UTF8.GetBytes($json)
        
        # Create authorization signature
        $method = "POST"
        $contentType = "application/json"
        $resource = "/api/logs"
        $rfc1123date = [DateTime]::UtcNow.ToString("r")
        $contentLength = $body.Length
        
        $xHeaders = "x-ms-date:" + $rfc1123date
        $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource
        
        $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
        $keyBytes = [Convert]::FromBase64String($WorkspaceKey)
        
        $sha256 = New-Object System.Security.Cryptography.HMACSHA256
        $sha256.Key = $keyBytes
        $calculatedHash = $sha256.ComputeHash($bytesToHash)
        $encodedHash = [Convert]::ToBase64String($calculatedHash)
        $signature = "SharedKey ${WorkspaceId}:$encodedHash"
        
        # Build URI
        $uri = "https://$WorkspaceId.ods.opinsights.azure.com$resource" + "?api-version=2016-04-01"
        
        # Create headers
        $headers = @{
            "Authorization" = $signature
            "Log-Type" = $LogType
            "x-ms-date" = $rfc1123date
            "time-generated-field" = "Timestamp"
        }
        
        # Send data
        $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $body -UseBasicParsing
        
        if ($response.StatusCode -eq 200) {
            Write-Log "Successfully sent data to Log Analytics"
            return $true
        } else {
            Write-Log "Log Analytics returned status code: $($response.StatusCode)"
            return $false
        }
    } catch {
        Write-Log "Failed to send data to Log Analytics: $($_.Exception.Message)"
        return $false
    }
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
                } else { return $true }
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
        
        # Boot & Security Configuration
        SecureBootEnabled = $null
        UEFIMode = $null
        BIOSMode = $null
        
        # WinRE Core Fields
        WinREEnabled = $null
        WinRELocation = $null
        WinREBCDId = $null
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
        BitLockerStatus = $null
        PartitionAccessible = $null
        KB5034441Vulnerable = $null
        
        # Windows 11 Readiness
        Windows11Ready = $null
        TpmPresent = $null
        TpmReady = $null
        PendingReboot = $null
        IsVirtualMachine = $null
        
        # Performance Metrics
        ScriptExecutionTimeMS = $null
        
        RecommendedAction = @()
        ConfidenceScore = 0
        Severity = "Unknown"
        Error = $null
        ScriptVersion = ${ScriptVersion}
        SchemaVersion = ${SchemaVersion}
        RemediationReady = $false
        RecommendedActionCode = @()
        Diagnostics = @()
        
        # NinjaOne specific fields
        NinjaDeviceId = $null
        NinjaOrgId = $null
    }
    
    try {
        # CIM-based inventory (faster, non-deprecated)
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($cs) {
            $result.Manufacturer = $cs.Manufacturer
            $result.Model = $cs.Model
            # VM hints
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
        
        # Get NinjaOne device and org IDs if available
        try {
            $result.NinjaDeviceId = $env:NINJA_DEVICE_ID
            $result.NinjaOrgId = $env:NINJA_ORGANIZATION_ID
        } catch {
            Write-Log "Could not retrieve NinjaOne IDs (expected if running manually)"
        }
        
        # Check UEFI/BIOS Mode and Secure Boot
        try {
            $secureBoot = Confirm-SecureBootUEFI -ErrorAction Stop
            $result.SecureBootEnabled = $secureBoot
            $result.UEFIMode = $true
            $result.BIOSMode = "UEFI"
        } catch {
            $result.SecureBootEnabled = $false
            $result.UEFIMode = $false
            $result.BIOSMode = "Legacy"
            Write-Log "System is in Legacy BIOS mode (not UEFI)"
        }
        
        # Windows 11 Readiness Check
        $win11Ready = $true
        if ($result.BIOSMode -eq "Legacy") { 
            $win11Ready = $false
            $result.RecommendedAction += "Legacy BIOS detected - upgrade to UEFI for Windows 11"
            $result.RecommendedActionCode += 'LEGACY_BIOS'
        }
        if ($result.UEFIMode -eq $true -and $result.SecureBootEnabled -eq $false) { 
            $win11Ready = $false
            $result.RecommendedAction += "Secure Boot disabled - enable for Windows 11"
            $result.RecommendedActionCode += 'SECURE_BOOT_DISABLED'
        }
        $result.Windows11Ready = $win11Ready
        
        # TPM and Pending Reboot
        try { $tpm = Get-Tpm -ErrorAction SilentlyContinue; if ($tpm) { $result.TpmPresent = $tpm.TpmPresent; $result.TpmReady = $tpm.TpmReady } } catch {}
        $result.PendingReboot = Test-PendingReboot
        
        # Basic WinRE status from reagentc with robust parsing and fallback
        $reagentc = reagentc /info 2>&1
        $statusLine = ($reagentc | Select-String -Pattern "Windows RE status" -SimpleMatch | ForEach-Object { $_.Line })
        $enabled = $false
        if ($statusLine) { $enabled = ($statusLine -split ":",2)[1].Trim() -match "Enabled" }
        if (-not $statusLine) {
            try { $winreReg = Get-ItemProperty -Path 'HKLM:SYSTEM\CurrentControlSet\Control\WinRE' -ErrorAction Stop; if ($null -ne $winreReg.Enabled) { $enabled = [bool]$winreReg.Enabled } } catch {}
            $result.Diagnostics += 'ReagentcStatusRegFallback'
        }
        $result.WinREEnabled = $enabled
        $locationLine = ($reagentc | Select-String -Pattern "Windows RE location" -SimpleMatch | ForEach-Object { $_.Line })
        $location = $null
        if ($locationLine) { $location = ($locationLine -split ":",2)[1].Trim() }
        $bcdLine = ($reagentc | Select-String -Pattern "Boot Configuration Data (BCD) identifier" -SimpleMatch | ForEach-Object { $_.Line })
        if ($bcdLine) { $result.WinREBCDId = ($bcdLine -split ":",2)[1].Trim() }
        $result.WinRELocation = $location

        # Extract partition details
        if ($location -match "harddisk(\d+)\\partition(\d+)") {
            $diskNumber = [int]$matches[1]
            $partitionNumber = [int]$matches[2]
            
            try {
                $partition = Get-Partition -DiskNumber $diskNumber -PartitionNumber $partitionNumber -ErrorAction SilentlyContinue
                if ($partition) {
                    $result.PartitionSizeMB = [math]::Round($partition.Size / 1MB, 2)
                    $result.PartitionType = $partition.Type
                    if ($partition.GptType) { $result.PartitionGptType = $partition.GptType }
                    $recoveryGuid = '{DE94BBA4-06D1-4D40-A16A-BFD50179D6AC}'
                    $result.IsRecoveryGptGuid = ($partition.GptType -eq $recoveryGuid)
                    
                    # Growability info
                    try {
                        $supported = Get-PartitionSupportedSize -DiskNumber $diskNumber -PartitionNumber $partitionNumber -ErrorAction SilentlyContinue
                        if ($supported) {
                            $result.SupportedMaxSizeMB = [math]::Round($supported.SizeMax/1MB,2)
                            $result.CanGrowTo500MB = ($supported.SizeMax -ge (500MB))
                        }
                    } catch {}
                    
                    # Adjacency and last partition
                    $allParts = Get-Partition -DiskNumber $diskNumber -ErrorAction SilentlyContinue | Sort-Object -Property Offset
                    if ($allParts) {
                        $lastPart = $allParts[-1]
                        $result.IsLastPartition = ($lastPart.PartitionNumber -eq $partitionNumber)
                        $osPart = ($allParts | Where-Object { $_.Type -eq 'Basic' -and $_.AccessPaths -like '*\\' } | Select-Object -First 1)
                        if (-not $osPart) { $osPart = ($allParts | Where-Object { $_.Type -eq 'Basic' } | Sort-Object Offset | Select-Object -Last 1) }
                        if ($osPart) { $result.AdjacentToOSPartition = (($osPart.Offset + $osPart.Size) -eq $partition.Offset) -or (($partition.Offset + $partition.Size) -eq $osPart.Offset) }
                    }
                    
                    # Get disk type
                    $disk = Get-Disk -Number $diskNumber -ErrorAction SilentlyContinue
                    if ($disk) {
                        $result.DiskType = "$($disk.PartitionStyle) / $($disk.BusType)"
                    }
                }
            } catch {
                Write-Log "Partition analysis failed: $($_.Exception.Message)"
            }
        }

        # Count recovery partitions
        $allRecoveryPartitions = Get-Partition | Where-Object { $_.Type -eq "Recovery" }
        $result.RecoveryPartitionCount = ($allRecoveryPartitions | Measure-Object).Count

        # Check WinRE.wim file
        if ($location -and (Test-Path $location)) {
            $wimPath = Join-Path $location "winre.wim"
            if (Test-Path $wimPath) {
                $wimFile = Get-Item $wimPath -ErrorAction SilentlyContinue
                if ($wimFile) {
                    $result.WinREImageSizeMB = [math]::Round($wimFile.Length / 1MB, 2)
                    $result.PartitionAccessible = $true
                    
                    if ($result.PartitionSizeMB) {
                        $result.PartitionFreeMB = [math]::Round($result.PartitionSizeMB - $result.WinREImageSizeMB, 2)
                        if ($result.PartitionFreeMB -lt 100) {
                            $result.RecommendedAction += "Low free space: $($result.PartitionFreeMB)MB"
                            $result.RecommendedActionCode += 'LOW_RECOVERY_FREE_SPACE'
                        }
                    }
                }
            } else {
                $result.PartitionAccessible = $false
                $result.RecommendedAction += "WinRE.wim missing"
                $result.RecommendedActionCode += 'WINRE_WIM_MISSING'
            }
        } else {
            $result.PartitionAccessible = $false
            $result.RecommendedAction += "Recovery partition not accessible"
        }

        # KB5034441 vulnerability assessment (prefer free space, else size heuristic)
        if ($null -ne $result.PartitionFreeMB) {
            if ($result.PartitionFreeMB -lt 250) {
                $result.KB5034441Vulnerable = $true
                $result.RecommendedAction += "URGENT: Recovery partition <250MB free (current: $($result.PartitionFreeMB)MB). Resize to 500MB+)"
                $result.RecommendedActionCode += 'KB5034441_RESIZE'
            } else { $result.KB5034441Vulnerable = $false }
        } elseif ($null -ne $result.PartitionSizeMB) {
            if ($result.PartitionSizeMB -lt 500) { 
                $result.KB5034441Vulnerable = $true
                $result.RecommendedAction += "Recovery partition small (size: $($result.PartitionSizeMB)MB). Target 500MB+)"
                $result.RecommendedActionCode += 'KB5034441_RESIZE'
            } else { $result.KB5034441Vulnerable = $false }
        }

        # BitLocker status
        try {
            $blvs = Get-BitLockerVolume -ErrorAction SilentlyContinue
            $osVolume = $blvs | Where-Object { $_.VolumeType -eq "OperatingSystem" } | Select-Object -First 1
            if ($osVolume) {
                $result.BitLockerStatus = $osVolume.ProtectionStatus.ToString()
            } else {
                $result.BitLockerStatus = "Unknown"
            }
        } catch {
            $result.BitLockerStatus = "Unknown"
            $result.Diagnostics += 'BitLockerCmdFailed'
        }

        # Check if WinRE is disabled
        if (!$result.WinREEnabled) {
            $result.RecommendedAction += "WinRE disabled - run 'reagentc /enable'"
            $result.RecommendedActionCode += 'WINRE_DISABLED'
        }

        # Calculate confidence score
        $score = 0
        if ($result.WinREEnabled) { $score += 30 }
        if ($result.PartitionAccessible) { $score += 25 }
        if ($result.BitLockerStatus -eq "On") { $score += 15 }
        if ($result.WinREImageSizeMB -and $result.WinREImageSizeMB -gt 100) { $score += 10 }
        if ($result.PartitionSizeMB -and $result.PartitionSizeMB -ge 250) { $score += 10 }
        if ($result.PartitionFreeMB -and $result.PartitionFreeMB -ge 100) { $score += 5 }
        if ($result.Windows11Ready) { $score += 5 }
        if ($result.TpmPresent -and $result.TpmReady) { $score += 5 }
        if ($result.IsRecoveryGptGuid) { $score += 5 }
        $result.ConfidenceScore = $score

        # Determine severity
        if ($score -ge 85) { 
            $result.Severity = "Healthy" 
        } elseif ($score -ge 60) { 
            $result.Severity = "Warning" 
        } else { 
            $result.Severity = "Critical" 
        }
        
        # Override if KB5034441 vulnerable
        if ($result.KB5034441Vulnerable -eq $true) {
            $result.Severity = "Critical"
        }
        # Pending reboot is a servicing prerequisite; warn if otherwise healthy
        if ($result.PendingReboot -eq $true -and $result.Severity -eq 'Healthy') {
            $result.Severity = 'Warning'
            $result.RecommendedAction += 'Pending reboot detected - reboot before servicing WinRE.'
            $result.RecommendedActionCode += 'PENDING_REBOOT'
        }

        # Compute remediation readiness (for safe automation)
        $result.RemediationReady = ($result.KB5034441Vulnerable -eq $true -and
                                    $result.CanGrowTo500MB -eq $true -and
                                    $result.IsLastPartition -eq $true -and
                                    $result.AdjacentToOSPartition -eq $true -and
                                    $result.PendingReboot -eq $false)
        
        # Add success message if healthy
        if ($result.Severity -eq "Healthy" -and $result.RecommendedAction.Count -eq 0) {
            $result.RecommendedAction += "No action required - WinRE is healthy"
        }
        
        # Calculate execution time
        $functionEndTime = Get-Date
        $result.ScriptExecutionTimeMS = [math]::Round(($functionEndTime - $functionStartTime).TotalMilliseconds, 2)
        
    } catch {
        $result.Error = $_.Exception.Message
        Write-Log "Error: $($_.Exception.Message)"
    }
    
    return $result
}
#endregion

#region Main Execution
try {
    Write-Log "=== WinRE Health Detection Started ==="
    
    # Get WinRE status
    $status = Get-WinREStatus
    
    # Set NinjaOne custom fields
    try {
        Ninja-Property-Set winreEnabled $status.WinREEnabled
        Ninja-Property-Set winreSeverity $status.Severity
        Ninja-Property-Set winreKB5034441Vulnerable $status.KB5034441Vulnerable
        Ninja-Property-Set winreConfidenceScore $status.ConfidenceScore
        Ninja-Property-Set winreRecommendation ($status.RecommendedAction -join "; ")
        Ninja-Property-Set winrePartitionSizeMB $status.PartitionSizeMB
        Ninja-Property-Set winrePartitionFreeMB $status.PartitionFreeMB
        Ninja-Property-Set winreLastCheck (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        Ninja-Property-Set winreBitLockerStatus $status.BitLockerStatus
        Ninja-Property-Set winreWindows11Ready $status.Windows11Ready
        Ninja-Property-Set winreSecureBoot $status.SecureBootEnabled
        Ninja-Property-Set winreFirmwareType $status.BIOSMode
        Ninja-Property-Set winreTpmPresent $status.TpmPresent
        Ninja-Property-Set winreTpmReady $status.TpmReady
        Ninja-Property-Set winrePendingReboot $status.PendingReboot
        Ninja-Property-Set winreIsRecoveryGptGuid $status.IsRecoveryGptGuid
        Ninja-Property-Set winrePartitionGptType $status.PartitionGptType
        Ninja-Property-Set winreIsLastPartition $status.IsLastPartition
        Ninja-Property-Set winreAdjacentToOSPartition $status.AdjacentToOSPartition
        Ninja-Property-Set winreSupportedMaxSizeMB $status.SupportedMaxSizeMB
        Ninja-Property-Set winreCanGrowTo500MB $status.CanGrowTo500MB
        Ninja-Property-Set winreBCDId $status.WinREBCDId
        Ninja-Property-Set winreRemediationReady $status.RemediationReady
        Ninja-Property-Set winreRecommendedActionCode ($status.RecommendedActionCode -join ',')
        Ninja-Property-Set winreScriptVersion $status.ScriptVersion
        Ninja-Property-Set winreSchemaVersion $status.SchemaVersion
        
        Write-Log "Successfully updated NinjaOne custom fields"
    } catch {
        Write-Log "Failed to set NinjaOne custom fields: $($_.Exception.Message)"
    }
    
    # Optional: Send to Azure Log Analytics if enabled
    $enableAzureLogging = Ninja-Property-Get ENABLE_AZURE_LOGGING -ErrorAction SilentlyContinue
    if ($enableAzureLogging -eq $true -or $enableAzureLogging -eq "true") {
        try {
            $workspaceId = Ninja-Property-Get LA_WORKSPACE_ID
            $workspaceKey = Ninja-Property-Get LA_WORKSPACE_KEY
            
            if ($workspaceId -and $workspaceKey) {
                Write-Log "Sending data to Azure Log Analytics..."
                $azureResult = Send-ToLogAnalytics -Data $status -WorkspaceId $workspaceId -WorkspaceKey $workspaceKey -LogType "WinREHealth"
                if ($azureResult) {
                    Write-Log "Data successfully sent to Azure"
                }
            } else {
                Write-Log "Azure credentials not configured, skipping Log Analytics upload"
            }
        } catch {
            Write-Log "Azure Log Analytics upload failed: $($_.Exception.Message)"
        }
    }
    
    # Optional: Create NinjaOne ticket for critical issues
    if ($status.Severity -eq "Critical") {
        try {
            $ticketSubject = "CRITICAL: WinRE Health Issue - $($status.ComputerName)"
            $ticketBody = @"
WinRE Health Status: CRITICAL

Computer: $($status.ComputerName)
Manufacturer: $($status.Manufacturer)
Model: $($status.Model)
Serial Number: $($status.SerialNumber)

Issue Details:
- WinRE Enabled: $($status.WinREEnabled)
- KB5034441 Vulnerable: $($status.KB5034441Vulnerable)
- Partition Size: $($status.PartitionSizeMB) MB
- Partition Free: $($status.PartitionFreeMB) MB
- GPT Type: $($status.PartitionGptType) (IsRecoveryGuid=$($status.IsRecoveryGptGuid))
- Can Grow to 500MB: $($status.CanGrowTo500MB) (Max=$($status.SupportedMaxSizeMB)MB)
- Confidence Score: $($status.ConfidenceScore)

Recommended Actions:
$($status.RecommendedAction -join "`n")

Automatic ticket created by WinRE Health Monitoring
"@
            
            # Note: Uncomment and configure if using NinjaOne ticketing integration
            # New-NinjaTicket -Subject $ticketSubject -Description $ticketBody -Priority "High" -Status "Open"
            
            # For analyzers, log subject/body to mark them used even if ticketing is not enabled
            Write-Log ("Ticket Subject: " + $ticketSubject)
            Write-Log ("Ticket Body Preview: " + ($ticketBody.Substring(0, [Math]::Min(200, $ticketBody.Length))))
            Write-Log "Critical issue detected - ticket should be created"
        } catch {
            Write-Log "Failed to create ticket: $($_.Exception.Message)"
        }
    }
    
    # Output summary
    $totalElapsed = [math]::Round(((Get-Date) - $scriptStartTime).TotalMilliseconds, 2)
    Write-Log "=== Detection Complete ==="
    Write-Log "Severity: $($status.Severity)"
    Write-Log "Confidence Score: $($status.ConfidenceScore)"
    Write-Log "KB5034441 Vulnerable: $($status.KB5034441Vulnerable)"
    Write-Log "Function Execution Time: $($status.ScriptExecutionTimeMS)ms"
    Write-Log "Total Script Time: $totalElapsed ms"
    
    # Exit with appropriate code for NinjaOne
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
    Write-Log "Fatal error: $($_.Exception.Message)"
    Write-Output "ERROR: $($_.Exception.Message)"
    exit 1
}
#endregion
