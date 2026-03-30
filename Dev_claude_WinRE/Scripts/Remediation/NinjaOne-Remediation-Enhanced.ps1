#Requires -Version 5.1
<#
.SYNOPSIS
    NinjaOne RMM wrapper for WinRE-Remediate-Enhanced.ps1

.DESCRIPTION
    NinjaOne-compatible wrapper that:
    - Reads remediation mode from device custom field
    - Executes appropriate remediation
    - Updates device custom fields with results
    - Ingests results to Azure Log Analytics
    
.PARAMETER Mode
    Remediation mode (overrides custom field if specified):
    - EnableOnly: Safe enable-only (default)
    - EnableWithValidation: Enable with pre-flight checks
    - SafeResize: Full partition resize
    - Auto: Read from winreRemediationMode custom field

.PARAMETER TargetSizeMB
    Target partition size for SafeResize mode (default: 550MB)

.PARAMETER WorkspaceId
    Azure Log Analytics Workspace ID (maps to LA_WORKSPACE_ID org variable)

.PARAMETER WorkspaceKey
    Azure Log Analytics Workspace Key (maps to LA_WORKSPACE_KEY org variable)

.PARAMETER UpdateCustomFields
    Update NinjaOne device custom fields with results (default: $true)

.NOTES
    Version: 1.0.0
    Author: WinRE Health Monitor Team
    Compatible: NinjaOne RMM
    
    Required NinjaOne Custom Fields (outputs):
    - winreRemediationMode (Dropdown: EnableOnly, EnableWithValidation, SafeResize, Disabled)
    - winreRemediationStatus (Text: Last result)
    - winreRemediationTimestamp (Text: Last attempt timestamp)
    - winreRemediationApproved (Checkbox: Approval for SafeResize)
    - winreRemediationSuccess (Checkbox: Last result success flag)
    
    Required Script Variables (Organization scope - inputs):
    - LA_WORKSPACE_ID (Text)
    - LA_WORKSPACE_KEY (String/Text)
    
.EXAMPLE
    # Auto mode - read from custom field
    .\NinjaOne-Remediation-Enhanced.ps1 -WorkspaceId $env:LA_WORKSPACE_ID -WorkspaceKey $env:LA_WORKSPACE_KEY

.EXAMPLE
    # Force specific mode
    .\NinjaOne-Remediation-Enhanced.ps1 -Mode EnableWithValidation -WorkspaceId $env:LA_WORKSPACE_ID -WorkspaceKey $env:LA_WORKSPACE_KEY

.EXAMPLE
    # SafeResize with approval check
    .\NinjaOne-Remediation-Enhanced.ps1 -Mode SafeResize -TargetSizeMB 550 -WorkspaceId $env:LA_WORKSPACE_ID -WorkspaceKey $env:LA_WORKSPACE_KEY
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [ValidateSet('Auto', 'EnableOnly', 'EnableWithValidation', 'SafeResize', 'Disabled')]
    [string]$Mode = 'Auto',
    
    [Parameter(Mandatory=$false)]
    [int]$TargetSizeMB = 550,
    
    [Parameter(Mandatory=$false)]
    [string]$WorkspaceId = $env:LA_WORKSPACE_ID,
    
    [Parameter(Mandatory=$false)]
    [string]$WorkspaceKey = $env:LA_WORKSPACE_KEY,
    
    [Parameter(Mandatory=$false)]
    [bool]$UpdateCustomFields = $true
)

$ErrorActionPreference = 'Continue'
$scriptVersion = '1.0.0'

Write-Host "=== NinjaOne WinRE Remediation Enhanced ==="
Write-Host "Version: $scriptVersion"
Write-Host "Mode: $Mode"

#region NinjaOne Helper Functions

function Get-NinjaCustomField {
    param([string]$FieldName)
    
    try {
        # NinjaOne provides custom field values via Ninja-Property-Get cmdlet
        if (Get-Command 'Ninja-Property-Get' -ErrorAction SilentlyContinue) {
            $value = Ninja-Property-Get -Name $FieldName
            return $value
        } else {
            Write-Host "WARNING: Ninja-Property-Get not available (not running in NinjaOne context)"
            return $null
        }
    } catch {
        Write-Host "WARNING: Failed to get custom field '$FieldName': $_"
        return $null
    }
}

