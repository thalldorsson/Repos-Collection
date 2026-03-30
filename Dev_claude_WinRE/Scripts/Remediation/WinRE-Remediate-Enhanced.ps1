#Requires -Version 5.1
<#
.SYNOPSIS
    Enhanced WinRE Remediation Script with configurable remediation modes.

.DESCRIPTION
    Provides flexible remediation options for WinRE health issues with safety guardrails.
    Supports four modes: EnableOnly, EnableWithValidation, SafeResize, and WhatIf.
    Compatible with Intune Proactive Remediations and NinjaOne RMM.

.PARAMETER Mode
    Remediation mode to execute:
    - EnableOnly: Simple WinRE enable (lowest risk)
    - EnableWithValidation: Enable with pre-flight validation
    - SafeResize: Full partition resize with comprehensive checks
    - WhatIf: Simulation only, no changes made

.PARAMETER TargetSizeMB
    Target recovery partition size in MB (default: 550). Used in SafeResize mode.

.PARAMETER RequireApproval
    For SafeResize mode, check for approval flag before proceeding.

.PARAMETER WorkspaceId
    Azure Log Analytics Workspace ID for ingestion.

.PARAMETER WorkspaceKey
    Azure Log Analytics Workspace shared key (base64 encoded).

.PARAMETER LogType
    Log Analytics table name suffix (default: WinRERemediation).

.PARAMETER OutputStdOut
    Output results as JSON to stdout (Intune compatible).

.PARAMETER Ephemeral
    Use ephemeral temporary directory (auto-cleanup).

.PARAMETER UpdateNinjaFields
    Update NinjaOne device custom fields with results.

.NOTES
    Version: 1.0.0
    Author: WinRE Health Monitor Team
    Schema Version: 2025-12-21
    Compatible: Windows 10/11, PowerShell 5.1+

.EXAMPLE
    # Enable-only mode (safest)
    .\WinRE-Remediate-Enhanced.ps1 -Mode EnableOnly

.EXAMPLE
    # Enable with validation
    .\WinRE-Remediate-Enhanced.ps1 -Mode EnableWithValidation -WorkspaceId $wsId -WorkspaceKey $wsKey

.EXAMPLE
    # Safe resize with approval (maintenance window)
    .\WinRE-Remediate-Enhanced.ps1 -Mode SafeResize -TargetSizeMB 550 -RequireApproval

.EXAMPLE
    # Simulation mode
    .\WinRE-Remediate-Enhanced.ps1 -Mode WhatIf -TargetSizeMB 550
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [ValidateSet('EnableOnly', 'EnableWithValidation', 'SafeResize', 'WhatIf')]
    [string]$Mode = 'EnableOnly',
    
    [Parameter(Mandatory=$false)]
    [int]$TargetSizeMB = 550,
    
    [Parameter(Mandatory=$false)]
    [switch]$RequireApproval,
    
    [Parameter(Mandatory=$false)]
    [string]$WorkspaceId = $env:LA_WORKSPACE_ID,
    
    [Parameter(Mandatory=$false)]
    [string]$WorkspaceKey = $env:LA_WORKSPACE_KEY,
    
    [Parameter(Mandatory=$false)]
    [string]$LogType = 'WinRERemediation',
    
    [Parameter(Mandatory=$false)]
    [int]$RetryCount = 3,
    
    [Parameter(Mandatory=$false)]
    [int]$RetryDelaySeconds = 2,
    
    [Parameter(Mandatory=$false)]
    [switch]$OutputStdOut,
    
    [Parameter(Mandatory=$false)]
    [switch]$Ephemeral,
    
    [Parameter(Mandatory=$false)]
    [switch]$UpdateNinjaFields,
    
    [Parameter(Mandatory=$false)]
    [switch]$TestMode
)

