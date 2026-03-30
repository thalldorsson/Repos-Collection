<#
.SYNOPSIS
  Restores Office macro hardening registry values from a backup JSON file.
.DESCRIPTION
  Reads a backup file created by Save-OfficeMacroHardeningBackup.ps1 and applies
  stored values for 'blockcontentexecutionfrominternet' under HKCU policy paths.
.PARAMETER BackupPath
  Path to backup file (default: MacroHardeningBackup.json in current location).
.PARAMETER Force
  Suppress confirmation prompts.
.EXAMPLE
  .\Restore-OfficeMacroHardeningBackup.ps1
.EXAMPLE
  .\Restore-OfficeMacroHardeningBackup.ps1 -BackupPath C:\temp\office-macro-backup.json -Force
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$BackupPath = (Join-Path (Get-Location) 'MacroHardeningBackup.json'),
    [switch]$Force
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $BackupPath)) { throw "Backup file not found: $BackupPath" }
$items = Get-Content $BackupPath -Raw | ConvertFrom-Json
foreach ($item in $items) {
    $regPath = $item.path
    $name = $item.name
    $value = $item.value
    if ($PSCmdlet.ShouldProcess($item.app, "Restore $regPath/$name=$value")) {
        if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
        if ($null -eq $value) {
            # Remove item if previously not set
            if (Get-ItemProperty -Path $regPath -Name $name -ErrorAction SilentlyContinue) {
                Remove-ItemProperty -Path $regPath -Name $name -Force -ErrorAction SilentlyContinue
            }
        } else {
            New-ItemProperty -Path $regPath -Name $name -Value $value -PropertyType DWord -Force | Out-Null
        }
    }
}
Write-Information "Restore complete from $BackupPath"