function Set-NinjaCustomField {
    param(
        [string]$FieldName,
        [string]$Value
    )
    
    try {
        # NinjaOne provides custom field update via Ninja-Property-Set cmdlet
        if (Get-Command 'Ninja-Property-Set' -ErrorAction SilentlyContinue) {
            Ninja-Property-Set -Name $FieldName -Value $Value
            Write-Host "Updated NinjaOne field: $FieldName = $Value"
            return $true
        } else {
            Write-Host "WARNING: Ninja-Property-Set not available (not running in NinjaOne context)"
            return $false
        }
    } catch {
        Write-Host "WARNING: Failed to set custom field '$FieldName': $_"
        return $false
    }
}

#endregion

# Determine effective remediation mode
$effectiveMode = $Mode

if ($Mode -eq 'Auto') {
    Write-Host "Auto mode - reading from winreRemediationMode custom field..."
    $customFieldMode = Get-NinjaCustomField -FieldName 'winreRemediationMode'
    
    if ($customFieldMode) {
        $effectiveMode = $customFieldMode
        Write-Host "Custom field mode: $effectiveMode"
    } else {
        $effectiveMode = 'EnableOnly'
        Write-Host "Custom field not set, defaulting to: $effectiveMode"
    }
}

# Check if remediation is disabled
if ($effectiveMode -eq 'Disabled') {
    Write-Host "Remediation is DISABLED via custom field"
    Write-Host "To enable, set winreRemediationMode to EnableOnly, EnableWithValidation, or SafeResize"
    
    if ($UpdateCustomFields) {
        Set-NinjaCustomField -FieldName 'winreRemediationStatus' -Value 'Disabled via custom field'
        Set-NinjaCustomField -FieldName 'winreRemediationTimestamp' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }
    
    exit 0
}

# Check for SafeResize approval
if ($effectiveMode -eq 'SafeResize') {
    Write-Host "SafeResize mode - checking approval..."
    
    $approved = Get-NinjaCustomField -FieldName 'winreRemediationApproved'
    
    # Robust approval check - handles various representations of true/false
    $approvalValue = $false
    if ($approved) {
        if ($approved -is [bool]) {
            $approvalValue = $approved
        } elseif ($approved -is [string]) {
            $approvalValue = ($approved.ToLower() -in @('true', '1', 'yes', 'on'))
        } elseif ($approved -is [int]) {
            $approvalValue = ($approved -eq 1)
        }
    }
    
    if (-not $approvalValue) {
        Write-Host "ERROR: SafeResize requires approval"
        Write-Host "Set winreRemediationApproved custom field to TRUE to approve"
        Write-Host "Falling back to EnableWithValidation..."
        
        $effectiveMode = 'EnableWithValidation'
        
        if ($UpdateCustomFields) {
            Set-NinjaCustomField -FieldName 'winreRemediationStatus' -Value 'SafeResize approval required'
            Set-NinjaCustomField -FieldName 'winreRemediationSuccess' -Value 'False'
            Set-NinjaCustomField -FieldName 'winreRemediationTimestamp' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        }
    } else {
        Write-Host "SafeResize approved via custom field"
    }
}

Write-Host "Effective mode: $effectiveMode"

# Locate enhanced remediation script
$enhancedScriptPath = Join-Path $PSScriptRoot '..\Remediation\WinRE-Remediate-Enhanced.ps1'

if (-not (Test-Path $enhancedScriptPath)) {
    # Try alternative paths
    $altPaths = @(
        'C:\ProgramData\WinRERemediation\WinRE-Remediate-Enhanced.ps1',
        'C:\ProgramData\NinjaRMMAgent\scripting\WinRE-Remediate-Enhanced.ps1'
    )
    
    $found = $false
    foreach ($path in $altPaths) {
        if (Test-Path $path) {
            $enhancedScriptPath = $path
            $found = $true
            break
        }
    }
    
    if (-not $found) {
        Write-Host "ERROR: Enhanced remediation script not found"
        Write-Host "Expected: $PSScriptRoot\..\Remediation\WinRE-Remediate-Enhanced.ps1"
        Write-Host "Or: C:\ProgramData\WinRERemediation\WinRE-Remediate-Enhanced.ps1"
        
        if ($UpdateCustomFields) {
            Set-NinjaCustomField -FieldName 'winreRemediationStatus' -Value 'Script not found'
            Set-NinjaCustomField -FieldName 'winreRemediationSuccess' -Value 'False'
            Set-NinjaCustomField -FieldName 'winreRemediationTimestamp' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        }
        
        exit 1
    }
}