# Import LogAnalyticsIngestion module for Azure Log Analytics ingestion
$laModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\LogAnalyticsIngestion.psm1'
if (Test-Path $laModulePath) {
    Import-Module $laModulePath -Force -ErrorAction SilentlyContinue
} else {
    Write-Warning "LogAnalyticsIngestion module not found at: $laModulePath. Azure ingestion will not be available."
}

# Script metadata
$scriptVersion = '1.0.0'
$schemaVersion = '2025-12-21'
$startTime = Get-Date

# Setup working directory
if ($OutputStdOut) {
    $WorkDir = $null
    $LogFile = $null
} else {
    if ($Ephemeral -or $Mode -eq 'EnableOnly') {
        $WorkDir = Join-Path $env:TEMP ("WinRERemediateEnhanced_" + [Guid]::NewGuid())
    } else {
        $WorkDir = 'C:\ProgramData\WinRERemediation'
    }
    
    if ($WorkDir -and !(Test-Path $WorkDir)) {
        New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null
    }
    
    $LogFile = if ($WorkDir) { Join-Path $WorkDir 'WinRERemediateEnhanced.log' } else { $null }
}

#region Helper Functions

function Write-Log {
    param([string]$Message)
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logMessage = "${timestamp}: [${Mode}] $Message"
    
    if (-not $OutputStdOut) {
        Write-Host $logMessage
        if ($LogFile) {
            Add-Content -Path $LogFile -Value $logMessage -ErrorAction SilentlyContinue
        }
    }
}

# Send-ToLogAnalytics function now imported from LogAnalyticsIngestion.psm1 module

function Get-WinREInfo {
    try {
        $info = reagentc /info 2>&1 | Out-String
        $enabled = $false
        $location = $null
        
        if ($info -match 'Windows RE status\s*:\s*(.+)') {
            $enabled = ($matches[1].Trim() -eq 'Enabled')
        }
        
        if ($info -match 'Windows RE location\s*:\s*(.+)') {
            $location = $matches[1].Trim()
        }
        
        return [pscustomobject]@{
            Enabled = $enabled
            Location = $location
            RawOutput = $info
        }
    } catch {
        Write-Log "Get-WinREInfo error: $($_.Exception.Message)"
        return [pscustomobject]@{
            Enabled = $false
            Location = $null
            RawOutput = $_.Exception.Message
        }
    }
}

function Test-PendingReboot {
    try {
        $paths = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        )
        
        foreach ($path in $paths) {
            if (Test-Path $path) {
                return $true
            }
        }
        
        $sm = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
        $val = Get-ItemProperty -Path $sm -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
        if ($val) {
            return $true
        }
        
        return $false
    } catch {
        Write-Log "Test-PendingReboot error: $($_.Exception.Message)"
        return $false
    }
}

function Test-BasicPreFlight {
    Write-Log "Running basic pre-flight checks..."
    
    $checks = [ordered]@{
        IsWindows10Or11 = $false
        HasAdminRights = $false
        NotInSafeMode = $false
        WinRELocationExists = $false
    }
    
    # Check Windows version
    try {
        $osVersion = [System.Environment]::OSVersion.Version
        $checks.IsWindows10Or11 = ($osVersion.Major -eq 10)
    } catch {
        Write-Log "OS version check failed: $($_.Exception.Message)"
    }
    
    # Check admin rights
    try {
        $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]$currentUser
        $checks.HasAdminRights = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        Write-Log "Admin check failed: $($_.Exception.Message)"
    }
    
    # Check not in safe mode
    try {
        $cimInstance = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($cimInstance -and $cimInstance.BootupState) {
            $safeMode = $cimInstance.BootupState
            $checks.NotInSafeMode = ($safeMode -ne 'Fail-safe boot' -and $safeMode -ne 'Fail-safe with network boot')
        } else {
            $checks.NotInSafeMode = $true  # Assume OK if check fails or CIM unavailable
        }
    } catch {
        $checks.NotInSafeMode = $true  # Assume OK if check fails
    }
    
    # Check WinRE location
    try {
        $winreInfo = Get-WinREInfo
        $checks.WinRELocationExists = (-not [string]::IsNullOrWhiteSpace($winreInfo.Location))
    } catch {
        Write-Log "WinRE location check failed: $($_.Exception.Message)"
    }
    
    $allPassed = ($checks.Values | Where-Object { $_ -eq $false }).Count -eq 0
    
    return [pscustomobject]@{
        Checks = $checks
        AllPassed = $allPassed
    }
}

