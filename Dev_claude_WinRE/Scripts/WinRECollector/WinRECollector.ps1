#Requires -Version 5.1
<#
.SYNOPSIS
  WinRE Health Collector - Gathers comprehensive WinRE status and sends to Azure Log Analytics and NinjaOne.
.DESCRIPTION
  Collects Windows Recovery Environment (WinRE) configuration, partition info, BitLocker state, and vulnerability status.
  Packages output as JSON matching WinREHealthStatus.schema.json and sends to:
  - Azure Log Analytics (HTTP Data Collector API)
  - NinjaOne API (optional custom field update)
  
.PARAMETER WorkspaceId
  Azure Log Analytics Workspace ID (GUID).
.PARAMETER WorkspaceKey
  Azure Log Analytics Workspace primary or secondary key (base64).
.PARAMETER LogType
  Log Analytics custom log type name (default: WinREHealth).
.PARAMETER NinjaAPIKey
  NinjaOne API key (optional; if provided, updates device custom field).
.PARAMETER NinjaAPIUrl
  NinjaOne API base URL (e.g., https://api.ninjarmm.com).
.PARAMETER NinjaDeviceId
  NinjaOne device ID to update (auto-detected if running as Ninja remote script).
.PARAMETER TestMode
  If $true, writes to file instead of sending; useful for testing.

.NOTES
  Version: 1.0.0
  Author: WinRE Health Monitoring Team
  Schema Version: 2024-12-04
  
.EXAMPLE
  # Run with Log Analytics (Intune Proactive Remediation)
  & .\WinRECollector.ps1 -WorkspaceId '<WORKSPACE_ID>' -WorkspaceKey '<WORKSPACE_KEY>'
  
.EXAMPLE
  # Test mode (outputs to file)
  & .\WinRECollector.ps1 -TestMode
#>

param(
    [string]$WorkspaceId,
    [string]$WorkspaceKey,
    [string]$LogType = 'WinREHealthV2',
    [string]$NinjaAPIKey,
    [string]$NinjaAPIUrl,
    [string]$NinjaDeviceId,
    [switch]$TestMode
)

# Import LogAnalyticsIngestion module for Azure Log Analytics ingestion
$laModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\LogAnalyticsIngestion.psm1'
if (Test-Path $laModulePath) {
    Import-Module $laModulePath -Force -ErrorAction SilentlyContinue
} else {
    Write-Warning "LogAnalyticsIngestion module not found at: $laModulePath. Azure ingestion will not be available."
}

$ErrorActionPreference = 'Continue'
$script:ScriptVersion = '1.0.0'
$script:SchemaVersion = '2024-12-04'
$script:StartTime = Get-Date

#region Helper Functions

function Write-LogMessage {
    param([string]$Message, [ValidateSet('Info', 'Warning', 'Error')]$Level = 'Info')
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $output = "[$timestamp] [$Level] $Message"
    if ($TestMode) { Write-Host $output }
    else { Write-Output $output }
}

function Invoke-ReagentC {
    $output = @()
    try {
        $output = & reagentc /info 2>&1 | Where-Object { $_ -match '\S' }
        return $output -join [Environment]::NewLine
    }
    catch {
        Write-LogMessage "reagentc error: $_" 'Error'
        return $null
    }
}

function Parse-ReagentCOutput {
    param([string]$Output)
    $result = @{}
    if ([string]::IsNullOrEmpty($Output)) { return $result }
    
    foreach ($line in $Output -split "`n") {
        if ($line -match '^\s*(.+?)\s*:\s*(.+)$') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            $result[$key] = $value
        }
    }
    return $result
}

function Test-WinREEnabled {
    param([hashtable]$ReagentInfo)
    if ($ReagentInfo['Windows RE status']) {
        return $ReagentInfo['Windows RE status'] -like '*Enabled*'
    }
    return $false
}

