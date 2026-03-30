# WinRE Remediation Script
# Safely resize recovery partition and (re)enable WinRE if vulnerable (KB5034441) conditions met.
# Version: 1.0.0

param(
    [int]$TargetSizeMB = 550,              # Desired minimum recovery partition size
    [switch]$WhatIf,                       # Simulation only
    [switch]$OutputStdOut,                 # Emit JSON only; no files
    [switch]$Ephemeral,                    # Ephemeral temp working directory
    [switch]$Persistent,                   # Opt-in persistent ProgramData directory
    [switch]$TestMode,                     # Keep artifacts even if Ephemeral

    # Direct Log Analytics ingestion (optional)
    [string]$WorkspaceId,
    [string]$WorkspaceKey,
    [string]$LogType = 'WinRERemediation',
    [int]$RetryCount = 3,
    [int]$RetryDelaySeconds = 2
)

# Import LogAnalyticsIngestion module for Azure Log Analytics ingestion
$laModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\LogAnalyticsIngestion.psm1'
if (Test-Path $laModulePath) {
    Import-Module $laModulePath -Force -ErrorAction SilentlyContinue
} else {
    Write-Warning "LogAnalyticsIngestion module not found at: $laModulePath. Azure ingestion will not be available."
}

# Region: Setup
$scriptVersion = '1.0.0'
$startTime = Get-Date
if ($OutputStdOut) {
    $WorkDir = $null; $LogFile = $null
} else {
    if ($Persistent) { $WorkDir = 'C:\ProgramData\WinRERemediation' } else { $WorkDir = Join-Path $env:TEMP ("WinRERemediate_" + [Guid]::NewGuid()) ; $Ephemeral = $true }
    if (!(Test-Path $WorkDir)) { New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null }
    $LogFile = Join-Path $WorkDir 'WinRERemediate.log'
}
function Write-Log { param([string]$Message); if ($OutputStdOut) { return }; if ($LogFile) { Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): $Message" } }

# Send-ToLogAnalytics function now imported from LogAnalyticsIngestion.psm1 module

# Region: Helper - Parse WinRE reagentc output
function Get-WinREInfo {
    $info = reagentc /info 2>&1
    $enabled = $false
    $loc = $null
    $statusLine = ($info | Select-String -Pattern 'Windows RE status' | ForEach-Object { $_.Line })
    if ($statusLine) { $enabled = (($statusLine -split ':',2)[1].Trim() -match 'Enabled') }
    $locLine = ($info | Select-String -Pattern 'Windows RE location' | ForEach-Object { $_.Line })
    if ($locLine) { $loc = (($locLine -split ':',2)[1].Trim()) }
    [pscustomobject]@{ Enabled=$enabled; Location=$loc }
}

function Test-PendingReboot {
    try {
        $paths = @( 'HKLM:SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired', 'HKLM:SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' )
        foreach ($p in $paths) { if (Test-Path $p) { return $true } }
        $sm = 'HKLM:SYSTEM\CurrentControlSet\Control\Session Manager'
        $val = (Get-ItemProperty -Path $sm -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue)
        if ($val) { return $true }
        return $false
    } catch { return $false }
}

# Pre-flight safety evaluation (partition, BitLocker, SMART, chkdsk, reboot)
function Test-WinREPreFlight {
    param(
        [int]$RequiredFreeMB = 250,
        [int]$MaxResizeMB = $TargetSizeMB,
        [switch]$SkipSmart
    )
    $result = [ordered]@{
        Timestamp = (Get-Date -Format o)
        ComputerName = $env:COMPUTERNAME
        PartitionSizeMB = $null
        PartitionFreeMB = $null
        BitLockerProtected = $false
        PendingReboot = Test-PendingReboot
        SmartHealthy = $true
        ChkDskClean = $true
        WinREEnabled = $null
        CanResize = $false
        RiskFlags = @()
        Ready = $false
    }
    try {
        $winre = Get-WinREInfo
        $result.WinREEnabled = $winre.Enabled
        if (-not $winre.Location) { $result.RiskFlags += 'MISSING_LOCATION'; throw 'WinRE location unavailable' }
        if ($winre.Location -match 'harddisk(\d+)\\partition(\d+)') {
            $diskNumber = [int]$matches[1]; $partNumber = [int]$matches[2]
            $partition = Get-Partition -DiskNumber $diskNumber -PartitionNumber $partNumber -ErrorAction SilentlyContinue
            if ($partition) {
                $result.PartitionSizeMB = [math]::Round($partition.Size/1MB,2)
                try {
                    $wimPath = Join-Path $winre.Location 'winre.wim'
                    if (Test-Path $wimPath) {
                        $wim = Get-Item $wimPath -ErrorAction SilentlyContinue
                        if ($wim) { $result.PartitionFreeMB = [math]::Round(($result.PartitionSizeMB - ($wim.Length/1MB)),2) }
                    }
                } catch { $result.RiskFlags += 'WIM_ACCESS_FAIL' }
                try {
                    $supported = Get-PartitionSupportedSize -DiskNumber $diskNumber -PartitionNumber $partNumber -ErrorAction SilentlyContinue
                    if ($supported) {
                        $maxMb = [math]::Round($supported.SizeMax/1MB,2)
                        $result.CanResize = ($maxMb -ge $MaxResizeMB)
                        if (-not $result.CanResize) { $result.RiskFlags += 'INSUFFICIENT_MAX_SIZE' }
                    } else { $result.RiskFlags += 'SUPPORTED_SIZE_UNAVAILABLE' }
                } catch { $result.RiskFlags += 'SUPPORTED_SIZE_ERROR' }
            } else { $result.RiskFlags += 'PARTITION_NOT_FOUND' }
        } else { $result.RiskFlags += 'LOCATION_PARSE_FAIL' }

        # BitLocker status (ensure not locked or encrypting)
        try {
            $bl = Get-BitLockerVolume -ErrorAction SilentlyContinue | Where-Object VolumeType -eq 'OperatingSystem' | Select-Object -First 1
            if ($bl) {
                $result.BitLockerProtected = ($bl.ProtectionStatus -eq 'On')
                if ($bl.LockStatus -ne 'Unlocked') { $result.RiskFlags += 'BITLOCKER_LOCKED' }
                if ($bl.EncryptionPercentage -lt 100) { $result.RiskFlags += 'BITLOCKER_IN_PROGRESS' }
            } else { $result.RiskFlags += 'BITLOCKER_UNKNOWN' }
        } catch { $result.RiskFlags += 'BITLOCKER_ERROR' }

        # SMART health (skip for virtual or if unavailable)
        if (-not $SkipSmart) {
            try {
                $phys = Get-PhysicalDisk -ErrorAction SilentlyContinue | Select-Object FriendlyName, HealthStatus
                if ($phys) {
                    $unhealthy = $phys | Where-Object HealthStatus -notin 'Healthy','Unknown'
                    if ($unhealthy) { $result.SmartHealthy = $false; $result.RiskFlags += 'SMART_UNHEALTHY' }
                }
            } catch { $result.RiskFlags += 'SMART_ERROR' }
        }

        # Lightweight chkdsk (read-only scan) skip in WhatIf for speed
        try {
            if (-not $WhatIf) {
                $chkdsk = chkdsk C: /scan 2>&1 | Select-String -Pattern 'Windows has scanned the file system and found no problems'
                if (-not $chkdsk) { $result.ChkDskClean = $false; $result.RiskFlags += 'CHKDSK_WARN' }
            }
        } catch { $result.RiskFlags += 'CHKDSK_ERROR' }

        $sizeNeedsResize = ($result.PartitionSizeMB -lt $MaxResizeMB)
        $freeSpaceConcern = ($result.PartitionFreeMB -lt $RequiredFreeMB)
        $noBlocking = ($result.PendingReboot -eq $false -and $result.ChkDskClean -eq $true -and $result.SmartHealthy -eq $true)
        $resizeNeeded = ($sizeNeedsResize -or $freeSpaceConcern)
        $result.Ready = ($resizeNeeded -and $result.CanResize -and $noBlocking)
    } catch { $result.RiskFlags += 'GENERAL_ERROR' }
    return $result
}

# Region: Main Logic
$result = [ordered]@{
    Timestamp = (Get-Date -Format o)
    ComputerName = $env:COMPUTERNAME
    OldSizeMB = $null
    NewSizeMB = $null
    TargetSizeMB = $TargetSizeMB
    ActionPerformed = @()
    Success = $false
    Message = $null
    ScriptVersion = $scriptVersion
    PendingReboot = $null
    WinREEnabledBefore = $null
    WinREEnabledAfter = $null
    RemediationAttempted = $false
    AdditionalPreFlight = $null
}

try {
    Write-Log "Starting WinRE remediation (target=$TargetSizeMB MB, whatIf=$WhatIf)"
    $preFlight = Test-WinREPreFlight -RequiredFreeMB 250 -MaxResizeMB $TargetSizeMB
    $result.PendingReboot = $preFlight.PendingReboot
    $result.AdditionalPreFlight = $preFlight
    if (-not $preFlight.Ready) {
        $result.Message = "Pre-flight not ready: Flags=[${($preFlight.RiskFlags -join ',')}]"
        Write-Log $result.Message
        $result.Success = $false
        throw 'Aborting due to failed pre-flight checks.'
    }

    $winre = Get-WinREInfo
    $result.WinREEnabledBefore = $winre.Enabled
    if (-not $winre.Location) { throw 'WinRE location not found; cannot remediate.' }

    if ($winre.Location -match 'harddisk(\d+)\\partition(\d+)') {
        $diskNumber = [int]$matches[1]; $partNumber = [int]$matches[2]
        $partition = Get-Partition -DiskNumber $diskNumber -PartitionNumber $partNumber -ErrorAction SilentlyContinue
        if (-not $partition) { throw 'Recovery partition object not found.' }
        $oldSizeMB = [math]::Round($partition.Size/1MB,2)
        $result.OldSizeMB = $oldSizeMB
        if ($oldSizeMB -ge $TargetSizeMB) {
            $result.Message = "Partition already >= target ($oldSizeMB MB)"
            $result.Success = $true
        } else {
            $supported = Get-PartitionSupportedSize -DiskNumber $diskNumber -PartitionNumber $partNumber -ErrorAction SilentlyContinue
            if (-not $supported) { throw 'Supported size info unavailable.' }
            $maxMB = [math]::Round($supported.SizeMax/1MB,2)
            if ($maxMB -lt $TargetSizeMB) { throw "Cannot grow to target ($TargetSizeMB MB); max supported $maxMB MB" }
            $result.RemediationAttempted = $true
            $resizeTargetBytes = ($TargetSizeMB * 1MB)
            $result.ActionPerformed += "ResizePartition:$oldSizeMB->$TargetSizeMB"
            if ($WhatIf) {
                Write-Log "[WhatIf] Would resize partition from $oldSizeMB MB to $TargetSizeMB MB"
                $result.Message = 'Simulation only - no changes made.'
                $result.Success = $true
            } else {
                Write-Log "Resizing partition from $oldSizeMB MB to $TargetSizeMB MB"
                Resize-Partition -DiskNumber $diskNumber -PartitionNumber $partNumber -Size $resizeTargetBytes -ErrorAction Stop
                Start-Sleep -Seconds 2
                $partitionRefreshed = Get-Partition -DiskNumber $diskNumber -PartitionNumber $partNumber -ErrorAction SilentlyContinue
                $newSizeMB = [math]::Round($partitionRefreshed.Size/1MB,2)
                $result.NewSizeMB = $newSizeMB
                if ($newSizeMB -ge $TargetSizeMB) {
                    Write-Log "Resize successful -> $newSizeMB MB"
                    $result.Success = $true
                    $result.Message = "Resize completed"
                } else { throw "Resize incomplete; now $newSizeMB MB (< target)." }
            }
        }
    } else { throw 'Could not parse disk/partition from WinRE location.' }

    # Ensure WinRE enabled after resize
    if ($result.Success -and -not $WhatIf) {
        try { reagentc /enable | Out-Null } catch { Write-Log "Enable WinRE failed: $($_.Exception.Message)" }
    }
    $result.WinREEnabledAfter = (Get-WinREInfo).Enabled

} catch {
    $result.Message = $_.Exception.Message
    Write-Log "Remediation error: $($result.Message)"
}

# Emit / persist
$json = $result | ConvertTo-Json -Depth 6
if ($OutputStdOut) { Write-Output $json } else { $json | Out-File -FilePath (Join-Path $WorkDir 'WinRERemediate.json') -Encoding UTF8 }

# Ingest if credentials supplied
if ($WorkspaceId -and $WorkspaceKey) {
    [void](Send-ToLogAnalytics -Data $result -WorkspaceId $WorkspaceId -WorkspaceKey $WorkspaceKey -LogType $LogType -RetryCount $RetryCount -RetryDelaySeconds $RetryDelaySeconds)
}

# Cleanup ephemeral
if ($Ephemeral -and -not $TestMode -and -not $Persistent -and $WorkDir) {
    try { Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

$elapsed = [math]::Round(((Get-Date) - $startTime).TotalMilliseconds,2)
Write-Log "Remediation complete (success=$($result.Success), elapsed=${elapsed}ms)"

# Exit code semantics: 0=success/non-needed, 1=error
if ($result.Success) { exit 0 } else { exit 1 }