function Test-ValidationPreFlight {
    Write-Log "Running validation pre-flight checks..."
    
    $basic = Test-BasicPreFlight
    if (-not $basic.AllPassed) {
        return [pscustomobject]@{
            BasicChecks = $basic.Checks
            PartitionAccessible = $false
            PartitionGUIDValid = $false
            AllPassed = $false
        }
    }
    
    $checks = $basic.Checks
    $checks['PartitionAccessible'] = $false
    $checks['PartitionGUIDValid'] = $false
    
    try {
        $winreInfo = Get-WinREInfo
        
        if ($winreInfo.Location -match 'harddisk(\d+)\\partition(\d+)') {
            $diskNum = [int]$matches[1]
            $partNum = [int]$matches[2]
            
            $partition = Get-Partition -DiskNumber $diskNum -PartitionNumber $partNum -ErrorAction SilentlyContinue
            if ($partition) {
                $checks['PartitionAccessible'] = $true
                
                # Check if it's a proper recovery partition
                if ($partition.GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}') {
                    $checks['PartitionGUIDValid'] = $true
                }
            }
        }
    } catch {
        Write-Log "Partition validation failed: $($_.Exception.Message)"
    }
    
    $allPassed = ($checks.Values | Where-Object { $_ -eq $false }).Count -eq 0
    
    return [pscustomobject]@{
        Checks = $checks
        AllPassed = $allPassed
    }
}

function Test-ComprehensivePreFlight {
    param(
        [int]$RequiredFreeMB = 250,
        [int]$TargetSizeMB = $TargetSizeMB
    )
    
    Write-Log "Running comprehensive pre-flight checks for SafeResize..."
    
    $validation = Test-ValidationPreFlight
    if (-not $validation.AllPassed) {
        return [pscustomobject]@{
            Checks = $validation.Checks
            AllPassed = $false
            CanResize = $false
            RiskFlags = @('BASIC_VALIDATION_FAILED')
        }
    }
    
    $checks = $validation.Checks
    $checks['NoPendingReboot'] = -not (Test-PendingReboot)
    $checks['BitLockerSafe'] = $true
    $checks['SmartHealthy'] = $true
    $checks['CanGrowPartition'] = $false
    
    $riskFlags = @()
    
    # BitLocker check
    try {
        $bl = Get-BitLockerVolume -ErrorAction SilentlyContinue | Where-Object VolumeType -eq 'OperatingSystem' | Select-Object -First 1
        if ($bl) {
            $encryptionPercent = $bl.EncryptionPercentage
            if ($null -ne $encryptionPercent -and $encryptionPercent -lt 100 -and $encryptionPercent -gt 0) {
                $checks['BitLockerSafe'] = $false
                $riskFlags += 'BITLOCKER_IN_PROGRESS'
            }
        }
    } catch {
        Write-Log "BitLocker check warning: $($_.Exception.Message)"
    }
    
    # SMART health check
    try {
        $physDisks = Get-PhysicalDisk -ErrorAction SilentlyContinue
        if ($physDisks) {
            $unhealthy = $physDisks | Where-Object { $_.HealthStatus -notin @('Healthy', 'Unknown') }
            if ($unhealthy) {
                $checks['SmartHealthy'] = $false
                $riskFlags += 'SMART_UNHEALTHY'
            }
        }
    } catch {
        Write-Log "SMART check warning: $($_.Exception.Message)"
    }
    
    # Partition resize capability check
    try {
        $winreInfo = Get-WinREInfo
        if ($winreInfo.Location -match 'harddisk(\d+)\\partition(\d+)') {
            $diskNum = [int]$matches[1]
            $partNum = [int]$matches[2]
            
            $supported = Get-PartitionSupportedSize -DiskNumber $diskNum -PartitionNumber $partNum -ErrorAction SilentlyContinue
            if ($supported) {
                $maxMB = [math]::Round($supported.SizeMax / 1MB, 2)
                $checks['CanGrowPartition'] = ($maxMB -ge $TargetSizeMB)
                
                if (-not $checks['CanGrowPartition']) {
                    $riskFlags += "INSUFFICIENT_MAX_SIZE_${maxMB}MB"
                }
            } else {
                $riskFlags += 'SUPPORTED_SIZE_UNAVAILABLE'
            }
        }
    } catch {
        Write-Log "Partition resize check failed: $($_.Exception.Message)"
        $riskFlags += 'RESIZE_CHECK_ERROR'
    }
    
    $allPassed = ($checks.Values | Where-Object { $_ -eq $false }).Count -eq 0
    
    return [pscustomobject]@{
        Checks = $checks
        AllPassed = $allPassed
        CanResize = $checks['CanGrowPartition']
        RiskFlags = $riskFlags
    }
}