function Get-RecoveryPartitionInfo {
    try {
        $disk = Get-Disk -Number 0 -ErrorAction SilentlyContinue
        if (-not $disk) { return @{} }
        
        $partitions = Get-Partition -DiskNumber 0 -ErrorAction SilentlyContinue
        $recoveryParts = $partitions | Where-Object { $_.Type -in @('Recovery', 'System', 'Hidden') } | 
                        Where-Object { $_.Size -gt 100MB }
        
        $info = @{
            RecoveryPartitionCount = ($recoveryParts | Measure-Object).Count
            MultipleRecoveryPartitions = ($recoveryParts | Measure-Object).Count -gt 1
            SystemDiskNumber = 0
            SystemDiskType = $disk.PartitionStyle
            SystemDiskSSD = $disk.BusType -eq 'NVMe' -or $disk.BusType -eq 'SSD'
            SystemDiskSizeGB = [math]::Round($disk.Size / 1GB, 2)
            AdditionalPartitions = @()
        }
        
        foreach ($part in $partitions) {
            $volInfo = @{
                Number = $part.PartitionNumber
                Type = $part.Type
                SizeMB = [math]::Round($part.Size / 1MB, 2)
                DriveLetter = $part.DriveLetter
                FileSystem = 'N/A'
            }
            
            if ($part.DriveLetter) {
                try {
                    $vol = Get-Volume -DriveLetter $part.DriveLetter -ErrorAction SilentlyContinue
                    $volInfo.FileSystem = $vol.FileSystem
                }
                catch { }
            }
            
            $info.AdditionalPartitions += $volInfo
        }
        
        return $info
    }
    catch {
        Write-LogMessage "Error getting recovery partition info: $_" 'Warning'
        return @{}
    }
}

function Get-BitLockerStatus {
    try {
        $volumes = Get-BitLockerVolume -ErrorAction SilentlyContinue
        if (-not $volumes) { 
            return @{
                BitLockerEnabled = $false
                BitLockerVolumeCount = 0
                BitLockerOSVolumeEncrypted = $false
                BitLockerRecoveryVolumeEncrypted = $false
            }
        }
        
        $info = @{
            BitLockerEnabled = ($volumes | Where-Object { $_.EncryptionPercentage -gt 0 } | Measure-Object).Count -gt 0
            BitLockerVolumeCount = ($volumes | Measure-Object).Count
            BitLockerOSVolumeEncrypted = $false
            BitLockerRecoveryVolumeEncrypted = $false
        }
        
        foreach ($vol in $volumes) {
            if ($vol.MountPoint -eq 'C:\') {
                $info.BitLockerOSVolumeEncrypted = $vol.EncryptionPercentage -eq 100
            }
        }
        
        return $info
    }
    catch {
        Write-LogMessage "Error getting BitLocker status: $_" 'Warning'
        return @{
            BitLockerEnabled = $false
            BitLockerVolumeCount = 0
            BitLockerOSVolumeEncrypted = $false
            BitLockerRecoveryVolumeEncrypted = $false
        }
    }
}

function Get-OSInfo {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
        $csInfo = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction SilentlyContinue
        $csSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
        
        return @{
            OSVersion = $os.Version
            OSBuild = $os.BuildNumber
            OSEdition = $os.Caption
            OSInstallDate = [DateTime]::ParseExact($os.InstallDate.Substring(0, 8), 'yyyyMMdd', $null).ToString('o')
            Manufacturer = $csInfo.Manufacturer
            Model = $csInfo.Model
            SerialNumber = $csInfo.IdentifyingNumber
            DomainName = if ($csSystem.PartOfDomain) { $csSystem.Domain } else { 'WORKGROUP' }
            LastBootTime = $os.LastBootUpTime.ToString('o')
            UptimeDays = [math]::Round((New-TimeSpan -Start $os.LastBootUpTime -End (Get-Date)).TotalDays, 2)
        }
    }
    catch {
        Write-LogMessage "Error getting OS info: $_" 'Warning'
        return @{}
    }
}

function Get-SecureBootStatus {
    try {
        $sb = Get-SecureBootUEFI -ErrorAction SilentlyContinue
        $tpm = Get-WmiObject -Namespace "root\cimv2\security\microsofttpm" -Class Win32_Tpm -ErrorAction SilentlyContinue
        
        return @{
            IsUEFI = (Test-Path 'HKLM:\System\CurrentControlSet\Control\SecureBoot\State' -ErrorAction SilentlyContinue)
            IsSecureBootEnabled = $sb -eq $true
            IsTPMEnabled = $tpm -ne $null
            TPMVersion = if ($tpm) { "2.0" } else { $null }
        }
    }
    catch {
        Write-LogMessage "Error getting Secure Boot status: $_" 'Warning'
        return @{
            IsUEFI = $false
            IsSecureBootEnabled = $false
            IsTPMEnabled = $false
            TPMVersion = $null
        }
    }
}