Write-Host "Using script: $enhancedScriptPath"

# Build parameters
$params = @{
    Mode = $effectiveMode
    TargetSizeMB = $TargetSizeMB
}

# Add Log Analytics credentials if available
if ($WorkspaceId -and $WorkspaceKey) {
    $params['WorkspaceId'] = $WorkspaceId
    $params['WorkspaceKey'] = $WorkspaceKey
    Write-Host "Log Analytics ingestion enabled"
} else {
    Write-Host "WARNING: Log Analytics credentials not provided"
    Write-Host "Set LA_WORKSPACE_ID and LA_WORKSPACE_KEY org variables"
}

# Execute remediation
$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Write-Host "Executing remediation at $timestamp..."

try {
    $resultJson = & $enhancedScriptPath @params
    $exitCode = $LASTEXITCODE
    
    # Parse result if JSON
    try {
        $result = $resultJson | ConvertFrom-Json
        $success = $result.RemediationResult.Success
        $message = $result.RemediationResult.Message
        
        Write-Host ""
        Write-Host "=== Remediation Result ==="
        Write-Host "Success: $success"
        Write-Host "Message: $message"
        Write-Host "Mode: $($result.RemediationResult.Mode)"
        Write-Host "Actions: $($result.RemediationResult.ActionsTaken -join ', ')"
        
        if ($result.RemediationResult.OldSizeMB) {
            Write-Host "Old Size: $($result.RemediationResult.OldSizeMB)MB"
        }
        if ($result.RemediationResult.NewSizeMB) {
            Write-Host "New Size: $($result.RemediationResult.NewSizeMB)MB"
        }
        
        # Update custom fields
        if ($UpdateCustomFields) {
            Write-Host ""
            Write-Host "Updating NinjaOne custom fields..."
            
            Set-NinjaCustomField -FieldName 'winreRemediationStatus' -Value $message
            Set-NinjaCustomField -FieldName 'winreRemediationSuccess' -Value $success.ToString()
            Set-NinjaCustomField -FieldName 'winreRemediationTimestamp' -Value $timestamp
            
            # Update additional fields based on result
            if ($result.RemediationResult.WinREEnabledAfter -ne $null) {
                Set-NinjaCustomField -FieldName 'winreEnabled' -Value $result.RemediationResult.WinREEnabledAfter.ToString()
            }
            
            if ($result.RemediationResult.NewSizeMB) {
                Set-NinjaCustomField -FieldName 'winrePartitionSizeMB' -Value $result.RemediationResult.NewSizeMB.ToString()
            }
            
            # Clear approval flag if SafeResize completed
            if ($effectiveMode -eq 'SafeResize' -and $success) {
                Set-NinjaCustomField -FieldName 'winreRemediationApproved' -Value 'False'
                Write-Host "Cleared SafeResize approval flag"
            }
        }
        
        if ($success) {
            Write-Host ""
            Write-Host "SUCCESS: Remediation completed"
            exit 0
        } else {
            Write-Host ""
            Write-Host "FAILED: Remediation completed with errors"
            exit 1
        }
        
    } catch {
        Write-Host "WARNING: Could not parse JSON result: $_"
        Write-Host "Raw output: $resultJson"
        
        if ($UpdateCustomFields) {
            Set-NinjaCustomField -FieldName 'winreRemediationStatus' -Value "Completed (exit code: $exitCode)"
            Set-NinjaCustomField -FieldName 'winreRemediationSuccess' -Value ($exitCode -eq 0).ToString()
            Set-NinjaCustomField -FieldName 'winreRemediationTimestamp' -Value $timestamp
        }
        
        exit $exitCode
    }
    
} catch {
    Write-Host ""
    Write-Host "ERROR: Remediation execution failed"
    Write-Host "Exception: $_"
    Write-Host "Stack: $($_.ScriptStackTrace)"
    
    if ($UpdateCustomFields) {
        Set-NinjaCustomField -FieldName 'winreRemediationStatus' -Value "Execution failed: $_"
        Set-NinjaCustomField -FieldName 'winreRemediationSuccess' -Value 'False'
        Set-NinjaCustomField -FieldName 'winreRemediationTimestamp' -Value $timestamp
    }
    
    exit 1
}