function Invoke-EnableOnly {
    Write-Log "Executing EnableOnly mode..."
    
    $result = [ordered]@{
        Mode = 'EnableOnly'
        Success = $false
        Message = $null
        WinREEnabledBefore = $false
        WinREEnabledAfter = $false
        ActionsTaken = @()
    }
    
    try {
        $winreBefore = Get-WinREInfo
        $result.WinREEnabledBefore = $winreBefore.Enabled
        
        if ($winreBefore.Enabled) {
            $result.Success = $true
            $result.Message = "WinRE already enabled"
            Write-Log $result.Message
        } else {
            Write-Log "Attempting to enable WinRE..."
            $output = reagentc /enable 2>&1 | Out-String
            $result.ActionsTaken += "reagentc /enable executed"
            
            Start-Sleep -Seconds 2
            
            $winreAfter = Get-WinREInfo
            $result.WinREEnabledAfter = $winreAfter.Enabled
            
            if ($winreAfter.Enabled) {
                $result.Success = $true
                $result.Message = "WinRE successfully enabled"
                Write-Log $result.Message
            } else {
                $result.Message = "WinRE enable command completed but status check failed"
                Write-Log $result.Message
            }
        }
    } catch {
        $result.Message = "EnableOnly failed: $($_.Exception.Message)"
        Write-Log $result.Message
    }
    
    return $result
}

function Invoke-EnableWithValidation {
    Write-Log "Executing EnableWithValidation mode..."
    
    $result = [ordered]@{
        Mode = 'EnableWithValidation'
        Success = $false
        Message = $null
        PreFlightPassed = $false
        PreFlightChecks = $null
        WinREEnabledBefore = $false
        WinREEnabledAfter = $false
        ActionsTaken = @()
    }
    
    try {
        # Pre-flight validation
        $preFlight = Test-ValidationPreFlight
        $result.PreFlightChecks = $preFlight.Checks
        $result.PreFlightPassed = $preFlight.AllPassed
        
        if (-not $preFlight.AllPassed) {
            $failedChecks = $preFlight.Checks.Keys | Where-Object { -not $preFlight.Checks[$_] }
            $result.Message = "Pre-flight validation failed: $($failedChecks -join ', ')"
            Write-Log $result.Message
            return $result
        }
        
        # Pre-flight passed, proceed with enable
        $winreBefore = Get-WinREInfo
        $result.WinREEnabledBefore = $winreBefore.Enabled
        
        if ($winreBefore.Enabled) {
            $result.Success = $true
            $result.Message = "WinRE already enabled (pre-flight passed)"
            Write-Log $result.Message
        } else {
            Write-Log "Pre-flight passed, attempting to enable WinRE..."
            $output = reagentc /enable 2>&1 | Out-String
            $result.ActionsTaken += "reagentc /enable executed"
            
            Start-Sleep -Seconds 2
            
            $winreAfter = Get-WinREInfo
            $result.WinREEnabledAfter = $winreAfter.Enabled
            
            if ($winreAfter.Enabled) {
                $result.Success = $true
                $result.Message = "WinRE successfully enabled (pre-flight passed)"
                Write-Log $result.Message
            } else {
                $result.Message = "WinRE enable command completed but validation failed"
                Write-Log $result.Message
            }
        }
    } catch {
        $result.Message = "EnableWithValidation failed: $($_.Exception.Message)"
        Write-Log $result.Message
    }
    
    return $result
}

