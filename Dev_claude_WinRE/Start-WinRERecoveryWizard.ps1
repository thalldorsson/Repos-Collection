<#
.SYNOPSIS
    Launch WinRE Recovery Wizard

.DESCRIPTION
    Interactive wizard for diagnosing and fixing Windows Recovery Environment issues.
    Provides step-by-step guidance through detection, analysis, and remediation.

.PARAMETER AutoRemediate
    Automatically apply recommended fixes without prompting

.PARAMETER SkipBackup
    Skip creating system restore point (not recommended)

.EXAMPLE
    .\Start-WinRERecoveryWizard.ps1
    # Interactive mode with confirmations

.EXAMPLE
    .\Start-WinRERecoveryWizard.ps1 -AutoRemediate
    # Automatically apply fixes

.NOTES
    Version: 1.0.0
    Requires: PowerShell 5.1+, Administrator rights
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter()]
    [switch]$AutoRemediate,

    [Parameter()]
    [switch]$SkipBackup
)

# Import recovery wizard module
$modulePath = Join-Path $PSScriptRoot "Scripts"
Import-Module "$modulePath/RecoveryWizard.psm1" -Force

# Start the wizard
try {
    $result = Start-RecoveryWizard -AutoRemediate:$AutoRemediate -SkipBackup:$SkipBackup
    
    if ($result) {
        exit 0
    } else {
        exit 1
    }
}
catch {
    Write-Host "`n❌ Wizard failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
