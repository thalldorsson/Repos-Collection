<#
.SYNOPSIS
  Creates an atomic backup of current HKCU Office macro hardening registry values.
.DESCRIPTION
  Enumerates target Office applications and captures the current value of
  'blockcontentexecutionfrominternet'. Saves as JSON array with app, path, value.
.PARAMETER OutputPath
  Path for backup file (default: MacroHardeningBackup.json in project root).
.EXAMPLE
  .\Save-OfficeMacroHardeningBackup.ps1
.EXAMPLE
  .\Save-OfficeMacroHardeningBackup.ps1 -OutputPath C:\temp\office-macro-backup.json
#>
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path (Get-Location) 'MacroHardeningBackup.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$apps = 'word','excel','powerpoint','access','publisher','visio','project'
$backup = @()
foreach ($app in $apps) {
    $regPath = "HKCU:\Software\Policies\Microsoft\Office\16.0\$app\security"
    $name = 'blockcontentexecutionfrominternet'
    $current = $null
    if (Test-Path $regPath) {
        try { $current = (Get-ItemProperty -Path $regPath -Name $name -ErrorAction Stop).$name } catch { $current = $null }
    }
    $backup += [pscustomobject]@{ app=$app; path=$regPath; name=$name; value=$current }
}
$backup | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputPath -Encoding UTF8
Write-Information "Backup written: $OutputPath"