function Invoke-SafeResize {
    param([int]$TargetSizeMB)
    
    Write-Log "Executing SafeResize mode (target: ${TargetSizeMB}MB)..."
    
    $result = [ordered]@{
        Mode = 'SafeResize'
        Success = $false
        Message = $null
        PreFlightPassed = $false
        PreFlightChecks = $null
        PreFlightRiskFlags = @()
        OldSizeMB = $null
        NewSizeMB = $null
        TargetSizeMB = $TargetSizeMB
        WinREEnabledBefore = $false
        WinREEnabledAfter = $false
        ActionsTaken = @()
    }
    
    try {
        # Comprehensive pre-flight
        $preFlight = Test-ComprehensivePreFlight -RequiredFreeMB 250 -TargetSizeMB $TargetSizeMB
        $result.PreFlightChecks = $preFlight.Checks
        $result.PreFlightPassed = $preFlight.AllPassed
        $result.PreFlightRiskFlags = $preFlight.RiskFlags
        
        if (-not $preFlight.AllPassed) {
            $failedChecks = $preFlight.Checks.Keys | Where-Object { -not $preFlight.Checks[$_] }
            $result.Message = "Pre-flight failed: $($failedChecks -join ', ') | Flags: $($preFlight.RiskFlags -join ', ')"
            Write-Log $result.Message
            return $result
        }
        
        if (-not $preFlight.CanResize) {
            $result.Message = "Cannot resize: partition cannot grow to target size"
            Write-Log $result.Message
            return $result
        }
        
        # Get partition info
        $winreInfo = Get-WinREInfo
        $result.WinREEnabledBefore = $winreInfo.Enabled
        
        if (-not ($winreInfo.Location -match 'harddisk(\d+)\\partition(\d+)')) {
            $result.Message = "Cannot parse disk/partition from WinRE location"
            Write-Log $result.Message
            return $result
        }
        
        $diskNum = [int]$matches[1]
        $partNum = [int]$matches[2]
        
        $partition = Get-Partition -DiskNumber $diskNum -PartitionNumber $partNum -ErrorAction Stop
        $oldSizeMB = [math]::Round($partition.Size / 1MB, 2)
        $result.OldSizeMB = $oldSizeMB
        
        if ($oldSizeMB -ge $TargetSizeMB) {
            $result.Success = $true
            $result.Message = "Partition already meets target size (${oldSizeMB}MB >= ${TargetSizeMB}MB)"
            $result.NewSizeMB = $oldSizeMB
            Write-Log $result.Message
            return $result
        }
        
        # Disable WinRE before resize
        if ($winreInfo.Enabled) {
            Write-Log "Disabling WinRE before resize..."
            reagentc /disable 2>&1 | Out-Null
            $result.ActionsTaken += "reagentc /disable"
            Start-Sleep -Seconds 2
        }
        
        # Resize partition
        Write-Log "Resizing partition from ${oldSizeMB}MB to ${TargetSizeMB}MB..."
        $resizeTargetBytes = ($TargetSizeMB * 1MB)
        Resize-Partition -DiskNumber $diskNum -PartitionNumber $partNum -Size $resizeTargetBytes -ErrorAction Stop
        $result.ActionsTaken += "Resize-Partition"
        
        Start-Sleep -Seconds 3
        
        # Verify resize
        $partitionAfter = Get-Partition -DiskNumber $diskNum -PartitionNumber $partNum -ErrorAction Stop
        $newSizeMB = [math]::Round($partitionAfter.Size / 1MB, 2)
        $result.NewSizeMB = $newSizeMB
        
        if ($newSizeMB -ge $TargetSizeMB) {
            Write-Log "Resize successful: ${oldSizeMB}MB -> ${newSizeMB}MB"
        } else {
            Write-Log "WARNING: Resize incomplete: ${oldSizeMB}MB -> ${newSizeMB}MB (target: ${TargetSizeMB}MB)"
        }
        
        # Re-enable WinRE
        Write-Log "Re-enabling WinRE..."
        reagentc /enable 2>&1 | Out-Null
        $result.ActionsTaken += "reagentc /enable"
        Start-Sleep -Seconds 2
        
        $winreAfter = Get-WinREInfo
        $result.WinREEnabledAfter = $winreAfter.Enabled
        
        if ($newSizeMB -ge $TargetSizeMB -and $winreAfter.Enabled) {
            $result.Success = $true
            $result.Message = "SafeResize completed successfully"
            Write-Log $result.Message
        } else {
            $result.Message = "SafeResize completed with issues (size: ${newSizeMB}MB, WinRE: $($winreAfter.Enabled))"
            Write-Log $result.Message
        }
        
    } catch {
        $result.Message = "SafeResize failed: $($_.Exception.Message)"
        Write-Log $result.Message
        
        # Attempt to re-enable WinRE if it was enabled before
        if ($result.WinREEnabledBefore -and -not $result.WinREEnabledAfter) {
            Write-Log "Attempting to restore WinRE enabled state..."
            try {
                reagentc /enable 2>&1 | Out-Null
                $result.ActionsTaken += "reagentc /enable (rollback)"
            } catch {
                Write-Log "Rollback failed: $($_.Exception.Message)"
            }
        }
    }
    
    return $result
}

