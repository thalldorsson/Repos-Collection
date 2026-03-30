#Requires -Version 5.1
<#
.SYNOPSIS
    Intune Proactive Remediation wrapper for WinRE-Remediate-Enhanced.ps1

.DESCRIPTION
    Lightweight wrapper for Intune Proactive Remediations that calls the enhanced
    remediation script with appropriate mode and parameters.
    
    This script is designed to be paired with WinRECollector-Detection.ps1 and will
    be triggered when detection returns non-zero (non-compliant).

.PARAMETER Mode
    Remediation mode:
    - EnableOnly: Safe enable-only (default, lowest risk)
    - EnableWithValidation: Enable with pre-flight checks
    - SafeResize: Full partition resize (requires approval setup)

.PARAMETER TargetSizeMB
    Target partition size for SafeResize mode (default: 550MB)

.PARAMETER WorkspaceId
    Azure Log Analytics Workspace ID (from environment if not specified)

.PARAMETER WorkspaceKey
    Azure Log Analytics Workspace Key (from environment if not specified)

.NOTES
    Version: 1.0.0
    Author: WinRE Health Monitor Team
    Compatible: Intune Proactive Remediations
    Execution Time: 5-60 seconds depending on mode
    
.EXAMPLE
    # Default mode (EnableOnly) - safest for continuous deployment
    .\WinRECollector-Remediation-Enhanced.ps1

.EXAMPLE
    # Enable with validation
    .\WinRECollector-Remediation-Enhanced.ps1 -Mode EnableWithValidation

.EXAMPLE
    # Safe resize (pilot only, with approval)
    .\WinRECollector-Remediation-Enhanced.ps1 -Mode SafeResize -TargetSizeMB 550
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [ValidateSet('EnableOnly', 'EnableWithValidation', 'SafeResize')]
    [string]$Mode = 'EnableOnly',
    
    [Parameter(Mandatory=$false)]
    [int]$TargetSizeMB = 550,
    
    [Parameter(Mandatory=$false)]
    [string]$WorkspaceId = $env:LA_WORKSPACE_ID,
    
    [Parameter(Mandatory=$false)]
    [string]$WorkspaceKey = $env:LA_WORKSPACE_KEY
)

$ErrorActionPreference = 'Continue'
$scriptVersion = '1.0.0'

Write-Host "WinRE Remediation Enhanced (Intune) - Mode: $Mode"

# Check if enhanced script exists (should be deployed as part of package)
$enhancedScriptPath = Join-Path $PSScriptRoot 'WinRE-Remediate-Enhanced.ps1'

if (-not (Test-Path $enhancedScriptPath)) {
    # Fallback: Try to find it in standard location
    $enhancedScriptPath = 'C:\ProgramData\WinRERemediation\WinRE-Remediate-Enhanced.ps1'
    
    if (-not (Test-Path $enhancedScriptPath)) {
        Write-Host "ERROR: Enhanced remediation script not found"
        Write-Host "Expected path: $PSScriptRoot\WinRE-Remediate-Enhanced.ps1"
        Write-Host "Or: C:\ProgramData\WinRERemediation\WinRE-Remediate-Enhanced.ps1"
        Write-Host ""
        Write-Host "Falling back to simple enable-only remediation..."
        
        # Fallback to simple enable
        try {
            Write-Host "Attempting simple WinRE enable..."
            $output = reagentc /enable 2>&1 | Out-String
            Write-Host "reagentc output: $output"
            
            Start-Sleep -Seconds 2
            
            $checkOutput = reagentc /info 2>&1 | Out-String
            if ($checkOutput -match 'Windows RE status\s*:\s*Enabled') {
                Write-Host "SUCCESS: WinRE enabled (fallback mode)"
                exit 0
            } else {
                Write-Host "WARNING: WinRE enable command completed but status check failed"
                exit 1
            }
        } catch {
            Write-Host "ERROR: Fallback enable failed: $_"
            exit 1
        }
    }
}

# Build parameters for enhanced script
$params = @{
    Mode = $Mode
    TargetSizeMB = $TargetSizeMB
    OutputStdOut = $true
    Ephemeral = $true
}

# Add Log Analytics credentials if available
if ($WorkspaceId -and $WorkspaceKey) {
    $params['WorkspaceId'] = $WorkspaceId
    $params['WorkspaceKey'] = $WorkspaceKey
    Write-Host "Log Analytics ingestion enabled"
} else {
    Write-Host "Log Analytics credentials not provided - results will not be ingested"
}

# For SafeResize mode, check if approval is granted
if ($Mode -eq 'SafeResize') {
    Write-Host "SafeResize mode requested - checking approval..."
    
    # In Intune deployment, approval can be managed via:
    # 1. Assignment filter (only deploy to approved devices)
    # 2. File-based approval flag
    # 3. Registry key
    
    $approvalMethods = @(
        'C:\ProgramData\WinRERemediation\SafeResize.approved',
        'HKLM:\SOFTWARE\WinREHealth\Remediation\SafeResizeApproved'
    )
    
    $approved = $false
    
    # Check file-based approval
    if (Test-Path $approvalMethods[0]) {
        $approved = $true
        Write-Host "Approval found (file-based)"
    }
    
    # Check registry-based approval
    try {
        $regValue = Get-ItemProperty -Path $approvalMethods[1] -Name 'Approved' -ErrorAction SilentlyContinue
        if ($regValue -and $null -ne $regValue.Approved -and $regValue.Approved -eq 1) {
            $approved = $true
            Write-Host "Approval found (registry-based)"
        }
    } catch {
        # No registry approval
    }
    
    if (-not $approved) {
        Write-Host "ERROR: SafeResize mode requires approval"
        Write-Host "To approve SafeResize for this device:"
        Write-Host "  Method 1: Create file: $($approvalMethods[0])"
        Write-Host "  Method 2: Set registry: $($approvalMethods[1]) -> Approved=1"
        Write-Host ""
        Write-Host "Falling back to EnableWithValidation mode..."
        $params['Mode'] = 'EnableWithValidation'
    }
}

# Execute enhanced remediation script
try {
    Write-Host "Executing enhanced remediation: $enhancedScriptPath"
    Write-Host "Parameters: $($params.Keys -join ', ')"
    
    $result = & $enhancedScriptPath @params
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "SUCCESS: Remediation completed"
        Write-Host "Result: $result"
        exit 0
    } else {
        Write-Host "WARNING: Remediation completed with issues"
        Write-Host "Result: $result"
        exit 1
    }
} catch {
    Write-Host "ERROR: Remediation execution failed: $_"
    Write-Host "Stack: $($_.ScriptStackTrace)"
    exit 1
}
