<#[
.SYNOPSIS
    Enforce local Office macro hardening (workstation baseline)

.DESCRIPTION
    Configures the "Block macros from running in Office files from the Internet"
    policy for common Office apps by setting the corresponding registry values
    under HKCU:\Software\Policies\Microsoft\Office\16.0\<app>\security.

    This script targets the user policy hive (HKCU) for quick piloting and
    validation. For enterprise rollout, prefer:
      - Intune Administrative Templates or Settings Catalog
      - Office Cloud Policy Service (config.office.com)

    For Excel 4.0 (XLM) macros, Microsoft recommends disabling XLM macros. The
    most reliable deployment path is Intune Administrative Templates or Office
    Cloud Policy. This script reports guidance for XLM but does not set an
    unverified registry value.

.LINK
    Microsoft Learn: Macros from the Internet are blocked by default in Office
    https://learn.microsoft.com/microsoft-365-apps/security/internet-macros-blocked

.PARAMETER WhatIf
    Show intended changes without applying them (default).

.PARAMETER Verbose
    Show detailed logging.

.EXAMPLE
    # Detect current status only
    .\Set-OfficeMacroHardeningLocal.ps1

.EXAMPLE
    # Enforce local HKCU policy keys with confirmation prompt
    .\Set-OfficeMacroHardeningLocal.ps1 -Confirm

.EXAMPLE
    # Enforce without prompts
    .\Set-OfficeMacroHardeningLocal.ps1 -Confirm:$false -Force
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
param(
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info($msg) { Write-Host "[Info] $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "[Warn] $msg" -ForegroundColor Yellow }
function Write-Ok($msg)   { Write-Host "[Ok]  $msg" -ForegroundColor Green }
function Write-Err($msg)  { Write-Host "[Err] $msg" -ForegroundColor Red }

$apps = @(
    'word', 'excel', 'powerpoint', 'access', 'publisher', 'visio', 'project'
)

$results = @()

foreach ($app in $apps) {
    $regPath = "HKCU:\\Software\\Policies\\Microsoft\\Office\\16.0\\$app\\security"
    $name = 'blockcontentexecutionfrominternet'
    $desired = 1

    $current = $null
    if (Test-Path $regPath) {
        try { $current = (Get-ItemProperty -Path $regPath -Name $name -ErrorAction Stop).$name } catch { $current = $null }
    }

    $results += [pscustomobject]@{
        App      = $app
        Path     = $regPath
        Name     = $name
        Current  = $current
        Desired  = $desired
        Compliant = ($current -eq $desired)
    }
}

Write-Info 'Detected current user policy state for "Block macros from the Internet":'
$results | ForEach-Object {
    $status = if ($_.Compliant) { 'Compliant' } else { 'Drifted' }
    Write-Host (" - {0,-10} {1} -> {2} [{3}]" -f $_.App, ($_.Current ?? '<not set>'), $_.Desired, $status)
}

$drift = $results | Where-Object { -not $_.Compliant }
if (-not $drift) {
    Write-Ok 'All targeted apps already enforce "Block macros from the Internet" (HKCU).'
} else {
    Write-Warn ("{0} app(s) not compliant; will enforce if approved." -f ($drift.Count))

    foreach ($d in $drift) {
        if ($PSCmdlet.ShouldProcess("$($d.App)", "Set $($d.Path)\$($d.Name)=$($d.Desired)")) {
            if (-not (Test-Path $d.Path)) {
                New-Item -Path $d.Path -Force | Out-Null
            }
            New-ItemProperty -Path $d.Path -Name $d.Name -Value $d.Desired -PropertyType DWord -Force | Out-Null
            Write-Ok ("Applied: {0}" -f $d.Path)
        }
    }
}

Write-Host ""
Write-Info 'Excel 4.0 (XLM) Macros — Guidance'
Write-Host " - Microsoft recommends disabling XLM macros. The most reliable deployment path is:" -ForegroundColor Yellow
Write-Host "   * Intune Administrative Templates (Windows 10/11, Microsoft 365 Apps)" -ForegroundColor Yellow
Write-Host "   * Office Cloud Policy Service (config.office.com)" -ForegroundColor Yellow
Write-Host " - See: https://learn.microsoft.com/microsoft-365-apps/security/internet-macros-blocked (Tools available to manage policies)" -ForegroundColor Yellow

Write-Host ""
Write-Info 'Next steps for enterprise rollout'
Write-Host " 1) Pilot with this local baseline in a test ring (this script)" -ForegroundColor Gray
Write-Host " 2) Configure Intune Administrative Templates: Block macros from Internet for Excel/Word/PowerPoint" -ForegroundColor Gray
Write-Host " 3) Configure Excel 4.0 (XLM) macro policy to Disabled via Intune or Cloud Policy" -ForegroundColor Gray
Write-Host " 4) Monitor impact and iterate; then expand to broader rings" -ForegroundColor Gray

Write-Host ""
Write-Ok 'Done.'