function Invoke-WhatIfMode {
    param([int]$TargetSizeMB)
    
    Write-Log "Executing WhatIf mode (simulation only)..."
    
    $result = [ordered]@{
        Mode = 'WhatIf'
        Success = $true
        Message = "Simulation completed - no changes made"
        PreFlightChecks = $null
        PreFlightRiskFlags = @()
        CurrentSizeMB = $null
        TargetSizeMB = $TargetSizeMB
        WouldResize = $false
        WouldEnable = $false
        EstimatedActions = @()
    }
    
    try {
        $preFlight = Test-ComprehensivePreFlight -TargetSizeMB $TargetSizeMB
        $result.PreFlightChecks = $preFlight.Checks
        $result.PreFlightRiskFlags = $preFlight.RiskFlags
        
        $winreInfo = Get-WinREInfo
        
        if ($winreInfo.Location -match 'harddisk(\d+)\\partition(\d+)') {
            $diskNum = [int]$matches[1]
            $partNum = [int]$matches[2]
            
            $partition = Get-Partition -DiskNumber $diskNum -PartitionNumber $partNum -ErrorAction SilentlyContinue
            if ($partition) {
                $currentSizeMB = [math]::Round($partition.Size / 1MB, 2)
                $result.CurrentSizeMB = $currentSizeMB
                
                if ($currentSizeMB -lt $TargetSizeMB) {
                    $result.WouldResize = $true
                    $result.EstimatedActions += "Would resize partition from ${currentSizeMB}MB to ${TargetSizeMB}MB"
                }
            }
        }
        
        if (-not $winreInfo.Enabled) {
            $result.WouldEnable = $true
            $result.EstimatedActions += "Would enable WinRE (currently disabled)"
        }
        
        if ($result.EstimatedActions.Count -eq 0) {
            $result.EstimatedActions += "No actions needed - WinRE healthy"
        }
        
        Write-Log "WhatIf summary: $($result.EstimatedActions -join '; ')"
        
    } catch {
        $result.Message = "WhatIf simulation error: $($_.Exception.Message)"
        Write-Log $result.Message
    }
    
    return $result
}

