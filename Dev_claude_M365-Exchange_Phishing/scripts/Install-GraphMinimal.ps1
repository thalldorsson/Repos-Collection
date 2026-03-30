<#!
.SYNOPSIS
Installs and imports the minimal Microsoft Graph PowerShell modules required by the MCP tools.

.DESCRIPTION
Avoids installing the full Microsoft.Graph meta-package. Installs only:
 - Microsoft.Graph.Authentication
 - Microsoft.Graph.Users
 - Microsoft.Graph.Users.Actions
 - Microsoft.Graph.Reports
 - Microsoft.Graph.Identity.SignIns
C:\Git-Repos-Crayon-User\Projects\Dev_claude_M365-Exchange_Phishing\scripts 
Then imports these modules for the current session. Use -ImportOnly to skip installation.

.EXAMPLE
scripts/Install-GraphMinimal.ps1

.EXAMPLE
scripts/Install-GraphMinimal.ps1 -ImportOnly
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [switch]$ImportOnly
)

$ErrorActionPreference = 'Stop'

# Recommend running this installer in PowerShell 7+
try {
  $psv = $PSVersionTable.PSVersion
  if ($psv.Major -lt 7) {
    Write-Warning "You are running Windows PowerShell $psv. For best compatibility with these tools, run this installer in PowerShell 7+ (pwsh) so modules install to 'Documents/PowerShell/Modules' and are visible to pwsh."
  }
} catch { }

$RequiredVersionString = '2.32.0'
$RequiredVersion       = [version]'2.32.0.0'

$Modules = @(
  'Microsoft.Graph.Authentication',
  'Microsoft.Graph.Users',
  'Microsoft.Graph.Users.Actions',
  'Microsoft.Graph.Reports',
  'Microsoft.Graph.Identity.SignIns'
)

function Write-Info($msg){ Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Warn($msg){ Write-Warning $msg }

foreach($m in $Modules){
  $available = @(Get-Module -ListAvailable -Name $m)

  if (-not $ImportOnly) {
    $hasRequired = $false
    if ($available.Count -gt 0) {
      $hasRequired = $available | Where-Object { $_.Version -eq $RequiredVersion } | ForEach-Object { $true } | Select-Object -First 1
      if (-not $hasRequired) { $hasRequired = $false }
    }

    if (-not $hasRequired) {
      Write-Info "Installing $m ($RequiredVersionString) ..."
      if ($PSCmdlet.ShouldProcess($m, 'Install-Module')) {
        Install-Module -Name $m -RequiredVersion $RequiredVersionString -Scope CurrentUser -Force -ErrorAction Stop
      }
    } else {
      $ver = ($available | Sort-Object Version -Descending | Select-Object -First 1).Version
      Write-Info "$m required version present (installed highest: $ver; required: $RequiredVersion)"
    }
  }

  # Import behavior: if already loaded but wrong version, warn and skip to avoid assembly conflicts
  $loaded = Get-Module -Name $m | Select-Object -First 1
  if ($null -ne $loaded) {
    if ($loaded.Version -ne $RequiredVersion) {
      Write-Warn "$m is already loaded (version $($loaded.Version)) but required is $RequiredVersion. Please start a fresh PowerShell 7 session (pwsh) and rerun this script to load the required version."
      continue
    } else {
      Write-Info "$m already loaded (required version $($loaded.Version))."
      continue
    }
  }

  # Import exact required version
  Write-Info "Importing $m ($RequiredVersionString) ..."
  Import-Module -Name $m -RequiredVersion $RequiredVersionString -ErrorAction Stop
}

Write-Info 'Microsoft Graph minimal modules are installed/imported.'
Write-Info 'You can now run: Connect-MgGraph -Scopes "AuditLog.Read.All,User.Read.All,User.ReadWrite.All,Directory.Read.All,ThreatHunting.Read.All"'