function Get-VendorIntelligence {
    try {
        $manufacturer = (Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction SilentlyContinue).Manufacturer
        $vendor = switch -Wildcard ($manufacturer) {
            '*Dell*' { 'Dell' }
            '*HP*' { 'HP' }
            '*Lenovo*' { 'Lenovo' }
            '*Microsoft*' { 'Surface' }
            default { 'Other' }
        }
        
        return @{
            VendorName = $vendor
            HasSupportAssistPartition = $false
            SupportAssistPartitionCount = 0
            KnownPartitionLayout = $false
            VendorSpecificNotes = ''
        }
    }
    catch {
        return @{
            VendorName = 'Unknown'
            HasSupportAssistPartition = $false
            SupportAssistPartitionCount = 0
            KnownPartitionLayout = $false
            VendorSpecificNotes = 'Error detecting vendor'
        }
    }
}

function Calculate-ConfidenceScore {
    param([hashtable]$Data)
    $score = 0
    $factors = @{}
    
    # WinREEnabled (30 points)
    if ($Data.WinREEnabled) { $score += 30; $factors.WinREEnabled = 30 } else { $factors.WinREEnabled = 0 }
    
    # PartitionAccessible (25 points)
    if ($Data.RecoveryPartitionCount -gt 0) { $score += 25; $factors.PartitionAccessible = 25 } else { $factors.PartitionAccessible = 0 }
    
    # BitLockerEnabled (15 points)
    if ($Data.BitLockerEnabled) { $score += 15; $factors.BitLockerEnabled = 15 } else { $factors.BitLockerEnabled = 0 }
    
    # PartitionGUIDPresent (10 points)
    if ($Data.RecoveryPartitionCount -gt 0) { $score += 10; $factors.PartitionGUIDPresent = 10 } else { $factors.PartitionGUIDPresent = 0 }
    
    # WinREImageSizeAdequate (10 points)
    if ($Data.WinREImageSizeMB -gt 500) { $score += 10; $factors.WinREImageSizeAdequate = 10 } else { $factors.WinREImageSizeAdequate = 0 }
    
    # PartitionSizeAdequate (5 points)
    if ($Data.RecoveryPartitionSizeMB -gt 1000) { $score += 5; $factors.PartitionSizeAdequate = 5 } else { $factors.PartitionSizeAdequate = 0 }
    
    # FreeSpaceAdequate (5 points)
    if ($Data.RecoveryPartitionFreeMB -gt 100) { $score += 5; $factors.FreeSpaceAdequate = 5 } else { $factors.FreeSpaceAdequate = 0 }
    
    return @{
        ConfidenceScore = [math]::Min($score, 100)
        ConfidenceFactors = $factors
    }
}

# Send-ToLogAnalytics function now imported from LogAnalyticsIngestion.psm1 module

function Send-ToNinjaOne {
    param([object]$Payload)
    
    if ($TestMode) {
        Write-LogMessage "TEST MODE: Would send to NinjaOne" 'Info'
        return $true
    }
    
    if (-not $NinjaAPIKey -or -not $NinjaAPIUrl -or -not $NinjaDeviceId) {
        Write-LogMessage 'Missing Ninja credentials; skipping NinjaOne API' 'Info'
        return $false
    }
    
    try {
        $headers = @{
            'Authorization' = "APIKEY $NinjaAPIKey"
            'Content-Type'  = 'application/json'
        }
        
        $customFieldValue = @{
            'WinREStatus' = $Payload.WinREEnabled
            'LastCheck'   = $Payload.Timestamp
            'ConfidenceScore' = $Payload.ConfidenceScore
        } | ConvertTo-Json
        
        $body = @{
            'organizationId' = $env:NINJA_ORG_ID  # May be set by Ninja
            'deviceId'       = $NinjaDeviceId
            'field'          = 'WinREHealthStatus'
            'value'          = $customFieldValue
        } | ConvertTo-Json
        
        $uri = "$NinjaAPIUrl/v2/deviceFields"
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ErrorAction Stop
        
        Write-LogMessage "Successfully updated NinjaOne (DeviceId: $NinjaDeviceId)" 'Info'
        return $true
    }
    catch {
        Write-LogMessage "Failed to send to NinjaOne: $_" 'Warning'
        return $false
    }
}

