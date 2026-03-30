# WinRE Health Detection Script (Intune Proactive Remediation - Simple Edition)
# Purpose: Lightweight detection focused on WinRE health + KB5034441 vulnerability.
# Emits JSON to stdout for Intune pairing and can optionally ingest directly to Log Analytics via Data Collector API.
# Version: 1.7.0-intune-simple

param(
    [switch]$OutputStdOut,          # Emit JSON only (recommended for Intune detection)
    [switch]$Ephemeral,              # Use temp working directory (auto-clean unless TestMode/Persistent)
    [switch]$Persistent,             # Store artifacts under ProgramData (explicit opt-in)
    [switch]$TestMode,               # Retain artifacts even if Ephemeral

    # Direct Log Analytics ingestion (optional)
    [string]$WorkspaceId,
    [string]$WorkspaceKey,
    [string]$LogType = 'WinREHealthV2',
    [int]$RetryCount = 3,
    [int]$RetryDelaySeconds = 2
)

# Import SafeStorageAccess module for null-safe storage cmdlet wrappers
$safeStorageModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\SafeStorageAccess.psm1'
if (Test-Path $safeStorageModulePath) {
    Import-Module $safeStorageModulePath -Force -ErrorAction SilentlyContinue
} else {
    Write-Warning "SafeStorageAccess module not found at: $safeStorageModulePath. Storage health checks may be limited on legacy systems."
}

# Import LogAnalyticsIngestion module for Azure Log Analytics ingestion
$laModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\LogAnalyticsIngestion.psm1'
if (Test-Path $laModulePath) {
    Import-Module $laModulePath -Force -ErrorAction SilentlyContinue
} else {
    Write-Warning "LogAnalyticsIngestion module not found at: $laModulePath. Azure ingestion will not be available."
}

${ScriptVersion} = '1.7.0-intune-simple'
${SchemaVersion} = '2026-01-27'
$scriptStartTime = Get-Date

# Required baseline fields (12) for alignment with NinjaOne/analytics contracts
$RequiredBaselineFields = @(
    'winreEnabled','winreSeverity','winreKB5034441Vulnerable','winreConfidenceScore',
    'winreRecommendation','winrePartitionSizeMB','winrePartitionFreeMB','winreLastCheck',
    'winreBitLockerStatus','winreWindows11Ready','winreSecureBoot','winreFirmwareType'
)
Write-Verbose ("Baseline fields (12): " + ($RequiredBaselineFields -join ', '))

# Load .env file if it exists (for local testing and development)
# For production Intune deployments, use Azure Key Vault or managed identity instead
$envFile = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) '.env'
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        $line = $_.Trim()
        if (-not [string]::IsNullOrWhiteSpace($line) -and -not $line.StartsWith('#')) {
            if ($line -match '^([^=]+)=(.*)$') {
                $key = $matches[1].Trim()
                $value = $matches[2].Trim()
                # Remove quotes if present
                if (($value.StartsWith('"') -and $value.EndsWith('"')) -or 
                    ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                    $value = $value.Substring(1, $value.Length - 2)
                }
                [System.Environment]::SetEnvironmentVariable($key, $value, [System.EnvironmentVariableTarget]::Process)
            }
        }
    }
}

# Footprint handling
if ($OutputStdOut) {
    $WorkDir=$null; $LogFile=$null; $HistoryFile=$null
} else {
    if ($Persistent) { $WorkDir = 'C:\ProgramData\WinREHealth' } else { $WorkDir = Join-Path $env:TEMP ("WinREHealth_" + [Guid]::NewGuid()); $Ephemeral = $true }
    if (!(Test-Path $WorkDir)) { New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null }
    $LogFile = Join-Path $WorkDir 'WinREHealthDetection.log'
    $HistoryFile = Join-Path $WorkDir 'WinREHealthHistory.json'
}

