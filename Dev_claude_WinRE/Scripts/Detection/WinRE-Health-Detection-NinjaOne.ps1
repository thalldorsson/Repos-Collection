# WinRE Health Detection Script for NinjaOne RMM
# Author: Thorsteinn Halldorsson
# Date: 2026-01-10
# Version: 1.7.0-ninja
# Scope: Client devices only (Windows 10/11 workstations, laptops) - not for Windows Server
# Phase: 1-3 Integration (WinRE Health + Real-Time Monitoring + System Health Assessment)

# Notes:
# - Inputs come from Script Variables (Organization scope) mapped in NinjaOne: LA_WORKSPACE_ID, LA_WORKSPACE_KEY, ENABLE_AZURE_LOGGING (optional).
# - For local/manual runs, parameters are optional and fall back to $env:la_workspace_id, $env:la_workspace_key, and $env:ENABLE_AZURE_LOGGING.
# - ENABLE_AZURE_LOGGING parameter provides explicit control; if omitted, checks Ninja property, then env variable, defaults to true when credentials present.

param(
    # Execution control / footprint minimization
    [object]$Ephemeral,          # Use temp working directory (default when not TestMode)
    [object]$OutputStdOut,       # Emit JSON only to stdout; no files written
    [object]$TestMode,           # Keep artifacts for troubleshooting (overrides Ephemeral cleanup)
    [object]$Persistent,         # Store under ProgramData (explicit opt-in)

    # Direct Log Analytics ingestion (Data Collector API)
    [string]$WorkspaceId,
    [string]$WorkspaceKey,
    [object]$ENABLE_AZURE_LOGGING,  # Optional explicit toggle; if omitted, infers from Ninja property or env
    [switch]$ShowWorkspaceCredentials,
    [switch]$RevealWorkspaceKey,
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

#region Configuration
${ScriptVersion} = "1.7.0-ninja"
${SchemaVersion} = "2026-01-10"
$scriptStartTime = Get-Date

# Load .env file if it exists (for local testing and development)
# For production NinjaOne deployments, use Organization Script Variables instead
$envFile = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) '.env'
if (Test-Path $envFile) {
    Write-Verbose "Loading configuration from .env file"
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

# Guidance:
# - Map Org-level Script Variables to parameters: WorkspaceId → LA_WORKSPACE_ID (Text/String),
#   WorkspaceKey → LA_WORKSPACE_KEY (String/Text), ENABLE_AZURE_LOGGING → ENABLE_AZURE_LOGGING (Checkbox, optional).
# - Create NinjaOne Device Custom Fields before running to avoid "Unable to find the specified field" messages.
#   Required fields listed in Docs/README-NinjaOne-Setup.md (minimum + extended metrics).

# Default environment toggles (can be overridden by Ninja runtime or user)
if ($null -eq $env:winre_testmode)       { $env:winre_testmode = "true" }
if ($null -eq $env:winre_persistent)     { $env:winre_persistent = "true" }
if ($null -eq $env:winre_output_stdout)  { $env:winre_output_stdout = "false" }

    # Resolve execution toggles from parameters and optional environment overrides (inline, no external function calls)
    $toBool = {
        param($v,$def)
        if ($null -eq $v) { return $def }
        if ($v -is [bool]) { return [bool]$v }
        if ($v -is [int]) { return ([int]$v -ne 0) }
        try {
            $s = ([string]$v).Trim()
            if ($s -match '^(?i:true|1)$') { return $true }
            if ($s -match '^(?i:false|0)$') { return $false }
        } catch {}
        return $def
    }
    $resolvedTestMode    = & $toBool $TestMode $false
    $resolvedPersistent  = & $toBool $Persistent $false
    $resolvedOutputStd   = & $toBool $OutputStdOut $false
    $resolvedEphemeral   = & $toBool $Ephemeral $false

# Environment overrides allow control via $env:
    if (-not $resolvedTestMode)    { $resolvedTestMode    = & $toBool $env:winre_testmode $resolvedTestMode }
    if (-not $resolvedPersistent)  { $resolvedPersistent  = & $toBool $env:winre_persistent $resolvedPersistent }
    if (-not $resolvedOutputStd)   { $resolvedOutputStd   = & $toBool $env:winre_output_stdout $resolvedOutputStd }
    if (-not $resolvedEphemeral)   { $resolvedEphemeral   = & $toBool $env:winre_ephemeral $resolvedEphemeral }

# Establish output paths (skip if OutputStdOut)
if ($resolvedOutputStd) {
    $OutputDir   = $null
    $LogFile     = $null
    $HistoryFile = $null
} else {
    if ($resolvedPersistent) {
        $OutputDir = "C:\ProgramData\WinREHealth"
    } else {
        # CHANGED: Use explicit C:\Temp fallback instead of $env:TEMP
        # $env:TEMP may redirect to OneDrive on some machines
        $tempBase = if (Test-Path "C:\Temp") { "C:\Temp" } else { $env:TEMP }
        $OutputDir = Join-Path $tempBase ("WinREHealth_" + [Guid]::NewGuid().ToString())
        $resolvedEphemeral = $true
    }
    
    # ADDED: Ensure directory creation with fallback
    if (!(Test-Path $OutputDir)) {
        try {
            New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
        } catch {
            Write-Log "Failed to create $OutputDir, falling back to system temp"
            $OutputDir = Join-Path $env:WINDIR "Temp\WinREHealth"
            New-Item -Path $OutputDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
    
    $LogFile = Join-Path $OutputDir "WinREHealthDetection.log"
    $HistoryFile = Join-Path $OutputDir "WinREHealthHistory.json"
}
#endregion

# Helper to safely set NinjaOne device custom fields. Handles nulls and maps
# certain fields (e.g., winreSeverity) to acceptable formats for Ninja.
function Set-NinjaField {
    param(
        [Parameter(Mandatory=$true)][string]$FieldName,
        [Parameter(Mandatory=$false)][object]$Value
    )

    try {
        $cmd = Get-Command Ninja-Property-Set -ErrorAction SilentlyContinue
        if (-not $cmd) {
            Write-Log "Ninja-Property-Set not available (expected if running manually)"
            return $false
        }

        if ($null -eq $Value) {
            Write-Log "Skipping field '$FieldName' because value is null"
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
            # Ninja expects specific GUIDs for firmware type enumerations. Map human-readable values.
            switch -Wildcard ($Value) {
                'UEFI'   { $valueToSet = '3e8bb00a-753c-4e77-afc6-104537116ea7'; break }
                'Legacy' { $valueToSet = '52b8ae12-3d48-4c76-a094-86e3e9d57a2e'; break }
                default  { $valueToSet = '71d17779-001e-47e5-aeac-98b05f8d68bb'; break }
            }
        } else {
            $valueToSet = $Value
        }

        # Coerce booleans to accepted literal strings or numbers if needed
        if ($valueToSet -is [bool]) { $valueToSet = ($valueToSet -eq $true) }

        # Special handling for RecommendedActionCode: Ninja custom field may be an Integer bitmask.
        # Support arrays or comma-separated code names by mapping to a numeric bitmask.
        if ($FieldName -ieq 'winreRecommendedActionCode') {
            # Normalize incoming value into array of tokens if it's a string or enumerable
            $codes = @()
            if ($valueToSet -is [System.Collections.IEnumerable] -and -not ($valueToSet -is [string])) {
                $codes = @($valueToSet)
            } elseif ($valueToSet -is [string]) {
                $codes = ($valueToSet -split '[,;]') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
            } elseif ($valueToSet -is [int]) {
                # already numeric, leave as-is
                $valueToSet = [int]$valueToSet
                $codes = @()
            }

            # Mapping of known code names to integer bit values (extend as needed)
            $mapping = @{
                'LEGACY_BIOS' = 1
                'WINRE_DISABLED' = 2
                'SECURE_BOOT_DISABLED' = 4
                'LOW_RECOVERY_FREE_SPACE' = 8
                'WINRE_WIM_MISSING' = 16
                'KB5034441_RESIZE' = 32
                'PENDING_REBOOT' = 64
            }

            if ($codes.Count -gt 0) {
                $sum = 0
                $unmapped = @()
                foreach ($c in $codes) {
                    if ($mapping.ContainsKey($c)) { $sum += $mapping[$c] } else { $unmapped += $c }
                }
                if ($unmapped.Count -gt 0) {
                    Write-Log "Skipping '$FieldName' - unmapped codes: $($unmapped -join ', '). Ensure Ninja field type matches expected format or extend mapping."
                    return $false
                } else {
                    $valueToSet = $sum
                }
            }
        }

        Ninja-Property-Set $FieldName $valueToSet -ErrorAction Stop
        Write-Log "Set Ninja field '$FieldName' = $valueToSet"
        return $true
    } catch {
        Write-Log "Failed to set Ninja field '$FieldName': $($_.Exception.Message)"
        return $false
    }
}

#region Functions
function ConvertTo-BooleanSafe {
    param(
        $value
    )
    $defaultIfNull = $false
    if ($null -eq $value) { return $defaultIfNull }
    if ($value -is [bool]) { return [bool]$value }
    if ($value -is [int]) { return ([int]$value -ne 0) }
    try {
        $s = ([string]$value).Trim()
        if ($s -match '^(?i:true|1)$') { return $true }
        if ($s -match '^(?i:false|0)$') { return $false }
    } catch {}
    return $defaultIfNull
}
function Write-Log {
    param([string]$Message)
    if ($OutputStdOut) { return } # Silent in pure stdout mode
    if ($LogFile) {
        try {
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $dir = Split-Path -Path $LogFile -Parent
            if ($dir -and -not (Test-Path $dir)) {
                New-Item -Path $dir -ItemType Directory -Force | Out-Null
            }
            # Prefer terminating errors to allow catch/fallback handling
            Add-Content -Path $LogFile -Value "${timestamp}: $Message" -ErrorAction Stop
        } catch {
            # Avoid noisy errors in NinjaOne when TEMP/ProgramData paths are unavailable
            # Fallback: switch log location to a user-writable TEMP path and retry
            try {
                $fallbackDir = Join-Path $env:TEMP 'WinREHealth'
                if (-not (Test-Path $fallbackDir)) { New-Item -Path $fallbackDir -ItemType Directory -Force | Out-Null }
                Set-Variable -Name OutputDir -Value $fallbackDir -Scope Script
                Set-Variable -Name LogFile   -Value (Join-Path $fallbackDir 'WinREHealthDetection.log') -Scope Script
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                Add-Content -Path $script:LogFile -Value "${timestamp}: $Message" -ErrorAction SilentlyContinue
            } catch {
                # Suppress any remaining file I/O errors; last resort is to emit to stdout in non-OutputStdOut mode
                Write-Output "${timestamp}: $Message"
            }
        }
    }
}

# Collects device context attributes used for Phase 2 schema extension
function Get-DeviceContext {
    [CmdletBinding()]
    param()

    $context = @{
        DeviceLocation_s     = "Unknown"
        ManufactureDate_s    = (Get-Date).AddYears(-3).ToString('yyyy-MM-ddTHH:mm:ssZ')
        DeviceAge_d          = 999
        DepartmentName_s     = "Unknown"
        DeviceOrgUnit_s      = "Unknown"
        FirstSeenDate_s      = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssZ')
        VirtualMachineType_s = "Unknown"
        PhysicalMemoryGB_d   = 0.0
        ProcessorCores_d     = 0.0
        StorageCapacityGB_d  = 0.0
    }

    try {
        # AD OU path for location
        try {
            $searcher = [System.DirectoryServices.DirectorySearcher]::new([System.DirectoryServices.DirectoryEntry]::new("LDAP://"))
            $searcher.Filter = "(&(objectClass=computer)(cn=$env:COMPUTERNAME))"
            $result = $searcher.FindOne()
            if ($result -and $result.Properties['distinguishedname'].Count -gt 0) {
                $dn = $result.Properties['distinguishedname'][0]
                $context.DeviceLocation_s = ($dn -split ',OU=' | Select-Object -Skip 1) -join ' / '
                $context.DeviceOrgUnit_s = (($dn -split ',')[0]).Replace('CN=','')
            }
        } catch { Write-Log "Get-DeviceContext: AD lookup failed ($($_.Exception.Message))" }

        # Manufacture date and age
        $enclosure = Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue
        if ($enclosure -and $enclosure.ManufactureDate) {
            $context.ManufactureDate_s = ($enclosure.ManufactureDate | Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
            $context.DeviceAge_d = [Math]::Round(((Get-Date) - $enclosure.ManufactureDate).TotalDays, 1)
        }

        # Department (optional AD attribute)
        try {
            $adComputer = Get-ADComputer -Identity $env:COMPUTERNAME -Properties extensionAttribute1 -ErrorAction SilentlyContinue
            if ($adComputer -and $adComputer.extensionAttribute1) { $context.DepartmentName_s = $adComputer.extensionAttribute1 }
        } catch { }

        # Hardware specs
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($cs) {
            $context.PhysicalMemoryGB_d = [Math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
        }
        $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue
        if ($cpu) {
            $context.ProcessorCores_d = ($cpu | Measure-Object -Property NumberOfCores -Sum).Sum
        }
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "Name='C:'" -ErrorAction SilentlyContinue
        if ($disk) {
            $context.StorageCapacityGB_d = [Math]::Round($disk.Size / 1GB, 2)
        }

        # VM detection
        $vm = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue
        if ($vm -and $vm.Vendor) { $context.VirtualMachineType_s = $vm.Vendor }

    } catch {
        Write-Log "Get-DeviceContext failed: $($_.Exception.Message)"
    }

    return $context
}

# Reference lists (to assist operators; not enforced):
$RequiredNinjaFields = @(
    'winreEnabled','winreSeverity','winreKB5034441Vulnerable','winreConfidenceScore',
    'winreRecommendation','winrePartitionSizeMB','winrePartitionFreeMB','winreLastCheck',
    'winreBitLockerStatus','winreWindows11Ready','winreSecureBoot','winreFirmwareType',
    'winreTpmPresent','winreTpmReady','winrePendingReboot','winreIsRecoveryGptGuid',
    'winrePartitionGptType','winrePartitionHealthStatus','winrePartitionOperationalStatus',
    'winreDiskHealthStatus','winreDiskOperationalStatus','winreBCDRecoveryGuid',
    'winreIsLastPartition','winreAdjacentToOSPartition',
    'winreSupportedMaxSizeMB','winreCanGrowTo500MB','winreBCDId','winreRemediationReady',
    'winreRecommendedActionCode','winreScriptVersion','winreSchemaVersion',
    'winrePartitionFreeTrendMBPerDay','winreDaysUntilSpaceCritical','winreTrendDirection',
    'winreTrendAnalysisPeriodDays','winreDeviceCriticality','winreCriticalityPriority',
    'winreCriticalityReason',
    'winreDeviceLocation','winreManufactureDate','winreDeviceAge','winreDepartmentName',
    'winreDeviceOrgUnit','winreFirstSeenDate','winreVirtualMachineType',
    'winrePhysicalMemoryGB','winreStorageCapacityGB','winreProcessorCores'
)

# Send-ToLogAnalytics function now imported from LogAnalyticsIngestion.psm1 module

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
        BCDRecoveryGuid = "NOT_CONFIGURED"
        PartitionSizeMB = $null
        PartitionFreeMB = $null
        PartitionFreeMBEstimated = $null
        PartitionType = $null
        PartitionGptType = $null
        PartitionHealthStatus = "NotChecked"
        PartitionOperationalStatus = "NotChecked"
        IsRecoveryGptGuid = $null
        IsLastPartition = $null
        AdjacentToOSPartition = $null
        SupportedMaxSizeMB = $null
        CanGrowTo500MB = $null
        DiskType = $null
        DiskHealthStatus = "NotChecked"
        DiskOperationalStatus = "NotChecked"
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

        # Device context (Phase 2)
        DeviceLocation_s = $null
        ManufactureDate_s = $null
        DeviceAge_d = $null
        DepartmentName_s = $null
        DeviceOrgUnit_s = $null
        FirstSeenDate_s = $null
        VirtualMachineType_s = $null
        PhysicalMemoryGB_d = $null
        ProcessorCores_d = $null
        StorageCapacityGB_d = $null
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
        
        # Get NinjaOne device ID if available
        try {
            $result.NinjaDeviceId = $env:COMPUTERNAME
        } catch {
            Write-Log "Could not retrieve NinjaOne device ID (expected if running manually)"
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
        
        # Set default for BCDRecoveryGuid (will be overridden if BCD validation succeeds)
        if ($enabled) {
            $result.BCDRecoveryGuid = "00000000-0000-0000-0000-000000000000"
        }
        
        # Validate BCD configuration
        if ($enabled -and $result.WinREBCDId) {
            try {
                $bcdOutput = bcdedit /enum '{bootmgr}' 2>&1 | Out-String
                $recoverySequenceLine = ($bcdOutput -split "`n" | Select-String -Pattern "recoverysequence" | ForEach-Object { $_.Line })
                
                if ($recoverySequenceLine) {
                    $bcdGuid = ($recoverySequenceLine -split '\s+')[1]
                    $result.BCDRecoveryGuid = $bcdGuid
                    
                    # Check for invalid GUID (all zeros)
                    if ($bcdGuid -match '^[{]?0+[-]0+[-]0+[-]0+[-]0+[}]?$') {
                        $result.RecommendedAction += "BCD recovery GUID is invalid (all zeros)"
                        $result.Diagnostics += 'InvalidBCDGuid'
                    }
                    
                    # Compare with WinREBCDId from reagentc (normalize GUIDs for comparison)
                    $normalizedBcdGuid = $bcdGuid.Trim('{}').ToLower()
                    $normalizedWinREGuid = $result.WinREBCDId.Trim('{}').ToLower()
                    if ($normalizedBcdGuid -ne $normalizedWinREGuid) {
                        $result.RecommendedAction += "BCD GUID mismatch between bootmgr and WinRE"
                        $result.Diagnostics += 'BCDGuidMismatch'
                    }
                } else {
                    # No recoverysequence in bootmgr - not necessarily an error on UEFI systems
                    $result.BCDRecoveryGuid = "00000000-0000-0000-0000-000000000000"
                    $result.Diagnostics += 'NoRecoverySequence'
                    Write-Log "No recoverysequence found in bootmgr BCD (common on UEFI systems)"
                }
            } catch {
                Write-Log "Could not validate BCD configuration: $($_.Exception.Message)"
                $result.BCDRecoveryGuid = "00000000-0000-0000-0000-000000000000"
            }
        }

        # Extract partition details
        if ($location -match "harddisk(\d+)\\partition(\d+)") {
            $diskNumber = [int]$matches[1]
            $partitionNumber = [int]$matches[2]
            
            # Set defaults for health properties (will be overridden if partition object retrieved successfully)
            $result.PartitionHealthStatus = "Unknown"
            $result.PartitionOperationalStatus = "Unknown"
            
            try {
                $partition = Get-PartitionSafe -DiskNumber $diskNumber -PartitionNumber $partitionNumber -ErrorAction SilentlyContinue
                if ($partition) {
                    $result.PartitionSizeMB = [math]::Round($partition.Size / 1MB, 2)
                    $result.PartitionType = $partition.Type
                    if ($partition.GptType) { $result.PartitionGptType = $partition.GptType }
                    $recoveryGuid = '{DE94BBA4-06D1-4D40-A16A-BFD50179D6AC}'
                    $result.IsRecoveryGptGuid = ($partition.GptType -eq $recoveryGuid)
                    
                    # Partition health status
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
                        
                        # Only flag truly unhealthy states (not NotChecked/Unknown)
                        if ($partition.HealthStatus -and 
                            $partition.HealthStatus -ne 'Healthy' -and 
                            $partition.HealthStatus -ne 'NotChecked' -and
                            $partition.HealthStatus -ne 'Unknown') {
                            $result.RecommendedAction += "Partition health: $($partition.HealthStatus)"
                            $result.Diagnostics += 'UnhealthyPartition'
                        }
                    } catch {
                        Write-Log "Could not retrieve partition health status: $($_.Exception.Message)"
                        $result.PartitionHealthStatus = "Error"
                        $result.PartitionOperationalStatus = "Unknown"
                    }
                    
                    # Growability info
                    try {
                        $supported = Get-PartitionSupportedSize -DiskNumber $diskNumber -PartitionNumber $partitionNumber -ErrorAction SilentlyContinue
                        if ($supported) {
                            $result.SupportedMaxSizeMB = [math]::Round($supported.SizeMax/1MB,2)
                            $result.CanGrowTo500MB = ($supported.SizeMax -ge (500MB))
                        }
                    } catch {}
                    
                    # Adjacency and last partition
                    $allParts = Get-PartitionSafe -DiskNumber $diskNumber -ErrorAction SilentlyContinue | Sort-Object -Property Offset
                    if ($allParts) {
                        $lastPart = $allParts[-1]
                        $result.IsLastPartition = ($lastPart.PartitionNumber -eq $partitionNumber)
                        $osPart = ($allParts | Where-Object { $_.Type -eq 'Basic' -and $_.AccessPaths -like '*\\' } | Select-Object -First 1)
                        if (-not $osPart) { $osPart = ($allParts | Where-Object { $_.Type -eq 'Basic' } | Sort-Object Offset | Select-Object -Last 1) }
                        if ($osPart) { $result.AdjacentToOSPartition = (($osPart.Offset + $osPart.Size) -eq $partition.Offset) -or (($partition.Offset + $partition.Size) -eq $osPart.Offset) }
                    }
                    
                    # Get disk type and health
                    $disk = Get-DiskSafe -Number $diskNumber -ErrorAction SilentlyContinue
                    if ($disk) {
                        $result.DiskType = "$($disk.PartitionStyle) / $($disk.BusType)"
                        
                        try {
                            if ($disk.HealthStatus) {
                                $result.DiskHealthStatus = $disk.HealthStatus.ToString()
                            } else {
                                $result.DiskHealthStatus = "Unknown"
                            }
                            
                            if ($disk.OperationalStatus) {
                                $result.DiskOperationalStatus = $disk.OperationalStatus.ToString()
                            } else {
                                $result.DiskOperationalStatus = "Unknown"
                            }
                            
                            # Only flag truly unhealthy states (not NotChecked/Unknown)
                            if ($disk.HealthStatus -and 
                                $disk.HealthStatus -ne 'Healthy' -and
                                $disk.HealthStatus -ne 'NotChecked' -and
                                $disk.HealthStatus -ne 'Unknown') {
                                $result.RecommendedAction += "Disk health: $($disk.HealthStatus)"
                                $result.Diagnostics += 'UnhealthyDisk'
                            }
                        } catch {
                            Write-Log "Could not retrieve disk health status: $($_.Exception.Message)"
                            $result.DiskHealthStatus = "Error"
                            $result.DiskOperationalStatus = "Unknown"
                        }
                    }
                }
            } catch {
                Write-Log "Partition analysis failed: $($_.Exception.Message)"
            }
        }

        # Count recovery partitions
        $allRecoveryPartitions = Get-PartitionSafe -AllPartitions | Where-Object { $_.Type -eq "Recovery" }
        $result.RecoveryPartitionCount = ($allRecoveryPartitions | Measure-Object).Count

        # Trust reagentc /info as source of truth (per Microsoft docs)
        # If WinRE is enabled with valid location, the partition IS functionally accessible
        if ($enabled -and $location) {
            $result.PartitionAccessible = $true  # Functionally accessible to Windows
            
            # Try to get WinRE.wim metrics via Test-Path (works on some systems)
            # But don't mark as inaccessible if it fails - \\?\GLOBALROOT paths may not work with Test-Path
            $wimPath = Join-Path $location "winre.wim"
            $wimFile = $null
            try {
                if (Test-Path $wimPath -ErrorAction SilentlyContinue) {
                    $wimFile = Get-Item $wimPath -ErrorAction SilentlyContinue
                }
            } catch {
                # Test-Path fails on \\?\GLOBALROOT paths - this is expected
                Write-Log "Test-Path failed on kernel device path (expected): $wimPath"
            }
            
            if ($wimFile) {
                # Successfully accessed WinRE.wim
                $result.WinREImageSizeMB = [math]::Round($wimFile.Length / 1MB, 2)
                
                if ($result.PartitionSizeMB) {
                    $result.PartitionFreeMB = [math]::Round($result.PartitionSizeMB - $result.WinREImageSizeMB, 2)
                    if ($result.PartitionFreeMB -lt 100) {
                        $result.RecommendedAction += "Low free space: $($result.PartitionFreeMB)MB"
                        $result.RecommendedActionCode += 'LOW_RECOVERY_FREE_SPACE'
                    }
                }
            } else {
                # Can't access WinRE.wim via Test-Path, but WinRE is enabled
                # This is common with \\?\GLOBALROOT paths - not an error condition
                Write-Log "WinRE.wim not accessible via Test-Path (kernel device path), but WinRE is enabled and functional"
                
                # Estimate free space when WinRE.wim size is unknown
                if ($result.PartitionSizeMB -and -not $result.WinREImageSizeMB) {
                    # WinRE.wim typically 450-550MB for Windows 11, 350-450MB for Windows 10
                    $estimatedWimSize = 500  # MB (conservative estimate)
                    $result.PartitionFreeMBEstimated = [math]::Round($result.PartitionSizeMB - $estimatedWimSize, 2)
                    $result.Diagnostics += 'EstimatedFreeSpace'
                    
                    Write-Log "Estimated free space (WinRE.wim size unknown): $($result.PartitionFreeMBEstimated)MB"
                    
                    # Use estimated free space for low space detection if actual not available
                    if ($null -eq $result.PartitionFreeMB -and $result.PartitionFreeMBEstimated -lt 100) {
                        $result.RecommendedAction += "Estimated low free space: ~$($result.PartitionFreeMBEstimated)MB"
                        $result.RecommendedActionCode += 'LOW_RECOVERY_FREE_SPACE'
                    }
                }
            }
        } else {
            # WinRE is disabled or location is empty - this IS a problem
            $result.PartitionAccessible = $false
            if (-not $enabled) {
                $result.RecommendedAction += "WinRE is disabled"
                $result.RecommendedActionCode += 'WINRE_DISABLED'
            } else {
                $result.RecommendedAction += "WinRE location not configured"
            }
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
    Write-Log "=== WinRE Health Detection Started (v${ScriptVersion}) ==="

    # Optionally display workspace credentials for troubleshooting when explicitly requested.
    # Resolve effective workspace credentials from parameters or environment early so they are visible at start.
    $startupWorkspaceId = $WorkspaceId
    $startupWorkspaceKey = $WorkspaceKey
    if ([string]::IsNullOrWhiteSpace($startupWorkspaceId)) { $startupWorkspaceId = $env:la_workspace_id }
    if ([string]::IsNullOrWhiteSpace($startupWorkspaceKey)) { $startupWorkspaceKey = $env:la_workspace_key }

    function Mask-Secret {
        param([string]$s)
        if ([string]::IsNullOrWhiteSpace($s)) { return "(missing)" }
        if ($s.Length -le 8) { return ('*' * ($s.Length - 4)) + $s.Substring([Math]::Max(0,$s.Length-4)) }
        return $s.Substring(0,4) + ('*' * ($s.Length - 8)) + $s.Substring($s.Length-4)
    }

    if ($ShowWorkspaceCredentials) {
        try {
            Write-Host "WorkspaceId: $startupWorkspaceId" -ForegroundColor Cyan
            if ($RevealWorkspaceKey) {
                Write-Host "WorkspaceKey: $startupWorkspaceKey" -ForegroundColor Yellow
            } else {
                Write-Host $("WorkspaceKey: {0} (masked, use -RevealWorkspaceKey to show)" -f (Mask-Secret -s $startupWorkspaceKey)) -ForegroundColor Yellow
            }
        } catch {
            Write-Log "Failed to display workspace credentials: $($_.Exception.Message)"
        }
    }
    
    # Import optional enhancement modules (trend analysis + device criticality)
    try {
        Import-Module "$PSScriptRoot\..\TrendAnalysis.psm1" -ErrorAction SilentlyContinue
    } catch { Write-Log "TrendAnalysis module import failed: $($_.Exception.Message)" }
    try {
        Import-Module "$PSScriptRoot\..\DeviceCriticality.psm1" -ErrorAction SilentlyContinue
    } catch { Write-Log "DeviceCriticality module import failed: $($_.Exception.Message)" }
    
    # Import Phase 3 modules (hardware health, OS compliance, network readiness)
    try {
        Import-Module "$PSScriptRoot\..\Modules\HardwareHealth.psm1" -ErrorAction SilentlyContinue
    } catch { Write-Log "HardwareHealth module import failed: $($_.Exception.Message)" }
    try {
        Import-Module "$PSScriptRoot\..\Modules\OSCompliance.psm1" -ErrorAction SilentlyContinue
    } catch { Write-Log "OSCompliance module import failed: $($_.Exception.Message)" }
    try {
        Import-Module "$PSScriptRoot\..\Modules\NetworkReadiness.psm1" -ErrorAction SilentlyContinue
    } catch { Write-Log "NetworkReadiness module import failed: $($_.Exception.Message)" }
    
    # Get WinRE status
    $status = Get-WinREStatus

    # Enrich with device context (Phase 2 schema fields)
    try {
        $deviceContext = Get-DeviceContext
        if ($deviceContext) {
            foreach ($k in $deviceContext.Keys) {
                $status | Add-Member -NotePropertyName $k -NotePropertyValue $deviceContext[$k] -Force
            }
        }
    } catch { Write-Log "Failed to enrich device context: $($_.Exception.Message)" }

    # Enrich with Phase 3 system health assessment (hardware, OS, network)
    try {
        if (Get-Command Get-HardwareHealth -ErrorAction SilentlyContinue) {
            $hwHealth = Get-HardwareHealth
            if ($hwHealth) {
                foreach ($k in $hwHealth.Keys) {
                    $status | Add-Member -NotePropertyName $k -NotePropertyValue $hwHealth[$k] -Force
                }
                Write-Log "Hardware health assessment completed: $($hwHealth.HardwareHealthSeverity_s)"
            }
        }
    } catch { Write-Log "Failed to assess hardware health: $($_.Exception.Message)" }

    try {
        if (Get-Command Get-OSCompliance -ErrorAction SilentlyContinue) {
            $osCompliance = Get-OSCompliance
            if ($osCompliance) {
                foreach ($k in $osCompliance.Keys) {
                    $status | Add-Member -NotePropertyName $k -NotePropertyValue $osCompliance[$k] -Force
                }
                Write-Log "OS compliance validation completed: $($osCompliance.OSComplianceSeverity_s)"
            }
        }
    } catch { Write-Log "Failed to validate OS compliance: $($_.Exception.Message)" }

    try {
        if (Get-Command Test-NetworkReadiness -ErrorAction SilentlyContinue) {
            $netReadiness = Test-NetworkReadiness
            if ($netReadiness) {
                foreach ($k in $netReadiness.Keys) {
                    $status | Add-Member -NotePropertyName $k -NotePropertyValue $netReadiness[$k] -Force
                }
                Write-Log "Network readiness testing completed: $($netReadiness.NetworkReadinessSeverity_s)"
            }
        }
    } catch { Write-Log "Failed to test network readiness: $($_.Exception.Message)" }

    # Calculate migration readiness score (0-100) based on all health dimensions
    try {
        $readinessScore = 100
        $readinessIssues = @()
        
        # WinRE health (30 points)
        if ($status.Severity -eq "Critical") { $readinessScore -= 30; $readinessIssues += "WinRE Critical" }
        elseif ($status.Severity -eq "Warning") { $readinessScore -= 15; $readinessIssues += "WinRE Warning" }
        
        # Hardware health (25 points)
        if ($status.HardwareHealthSeverity_s -eq "Critical") { $readinessScore -= 25; $readinessIssues += "Hardware Critical" }
        elseif ($status.HardwareHealthSeverity_s -eq "Warning") { $readinessScore -= 12; $readinessIssues += "Hardware Warning" }
        
        # OS compliance (25 points)
        if ($status.OSComplianceSeverity_s -eq "Critical") { $readinessScore -= 25; $readinessIssues += "OS Critical" }
        elseif ($status.OSComplianceSeverity_s -eq "Warning") { $readinessScore -= 12; $readinessIssues += "OS Warning" }
        
        # Network readiness (20 points)
        if ($status.NetworkReadinessSeverity_s -eq "Critical") { $readinessScore -= 20; $readinessIssues += "Network Critical" }
        elseif ($status.NetworkReadinessSeverity_s -eq "Warning") { $readinessScore -= 10; $readinessIssues += "Network Warning" }
        
        # Determine Go/No-Go decision
        $goNoGo = if ($readinessScore -ge 80) { "Go" } elseif ($readinessScore -ge 60) { "Caution" } else { "No-Go" }
        
        $status | Add-Member -NotePropertyName 'MigrationReadinessScore_d' -NotePropertyValue $readinessScore -Force
        $status | Add-Member -NotePropertyName 'MigrationReadinessStatus_s' -NotePropertyValue $goNoGo -Force
        $status | Add-Member -NotePropertyName 'MigrationReadinessIssues_s' -NotePropertyValue ($readinessIssues -join '; ') -Force
        
        Write-Log "Migration readiness score: $readinessScore ($goNoGo) - Issues: $($readinessIssues -join ', ')"
    } catch { Write-Log "Failed to calculate migration readiness score: $($_.Exception.Message)" }

    # Load existing history BEFORE computing trend (so current point not yet included)
    $existingHistory = @()
    if ($HistoryFile -and (Test-Path $HistoryFile)) {
        try { $existingHistory = Get-Content -Path $HistoryFile -Raw | ConvertFrom-Json } catch { Write-Log "Failed to read existing history: $($_.Exception.Message)" }
    }

    # Perform trend analysis (adds PartitionFreeTrendMBPerDay, DaysUntilSpaceCritical, TrendDirection, TrendAnalysisPeriodDays)
    if (Get-Command Add-TrendAnalysisToResult -ErrorAction SilentlyContinue) {
        try { $status = Add-TrendAnalysisToResult -Result $status -HistoryFile $HistoryFile } catch { Write-Log "Trend analysis failed: $($_.Exception.Message)" }
    }

    # Perform device criticality classification (adds DeviceCriticality, CriticalityPriority, CriticalityReason)
    if (Get-Command Add-CriticalityToResult -ErrorAction SilentlyContinue) {
        try { $status = Add-CriticalityToResult -Result $status } catch { Write-Log "Device criticality classification failed: $($_.Exception.Message)" }
    }

    # Append current status to rolling history (limit to last 50 entries)
    if ($HistoryFile) {
        try {
            $newHistory = @($existingHistory) + $status
            if ($newHistory.Count -gt 50) { $newHistory = $newHistory[-50..-1] }
            $newHistory | ConvertTo-Json -Depth 6 | Set-Content -Path $HistoryFile -Encoding UTF8 -ErrorAction Stop
        } catch {
            $hf = $HistoryFile
            $em = $_.Exception.Message
            Write-Log ("Failed to update history file at " + $hf + " - " + $em)
            # Fallback history path under TEMP
            try {
                $fallbackDir = Join-Path $env:TEMP 'WinREHealth'
                if (-not (Test-Path $fallbackDir)) { New-Item -Path $fallbackDir -ItemType Directory -Force | Out-Null }
                $hf2 = Join-Path $fallbackDir 'WinREHealthHistory.json'
                Set-Variable -Name HistoryFile -Value $hf2 -Scope Script
                $newHistory | ConvertTo-Json -Depth 6 | Set-Content -Path $hf2 -Encoding UTF8 -ErrorAction SilentlyContinue
            } catch { }
        }
    }

    # Convert to JSON (for stdout mode or optional output)
    $json = $status | ConvertTo-Json -Depth 6
    
    # If OutputStdOut mode, emit JSON and exit early (no disk footprint)
    if ($resolvedOutputStd) { Write-Output $json; exit 0 }
    
    # Set NinjaOne custom fields (only in normal mode) including trend metrics if present
    try {
        # Operator hint: ensure these Device Custom Fields exist in NinjaOne before running routinely
        Write-Log ("Required NinjaOne fields: " + ($RequiredNinjaFields -join ', '))
        Write-Log ("Optional NinjaOne fields: " + ($OptionalNinjaFields -join ', '))

        # Only attempt Ninja field updates when running under a Ninja agent device context
        # Prefer the Ninja-provided device ID when available; fall back to local computer name
        $ninjaDeviceId = if ($null -ne $env:NINJA_DEVICE_ID -and -not [string]::IsNullOrWhiteSpace($env:NINJA_DEVICE_ID)) { $env:NINJA_DEVICE_ID } else { $env:COMPUTERNAME }
        $hasSetCmd = Get-Command Ninja-Property-Set -ErrorAction SilentlyContinue
        if (-not $ninjaDeviceId -or -not $hasSetCmd) {
            # Avoid emitting warnings to stdout when running manually; log instead so manual runs stay clean
            Write-Log "Skipping Ninja custom field updates (no device context or Ninja-Property-Set unavailable). Ensure you run this from the Ninja agent or via a policy."
        } else {
            [void](Set-NinjaField -FieldName 'winreEnabled' -Value $status.WinREEnabled)
            [void](Set-NinjaField -FieldName 'winreSeverity' -Value $status.Severity)
            [void](Set-NinjaField -FieldName 'winreKB5034441Vulnerable' -Value $status.KB5034441Vulnerable)
            [void](Set-NinjaField -FieldName 'winreConfidenceScore' -Value $status.ConfidenceScore)
            [void](Set-NinjaField -FieldName 'winreRecommendation' -Value ($status.RecommendedAction -join "; "))
            [void](Set-NinjaField -FieldName 'winrePartitionSizeMB' -Value $status.PartitionSizeMB)
            [void](Set-NinjaField -FieldName 'winrePartitionFreeMB' -Value $status.PartitionFreeMB)
            [void](Set-NinjaField -FieldName 'winreLastCheck' -Value ((Get-Date).ToString('s')))
            [void](Set-NinjaField -FieldName 'winreBitLockerStatus' -Value $status.BitLockerStatus)
            [void](Set-NinjaField -FieldName 'winreWindows11Ready' -Value $status.Windows11Ready)
            [void](Set-NinjaField -FieldName 'winreSecureBoot' -Value $status.SecureBootEnabled)
            [void](Set-NinjaField -FieldName 'winreFirmwareType' -Value $status.BIOSMode)
            [void](Set-NinjaField -FieldName 'winreTpmPresent' -Value $status.TpmPresent)
            [void](Set-NinjaField -FieldName 'winreTpmReady' -Value $status.TpmReady)
            [void](Set-NinjaField -FieldName 'winrePendingReboot' -Value $status.PendingReboot)
            [void](Set-NinjaField -FieldName 'winreIsRecoveryGptGuid' -Value $status.IsRecoveryGptGuid)
            [void](Set-NinjaField -FieldName 'winrePartitionGptType' -Value $status.PartitionGptType)
            [void](Set-NinjaField -FieldName 'winrePartitionHealthStatus' -Value $status.PartitionHealthStatus)
            [void](Set-NinjaField -FieldName 'winrePartitionOperationalStatus' -Value $status.PartitionOperationalStatus)
            [void](Set-NinjaField -FieldName 'winreDiskHealthStatus' -Value $status.DiskHealthStatus)
            [void](Set-NinjaField -FieldName 'winreDiskOperationalStatus' -Value $status.DiskOperationalStatus)
            [void](Set-NinjaField -FieldName 'winreBCDRecoveryGuid' -Value $status.BCDRecoveryGuid)
            [void](Set-NinjaField -FieldName 'winreIsLastPartition' -Value $status.IsLastPartition)
            [void](Set-NinjaField -FieldName 'winreAdjacentToOSPartition' -Value $status.AdjacentToOSPartition)
            [void](Set-NinjaField -FieldName 'winreSupportedMaxSizeMB' -Value $status.SupportedMaxSizeMB)
            [void](Set-NinjaField -FieldName 'winreCanGrowTo500MB' -Value $status.CanGrowTo500MB)
            [void](Set-NinjaField -FieldName 'winreBCDId' -Value $status.WinREBCDId)
            [void](Set-NinjaField -FieldName 'winreRemediationReady' -Value $status.RemediationReady)

            # Phase 2 device context fields
            [void](Set-NinjaField -FieldName 'winreDeviceLocation' -Value $status.DeviceLocation_s)
            [void](Set-NinjaField -FieldName 'winreManufactureDate' -Value $status.ManufactureDate_s)
            [void](Set-NinjaField -FieldName 'winreDeviceAge' -Value $status.DeviceAge_d)
            [void](Set-NinjaField -FieldName 'winreDepartmentName' -Value $status.DepartmentName_s)
            [void](Set-NinjaField -FieldName 'winreDeviceOrgUnit' -Value $status.DeviceOrgUnit_s)
            [void](Set-NinjaField -FieldName 'winreFirstSeenDate' -Value $status.FirstSeenDate_s)
            [void](Set-NinjaField -FieldName 'winreVirtualMachineType' -Value $status.VirtualMachineType_s)
            [void](Set-NinjaField -FieldName 'winrePhysicalMemoryGB' -Value $status.PhysicalMemoryGB_d)
            [void](Set-NinjaField -FieldName 'winreStorageCapacityGB' -Value $status.StorageCapacityGB_d)
            [void](Set-NinjaField -FieldName 'winreProcessorCores' -Value $status.ProcessorCores_d)
            
            # Calculate bitmask for RecommendedActionCode (NinjaOne expects Integer, not String)
            $actionCodeBitmask = 0
            if ($status.RecommendedActionCode -and $status.RecommendedActionCode.Count -gt 0) {
                $codeMapping = @{
                    'LEGACY_BIOS' = 1
                    'WINRE_DISABLED' = 2
                    'SECURE_BOOT_DISABLED' = 4
                    'LOW_RECOVERY_FREE_SPACE' = 8
                    'WINRE_WIM_MISSING' = 16
                    'KB5034441_RESIZE' = 32
                    'PENDING_REBOOT' = 64
                }
                foreach ($code in $status.RecommendedActionCode) {
                    if ($codeMapping.ContainsKey($code)) {
                        $actionCodeBitmask += $codeMapping[$code]
                    }
                }
            }
            [void](Set-NinjaField -FieldName 'winreRecommendedActionCode' -Value $actionCodeBitmask)
            
            [void](Set-NinjaField -FieldName 'winreScriptVersion' -Value $status.ScriptVersion)
            [void](Set-NinjaField -FieldName 'winreSchemaVersion' -Value $status.SchemaVersion)
            if ($null -ne $status.PartitionFreeTrendMBPerDay) { [void](Set-NinjaField -FieldName 'winrePartitionFreeTrendMBPerDay' -Value $status.PartitionFreeTrendMBPerDay) }
            if ($null -ne $status.DaysUntilSpaceCritical) { [void](Set-NinjaField -FieldName 'winreDaysUntilSpaceCritical' -Value $status.DaysUntilSpaceCritical) }
            if ($status.TrendDirection) { [void](Set-NinjaField -FieldName 'winreTrendDirection' -Value $status.TrendDirection) }
            if ($null -ne $status.TrendAnalysisPeriodDays) { [void](Set-NinjaField -FieldName 'winreTrendAnalysisPeriodDays' -Value $status.TrendAnalysisPeriodDays) }
            if ($status.DeviceCriticality) { [void](Set-NinjaField -FieldName 'winreDeviceCriticality' -Value $status.DeviceCriticality) }
            if ($null -ne $status.CriticalityPriority) { [void](Set-NinjaField -FieldName 'winreCriticalityPriority' -Value $status.CriticalityPriority) }
            if ($status.CriticalityReason) { [void](Set-NinjaField -FieldName 'winreCriticalityReason' -Value $status.CriticalityReason) }
        }
        Write-Log "Successfully updated NinjaOne custom fields (including trend + criticality metrics)"
    } catch { Write-Log "Failed to set NinjaOne custom fields: $($_.Exception.Message)" }
    
    # Direct Log Analytics ingestion (prefer explicit parameters; fallback to environment variables if provided)
    $effectiveWorkspaceId = $WorkspaceId
    $effectiveWorkspaceKey = $WorkspaceKey
    if ([string]::IsNullOrWhiteSpace($effectiveWorkspaceId)) { $effectiveWorkspaceId = $env:la_workspace_id }
    if ([string]::IsNullOrWhiteSpace($effectiveWorkspaceKey)) { $effectiveWorkspaceKey = $env:la_workspace_key }
    # Map Org-level Script Variables to parameters in the NinjaOne UI (WorkspaceId/WorkspaceKey/ENABLE_AZURE_LOGGING). Env vars can be used for testing/local runs.

    # Resolve ENABLE_AZURE_LOGGING: parameter → env variable → default to true if credentials present
    # NOTE: ENABLE_AZURE_LOGGING is a Script Variable (input), not a Device Custom Field (output)
    $effectiveEnableLogging = $null
    if ($null -ne $ENABLE_AZURE_LOGGING) {
        # Parameter was explicitly provided
        $effectiveEnableLogging = & $toBool $ENABLE_AZURE_LOGGING $true
        Write-Log "ENABLE_AZURE_LOGGING parameter provided: $effectiveEnableLogging"
    } else {
        # Try environment variable (fallback for local/manual runs)
        if ($null -ne $env:ENABLE_AZURE_LOGGING) {
            $effectiveEnableLogging = & $toBool $env:ENABLE_AZURE_LOGGING $true
            Write-Log "ENABLE_AZURE_LOGGING from environment: $effectiveEnableLogging"
        }
        
        # Default to true if credentials are present
        if ($null -eq $effectiveEnableLogging) {
            $effectiveEnableLogging = $true
            Write-Log "ENABLE_AZURE_LOGGING defaulted to: $effectiveEnableLogging (credentials present)"
        }
    }

    # Ingestion proceeds when credentials are present AND ENABLE_AZURE_LOGGING is true
    if ($effectiveWorkspaceId -and $effectiveWorkspaceKey -and $effectiveEnableLogging) {
        # Validate WorkspaceId format and DNS resolution before attempting ingest
        $wsOk = $true
        if ($effectiveWorkspaceId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
            Write-Log "Invalid WorkspaceId format: '$effectiveWorkspaceId' (expect GUID). Skipping ingest."
            $wsOk = $false
        }
        
        # Validate WorkspaceKey is Base64
        if ($wsOk) {
            try {
                $keyBytes = [Convert]::FromBase64String($effectiveWorkspaceKey)
                if ($keyBytes.Length -lt 32) {
                    Write-Log "WorkspaceKey seems too short ($($keyBytes.Length) bytes). Verify key from Azure Portal."
                }
            } catch {
                Write-Log "WorkspaceKey is not valid Base64. Verify key from Azure Portal > Log Analytics > Agents. Skipping ingest."
                $wsOk = $false
            }
        }
        
        # Verify DNS resolution for workspace endpoint
        if ($wsOk) {
            try {
                $hostToCheck = "$effectiveWorkspaceId.ods.opinsights.azure.com"
                [void][System.Net.Dns]::GetHostAddresses($hostToCheck)
            } catch {
                Write-Log "DNS resolution failed for $hostToCheck. Skipping ingest: $($_.Exception.Message)"
                $wsOk = $false
            }
        }
        
        if ($wsOk) {
            # Convert RecommendedActionCode array to numeric bitmask for Log Analytics
            # (LA will create a _d numeric column for querying/alerting)
            $actionCodeBitmask = 0
            if ($status.RecommendedActionCode -and $status.RecommendedActionCode.Count -gt 0) {
                $codeMapping = @{
                    'LEGACY_BIOS' = 1
                    'WINRE_DISABLED' = 2
                    'SECURE_BOOT_DISABLED' = 4
                    'LOW_RECOVERY_FREE_SPACE' = 8
                    'WINRE_WIM_MISSING' = 16
                    'KB5034441_RESIZE' = 32
                    'PENDING_REBOOT' = 64
                }
                foreach ($code in $status.RecommendedActionCode) {
                    if ($codeMapping.ContainsKey($code)) {
                        $actionCodeBitmask += $codeMapping[$code]
                    }
                }
            }
            # Add numeric field for Log Analytics; preserve original array for reference
            $status | Add-Member -NotePropertyName 'RecommendedActionCodeBitmask' -NotePropertyValue $actionCodeBitmask -Force
            
            Write-Log "Attempting Log Analytics ingest (workspace=$effectiveWorkspaceId, logType=$LogType)"
            [void](Send-ToLogAnalytics -Data $status -WorkspaceId $effectiveWorkspaceId -WorkspaceKey $effectiveWorkspaceKey -LogType $LogType -RetryCount $RetryCount -RetryDelaySeconds $RetryDelaySeconds)
        }
    } else {
        # Determine why ingestion was skipped
        if (-not $effectiveWorkspaceId -or -not $effectiveWorkspaceKey) {
            Write-Log "Log Analytics credentials missing; skipping ingest"
        } elseif (-not $effectiveEnableLogging) {
            Write-Log "Azure logging disabled via ENABLE_AZURE_LOGGING; skipping ingest"
        } else {
            Write-Log "Azure ingestion skipped (reason unknown)"
        }
    }

    # Troubleshooting hint: "Recovery partition not accessible" indicates the WinRE location from reagentc could not be accessed.
    # Common causes: hidden/unmounted recovery partition, stale volume GUID, disk/partition inconsistencies.
    
    # Ticketing disabled: keep full logs/audit trail but do not create tickets automatically
    if ($status.Severity -eq "Critical") {
        try {
            $ticketSubjectPreview = "CRITICAL: WinRE Health Issue - $($status.ComputerName)"
            $ticketBodyPreview = @(
                "WinRE Health Status: CRITICAL",
                "Computer: $($status.ComputerName)",
                "Manufacturer: $($status.Manufacturer)",
                "Model: $($status.Model)",
                "Serial Number: $($status.SerialNumber)",
                "Issue Details:",
                "  - WinRE Enabled: $($status.WinREEnabled)",
                "  - KB5034441 Vulnerable: $($status.KB5034441Vulnerable)",
                "  - Partition Size: $($status.PartitionSizeMB) MB",
                "  - Partition Free: $($status.PartitionFreeMB) MB",
                "Recommended Actions: " + ($status.RecommendedAction -join "; ")
            ) -join "`n"

            Write-Log ("CRITICAL detected - ticket creation disabled. Subject preview: " + $ticketSubjectPreview)
            Write-Log ("CRITICAL body preview: " + ($ticketBodyPreview.Substring(0, [Math]::Min(1000, $ticketBodyPreview.Length))))
            Write-Log "Critical issue detected - automatic ticket creation has been intentionally disabled"
        } catch { Write-Log "Failed writing ticket preview logs: $($_.Exception.Message)" }
    }
    
    # Output summary
    $totalElapsed = [math]::Round(((Get-Date) - $scriptStartTime).TotalMilliseconds, 2)
    Write-Log "=== Detection Complete ==="
    Write-Log "Severity: $($status.Severity)"
    Write-Log "Confidence Score: $($status.ConfidenceScore)"
    Write-Log "KB5034441 Vulnerable: $($status.KB5034441Vulnerable)"
    if ($null -ne $status.PartitionFreeTrendMBPerDay) { Write-Log "Trend: $($status.TrendDirection) at $($status.PartitionFreeTrendMBPerDay) MB/day (DaysUntilCritical=$($status.DaysUntilSpaceCritical))" }
    Write-Log "Function Execution Time: $($status.ScriptExecutionTimeMS)ms"
    Write-Log "Total Script Time: $totalElapsed ms"
    
    # Ephemeral cleanup (skip if TestMode or Persistent)
    if ($resolvedEphemeral -and -not $resolvedTestMode -and -not $resolvedPersistent -and $OutputDir) {
        try {
            Remove-Item -Path $OutputDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Ephemeral directory removed"
        } catch { Write-Log "Ephemeral cleanup failed: $($_.Exception.Message)" }
    } elseif ($resolvedTestMode) { Write-Log "TestMode active - retaining artifacts at $OutputDir" }
    
    # Return object for testing (instead of exit)
    if ($resolvedTestMode) { return $status }
    
    # Exit with appropriate code for NinjaOne (Critical returns 1; others 0)
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