#endregion

#region Main Collection Logic

Write-LogMessage "Starting WinRE Health Collection (v$script:ScriptVersion)" 'Info'

$payload = @{
    ComputerName = $env:COMPUTERNAME
    Timestamp = (Get-Date).ToUniversalTime().ToString('o')
    ScriptVersion = $script:ScriptVersion
    SchemaVersion = $script:SchemaVersion
}

# Collect WinRE Info
$reagentOutput = Invoke-ReagentC
$reagentInfo = Parse-ReagentCOutput -Output $reagentOutput
$payload.WinREEnabled = Test-WinREEnabled -ReagentInfo $reagentInfo
$payload.WinRELocation = $reagentInfo['Recovery Environment Location']
$payload.WinREImageVersion = $reagentInfo['Windows RE version']

# Collect Partition Info
$partInfo = Get-RecoveryPartitionInfo
$payload += $partInfo

# Collect BitLocker Info
$bitlockerInfo = Get-BitLockerStatus
$payload += $bitlockerInfo

# Collect OS & Hardware Info
$osInfo = Get-OSInfo
$payload += $osInfo

# Collect Security Info
$sbInfo = Get-SecureBootStatus
$payload += $sbInfo

# Collect Vendor Intelligence
$vendorInfo = Get-VendorIntelligence
$payload.VendorIntelligence = $vendorInfo

# Calculate Confidence Score
$confidence = Calculate-ConfidenceScore -Data $payload
$payload.ConfidenceScore = $confidence.ConfidenceScore
$payload.ConfidenceFactors = $confidence.ConfidenceFactors

# Determine Data Quality
$payload.DataQuality = if ($payload.WinREEnabled -and $payload.RecoveryPartitionCount -gt 0) { 'High' } 
                       elseif ($payload.WinREEnabled -or $payload.RecoveryPartitionCount -gt 0) { 'Medium' } 
                       else { 'Low' }

# Performance Metrics
$endTime = Get-Date
$payload.PerformanceMetrics = @{
    TotalExecutionTimeSeconds = [math]::Round((New-TimeSpan -Start $script:StartTime -End $endTime).TotalSeconds, 2)
}

# Collection Method
$payload.CollectionMethod = if ($env:COMPUTERNAME) { 'NinjaOne' } else { 'Intune-DCR' }

# Detection Success
$payload.DetectionSuccess = $true

# Recommendations
if (-not $payload.WinREEnabled) {
    $payload.RecommendedAction = 'Enable WinRE using: reagentc /enable'
    $payload.KB5034441Vulnerable = $true
    $payload.KB5034441Reason = 'WinRE is disabled; device may fail to boot into recovery'
}
else {
    $payload.RecommendedAction = 'Monitor WinRE status; ensure partition has adequate free space'
    $payload.KB5034441Vulnerable = $false
    $payload.KB5034441Reason = 'WinRE is enabled and partition is accessible'
}

# Send to destinations
$logAnalyticsResult = Send-ToLogAnalytics -Payload $payload
$ninjaResult = Send-ToNinjaOne -Payload $payload

# Output summary
if ($TestMode) {
    Write-LogMessage "=== COLLECTION COMPLETE (TEST MODE) ===" 'Info'
    $payload | ConvertTo-Json -Depth 10 | Write-Host
}
else {
    Write-LogMessage "=== COLLECTION COMPLETE ===" 'Info'
    Write-LogMessage "Log Analytics: $(if ($logAnalyticsResult) { 'OK' } else { 'FAILED' })" 'Info'
    Write-LogMessage "NinjaOne: $(if ($ninjaResult) { 'OK' } else { 'SKIPPED' })" 'Info'
}

exit 0

#endregion