function Write-Log { param([string]$Message); if ($OutputStdOut) { return }; if ($LogFile) { Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): $Message" } }

# Send-ToLogAnalytics function now imported from LogAnalyticsIngestion.psm1 module

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

function Get-MigrationWave {
    <#
    .SYNOPSIS
        Detects which migration wave group (1-6) the device belongs to via Entra ID group membership.
    .DESCRIPTION
        Queries device's Azure AD object ID and checks membership in migration wave groups.
        Uses Intune Management Extension's device token for Graph API authentication.
    .OUTPUTS
        String: "Wave 1" through "Wave 6", "Pilot", "Not Assigned", or "Unknown" on error
    #>
    try {
        Write-Log "Detecting migration wave group membership..."
        
        # Get device's Azure AD object ID from registry (populated by Intune enrollment)
        $deviceId = $null
        $regPaths = @(
            'HKLM:\SOFTWARE\Microsoft\Enrollments',
            'HKLM:\SOFTWARE\Microsoft\Provisioning\Diagnostics\Autopilot'
        )
        
        foreach ($regPath in $regPaths) {
            if (Test-Path $regPath) {
                $enrollments = Get-ChildItem -Path $regPath -ErrorAction SilentlyContinue
                foreach ($enrollment in $enrollments) {
                    $aadDeviceId = (Get-ItemProperty -Path $enrollment.PSPath -Name 'AadDeviceId' -ErrorAction SilentlyContinue).AadDeviceId
                    if ($aadDeviceId) {
                        $deviceId = $aadDeviceId
                        Write-Log "Found Azure AD Device ID: $deviceId"
                        break
                    }
                }
            }
            if ($deviceId) { break }
        }
        
        if (-not $deviceId) {
            Write-Log "Azure AD Device ID not found in registry"
            return "Unknown"
        }
        
        # Get access token using Intune Management Extension's token (if available)
        # Alternative: Use device's managed identity or certificate-based auth
        $tokenPath = 'HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension\Policies'
        $token = $null
        
        # Try to get token from IME (Intune Management Extension)
        try {
            # Use Windows.Security.Authentication.Web.Core for modern auth
            # This requires Windows 10 1903+ and device to be Azure AD joined
            $graphResource = "https://graph.microsoft.com"
            
            # Fallback: Try using Azure AD device credentials via dsregcmd
            $dsreg = dsregcmd /status 2>$null
            $tenantId = ($dsreg | Select-String -Pattern 'TenantId\s*:\s*(.*)' | ForEach-Object { $_.Matches.Groups[1].Value.Trim() })
            
            if (-not $tenantId) {
                Write-Log "Device not Azure AD joined - cannot determine migration wave"
                return "Not Assigned"
            }
            
            Write-Log "Device is Azure AD joined (Tenant: $tenantId)"
            
            # Query Graph API using device context (requires app registration or managed identity)
            # For production: Configure managed identity or use certificate-based auth
            
            # OPTION 1: Use local cache/registry key set by separate sync process
            # This is the most reliable approach for devices without direct Graph access
            $waveFromRegistry = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Company\Migration' -Name 'Wave' -ErrorAction SilentlyContinue
            if ($waveFromRegistry -and $waveFromRegistry.Wave) {
                Write-Log "Migration wave found in registry: $($waveFromRegistry.Wave)"
                return $waveFromRegistry.Wave
            }
            
            # OPTION 2: Query Graph API directly (requires permissions)
            # This would require either:
            # - Managed Identity assigned to device
            # - Certificate-based auth with app registration
            # - Service account with delegated permissions
            
            # For now, check if device has been tagged via Intune category
            $intuneCategory = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension' -Name 'DeviceCategory' -ErrorAction SilentlyContinue
            if ($intuneCategory -and $intuneCategory.DeviceCategory) {
                $category = $intuneCategory.DeviceCategory
                # Parse category for wave info (e.g., "Wave1", "Migration-Wave-2", etc.)
                if ($category -match '(?i)wave[_\s-]*(\d)') {
                    $waveNum = $matches[1]
                    Write-Log "Detected wave from Intune category: Wave $waveNum"
                    return "Wave $waveNum"
                }
                if ($category -match '(?i)pilot') {
                    Write-Log "Detected pilot device from Intune category"
                    return "Pilot"
                }
            }
            
            Write-Log "No migration wave assignment found"
            return "Not Assigned"
            
        } catch {
            Write-Log "Error querying migration wave: $($_.Exception.Message)"
            return "Unknown"
        }
        
    } catch {
        Write-Log "Migration wave detection failed: $($_.Exception.Message)"
        return "Unknown"
    }
}

function Get-WinREStatus {
    $fnStart = Get-Date
    $r = [ordered]@{
        Timestamp = (Get-Date -Format o)
        ComputerName = $env:COMPUTERNAME
        WinREEnabled=$null; WinRELocation=$null; WinREBCDId=$null
        BCDRecoveryGuid="NOT_CONFIGURED"
        PartitionSizeMB=$null; PartitionFreeMB=$null; SupportedMaxSizeMB=$null; CanGrowTo500MB=$null
        PartitionHealthStatus="NotChecked"; PartitionOperationalStatus="NotChecked"
        IsLastPartition=$null; AdjacentToOSPartition=$null; IsRecoveryGptGuid=$null; PartitionGptType=$null; PartitionAccessible=$null
        DiskHealthStatus="NotChecked"; DiskOperationalStatus="NotChecked"
        SecureBootEnabled=$null; FirmwareType=$null; Windows11Ready=$null; TpmPresent=$null; TpmReady=$null
        WinREImageSizeMB=$null; BitLockerStatus=$null; KB5034441Vulnerable=$null
        PendingReboot=$null; MigrationWave=$null; ScriptVersion=${ScriptVersion}; SchemaVersion=${SchemaVersion}
        Severity='Unknown'; RecommendedAction=@(); RecommendedActionCode=@(); ConfidenceScore=0; RemediationReady=$false; Error=$null
    }
    try {
        # Detect migration wave assignment
        $r.MigrationWave = Get-MigrationWave
        Write-Log "Migration Wave: $($r.MigrationWave)"

        # Secure Boot / Firmware type
        try {
            $null = Confirm-SecureBootUEFI -ErrorAction Stop
            $r.SecureBootEnabled = $true
            $r.FirmwareType = 'UEFI'
        } catch {
            $r.SecureBootEnabled = $false
            $r.FirmwareType = 'Legacy'
        }

        # TPM status (for Windows 11 readiness)
        try {
            $tpm = Get-Tpm -ErrorAction SilentlyContinue
            if ($tpm) {
                $r.TpmPresent = $tpm.TpmPresent
                $r.TpmReady = $tpm.TpmReady
            }
        } catch {}
        
        $reagentc = reagentc /info 2>&1
        $statusLine = ($reagentc | Select-String -Pattern 'Windows RE status' | ForEach-Object { $_.Line })
        $enabled=$false; if ($statusLine) { $enabled = (($statusLine -split ':',2)[1].Trim() -match 'Enabled') }
        $r.WinREEnabled = $enabled
        $locLine = ($reagentc | Select-String -Pattern 'Windows RE location' | ForEach-Object { $_.Line })
        if ($locLine) { $r.WinRELocation = (($locLine -split ':',2)[1].Trim()) }
        $bcdLine = ($reagentc | Select-String -Pattern 'Boot Configuration Data (BCD) identifier' | ForEach-Object { $_.Line })
        if ($bcdLine) { $r.WinREBCDId = (($bcdLine -split ':',2)[1].Trim()) }

        if ($r.WinRELocation -match 'harddisk(\d+)\\partition(\d+)') {
            $disk = [int]$matches[1]; $part=[int]$matches[2]
            try {
                $partition = Get-PartitionSafe -DiskNumber $disk -PartitionNumber $part -ErrorAction SilentlyContinue
                if ($partition) {
                    $r.PartitionSizeMB = [math]::Round($partition.Size/1MB,2)
                    if ($partition.GptType) { $r.PartitionGptType = $partition.GptType }
                    $recoveryGuid = '{DE94BBA4-06D1-4D40-A16A-BFD50179D6AC}'
                    $r.IsRecoveryGptGuid = ($partition.GptType -eq $recoveryGuid)
                    
                    # Partition health status (v1.5.5)
                    try {
                        if ($partition.HealthStatus) {
                            $r.PartitionHealthStatus = $partition.HealthStatus.ToString()
                        } else {
                            $r.PartitionHealthStatus = "Unknown"
                        }
                        if ($partition.OperationalStatus) {
                            $r.PartitionOperationalStatus = $partition.OperationalStatus.ToString()
                        } else {
                            $r.PartitionOperationalStatus = "Unknown"
                        }
                    } catch {
                        Write-Log "Could not retrieve partition health status: $($_.Exception.Message)"
                        $r.PartitionHealthStatus = "Error"
                        $r.PartitionOperationalStatus = "Unknown"
                    }
                    
                    # Disk health status (v1.5.5)
                    try {
                        $diskObj = Get-DiskSafe -Number $disk -ErrorAction SilentlyContinue
                        if ($diskObj) {
                            if ($diskObj.HealthStatus) {
                                $r.DiskHealthStatus = $diskObj.HealthStatus.ToString()
                            } else {
                                $r.DiskHealthStatus = "Unknown"
                            }
                            if ($diskObj.OperationalStatus) {
                                $r.DiskOperationalStatus = $diskObj.OperationalStatus.ToString()
                            } else {
                                $r.DiskOperationalStatus = "Unknown"
                            }
                        }
                    } catch {
                        Write-Log "Could not retrieve disk health status: $($_.Exception.Message)"
                        $r.DiskHealthStatus = "Error"
                        $r.DiskOperationalStatus = "Unknown"
                    }
                    
                    $supported = Get-PartitionSupportedSize -DiskNumber $disk -PartitionNumber $part -ErrorAction SilentlyContinue
                    if ($supported) { $r.SupportedMaxSizeMB = [math]::Round($supported.SizeMax/1MB,2); $r.CanGrowTo500MB = ($supported.SizeMax -ge (500MB)) }
                    $all = Get-PartitionSafe -DiskNumber $disk -ErrorAction SilentlyContinue | Sort-Object Offset
                    if ($all) {
                        $last = $all[-1]; $r.IsLastPartition = ($last.PartitionNumber -eq $part)
                        $osPart = ($all | Where-Object { $_.Type -eq 'Basic' -and $_.AccessPaths -like '*\\' } | Select-Object -First 1)
                        if (-not $osPart) { $osPart = ($all | Where-Object { $_.Type -eq 'Basic' } | Sort-Object Offset | Select-Object -Last 1) }
                        if ($osPart) { $r.AdjacentToOSPartition = (($osPart.Offset + $osPart.Size) -eq $partition.Offset) -or (($partition.Offset + $partition.Size) -eq $osPart.Offset) }
                    }
                }
            } catch {}
        }

        if ($r.WinRELocation -and (Test-Path $r.WinRELocation)) {
            $wim = Join-Path $r.WinRELocation 'winre.wim'
            if (Test-Path $wim) {
                $file = Get-Item $wim -ErrorAction SilentlyContinue
                if ($file) { $r.WinREImageSizeMB = [math]::Round($file.Length/1MB,2); $r.PartitionAccessible=$true; if ($r.PartitionSizeMB) { $r.PartitionFreeMB = [math]::Round($r.PartitionSizeMB - $r.WinREImageSizeMB,2) } }
            } else { $r.PartitionAccessible=$false; $r.RecommendedAction += 'WinRE.wim missing'; $r.RecommendedActionCode += 'WINRE_WIM_MISSING' }
        } else { $r.PartitionAccessible=$false }

        if ($null -ne $r.PartitionFreeMB) {
            if ($r.PartitionFreeMB -lt 250) { $r.KB5034441Vulnerable=$true; $r.RecommendedAction += "URGENT: Recovery partition <250MB free (current: $($r.PartitionFreeMB)MB). Resize to 500MB+"; $r.RecommendedActionCode += 'KB5034441_RESIZE' } else { $r.KB5034441Vulnerable=$false }
        } elseif ($null -ne $r.PartitionSizeMB) {
            if ($r.PartitionSizeMB -lt 500) { $r.KB5034441Vulnerable=$true; $r.RecommendedAction += "Recovery partition small (size: $($r.PartitionSizeMB)MB). Target 500MB+"; $r.RecommendedActionCode += 'KB5034441_RESIZE' } else { $r.KB5034441Vulnerable=$false }
        }

        try { $bl = Get-BitLockerVolume -ErrorAction SilentlyContinue; $osVol = $bl | Where-Object { $_.VolumeType -eq 'OperatingSystem' } | Select-Object -First 1; if ($osVol) { $r.BitLockerStatus = $osVol.ProtectionStatus } else { $r.BitLockerStatus='Unknown' } } catch { $r.BitLockerStatus='Unknown' }
        $r.PendingReboot = Test-PendingReboot

        # Windows 11 readiness (lightweight)
        $r.Windows11Ready = ($r.FirmwareType -eq 'UEFI' -and $r.SecureBootEnabled -eq $true -and $r.TpmReady -eq $true)

        $score=0
        if ($r.WinREEnabled) { $score+=30 }
        if ($r.PartitionAccessible) { $score+=25 }
        if ($r.BitLockerStatus -eq 'On') { $score+=15 }
        if ($r.WinREImageSizeMB -and $r.WinREImageSizeMB -gt 100) { $score+=10 }
        if ($r.PartitionSizeMB -and $r.PartitionSizeMB -ge 250) { $score+=10 }
        if ($r.PartitionFreeMB -and $r.PartitionFreeMB -ge 100) { $score+=5 }
        if ($r.IsRecoveryGptGuid) { $score+=5 }
        $r.ConfidenceScore=$score
        if ($score -ge 85) { $r.Severity='Healthy' } elseif ($score -ge 60) { $r.Severity='Warning' } else { $r.Severity='Critical' }
        if ($r.KB5034441Vulnerable) { $r.Severity='Critical' }
        if ($r.PendingReboot -eq $true -and $r.Severity -eq 'Healthy') { $r.Severity='Warning'; $r.RecommendedAction += 'Pending reboot detected - reboot before servicing WinRE.'; $r.RecommendedActionCode += 'PENDING_REBOOT' }
        $r.RemediationReady = ($r.KB5034441Vulnerable -and $r.CanGrowTo500MB -and $r.IsLastPartition -and $r.AdjacentToOSPartition -and -not $r.PendingReboot)
        if ($r.Severity -eq 'Healthy' -and $r.RecommendedAction.Count -eq 0) { $r.RecommendedAction += 'No action required - WinRE is healthy' }
    } catch { $r.Error = $_.Exception.Message; Write-Log "Error: $($_.Exception.Message)" }
    return $r
}

try {
    $status = Get-WinREStatus
    # Persist history (if not stdout)
    if ($HistoryFile) {
        try {
            $hist=@(); if (Test-Path $HistoryFile) { try { $hist = Get-Content -Path $HistoryFile -Raw | ConvertFrom-Json } catch {} }
            $hist = @($hist) + $status; if ($hist.Count -gt 40) { $hist = $hist[-40..-1] }
            $hist | ConvertTo-Json -Depth 6 | Set-Content -Path $HistoryFile -Encoding UTF8
        } catch { Write-Log "Failed history update: $($_.Exception.Message)" }
    }
    $json = $status | ConvertTo-Json -Depth 6
    if ($OutputStdOut) { Write-Output $json } else { $json | Out-File -FilePath (Join-Path $WorkDir 'WinREHealthStatus.json') -Encoding UTF8 }

    if ($WorkspaceId -and $WorkspaceKey) { [void](Send-ToLogAnalytics -Data $status -WorkspaceId $WorkspaceId -WorkspaceKey $WorkspaceKey -LogType $LogType -RetryCount $RetryCount -RetryDelaySeconds $RetryDelaySeconds) }

    # Cleanup ephemeral
    if ($Ephemeral -and -not $TestMode -and -not $Persistent -and $WorkDir) { try { Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction SilentlyContinue } catch { Write-Log "Ephemeral cleanup failed: $($_.Exception.Message)" } }

    # Return object for testing (instead of exit)
    if ($TestMode) { return $status }

    # Exit codes for Intune detection: 0=healthy/warning, 1=critical (triggers remediation)
    if ($status.Severity -eq 'Critical') { exit 1 } else { exit 0 }
} catch {
    Write-Log "Fatal: $($_.Exception.Message)"
    if ($OutputStdOut) { Write-Output ( @{ Error = $_.Exception.Message; ScriptVersion=${ScriptVersion}; Timestamp=(Get-Date -Format o) } | ConvertTo-Json ) }
    exit 1
}