#endregion

#region Main Execution

Write-Log "WinRE-Remediate-Enhanced.ps1 starting (Mode: $Mode, Version: $scriptVersion)"

# Build result object
$result = [ordered]@{
    Timestamp = (Get-Date).ToUniversalTime().ToString('o')
    ComputerName = $env:COMPUTERNAME
    ScriptVersion = $scriptVersion
    SchemaVersion = $schemaVersion
    Mode = $Mode
    TargetSizeMB = $TargetSizeMB
    RemediationResult = $null
}

# Execute appropriate mode
try {
    switch ($Mode) {
        'EnableOnly' {
            $result.RemediationResult = Invoke-EnableOnly
        }
        'EnableWithValidation' {
            $result.RemediationResult = Invoke-EnableWithValidation
        }
        'SafeResize' {
            # Check approval if required
            if ($RequireApproval) {
                # Check for approval flag (e.g., from NinjaOne custom field or file)
                $approvalPath = Join-Path $env:ProgramData 'WinRERemediation\SafeResize.approved'
                if (-not (Test-Path $approvalPath)) {
                    $result.RemediationResult = [ordered]@{
                        Mode = 'SafeResize'
                        Success = $false
                        Message = "SafeResize requires approval. Approval file not found: $approvalPath"
                        ActionsTaken = @()
                    }
                    Write-Log $result.RemediationResult.Message
                } else {
                    $result.RemediationResult = Invoke-SafeResize -TargetSizeMB $TargetSizeMB
                }
            } else {
                $result.RemediationResult = Invoke-SafeResize -TargetSizeMB $TargetSizeMB
            }
        }
        'WhatIf' {
            $result.RemediationResult = Invoke-WhatIfMode -TargetSizeMB $TargetSizeMB
        }
    }
} catch {
    Write-Log "Mode execution failed: $($_.Exception.Message)"
    $result.RemediationResult = [ordered]@{
        Mode = $Mode
        Success = $false
        Message = "Execution failed: $($_.Exception.Message)"
        ActionsTaken = @()
    }
}

$elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 2)
$result['ExecutionTimeSeconds'] = $elapsed
Write-Log "Execution completed in ${elapsed}s (Success: $($result.RemediationResult.Success))"

# Output results
$jsonOutput = $result | ConvertTo-Json -Depth 10

if ($OutputStdOut) {
    Write-Output $jsonOutput
} else {
    if ($WorkDir) {
        $outputPath = Join-Path $WorkDir 'WinRERemediateEnhanced.json'
        $jsonOutput | Out-File -FilePath $outputPath -Encoding UTF8 -Force
        Write-Log "Results written to: $outputPath"
    }
}

# Send to Log Analytics if credentials provided
if ($WorkspaceId -and $WorkspaceKey) {
    try {
        $ingested = Send-ToLogAnalytics -Data $result -WorkspaceId $WorkspaceId -WorkspaceKey $WorkspaceKey -LogType $LogType -RetryCount $RetryCount -RetryDelaySeconds $RetryDelaySeconds
        Write-Log "Log Analytics ingestion: $ingested"
    } catch {
        Write-Log "Log Analytics ingestion failed: $($_.Exception.Message)"
    }
}

# Cleanup ephemeral directory
if ($Ephemeral -and $WorkDir -and -not $TestMode) {
    try {
        Start-Sleep -Seconds 1
        Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction Stop
        Write-Log "Cleaned up ephemeral directory: $WorkDir"
    } catch {
        Write-Log "WARNING: Cleanup failed for $WorkDir : $($_.Exception.Message)"
        # Continue anyway, non-critical error
    }
}

# Exit with appropriate code
if ($result.RemediationResult.Success) {
    exit 0
} else {
    exit 1
}

#endregion
