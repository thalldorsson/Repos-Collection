<#!
.SYNOPSIS
Checks local prerequisites for M365 Security MCP tools: required Graph modules, Graph connection and scopes, and optional EXO/IPPSSession connectivity.

.DESCRIPTION
Validates:
 - PowerShell version (7+ recommended)
 - Presence of minimal Microsoft Graph PowerShell modules
 - Ability to import minimal Graph modules
 - Microsoft Graph connection and required scopes
 - Optional Exchange Online / Security & Compliance connectivity

.PARAMETER SkipEXO
Skips Exchange Online / IPPSSession connectivity checks.

.EXAMPLE
scripts/Check-Prereqs.ps1

.EXAMPLE
scripts/Check-Prereqs.ps1 -SkipEXO

.NOTES
Run from repository root. If modules are missing, run scripts/Install-GraphMinimal.ps1 first.
#>

[CmdletBinding()]
param(
  [switch]$SkipEXO
)

$ErrorActionPreference = 'Stop'

function Write-Status {
  param(
    [ValidateSet('OK','WARN','ERROR')][string]$Level,
    [string]$Message
  )
  switch ($Level) {
    'OK'    { Write-Host "[ OK ] $Message" -ForegroundColor Green }
    'WARN'  { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
    'ERROR' { Write-Host "[ERR ] $Message" -ForegroundColor Red }
  }
}

$requiredGraphModules = @(
  'Microsoft.Graph.Authentication',
  'Microsoft.Graph.Users',
  'Microsoft.Graph.Users.Actions',
  'Microsoft.Graph.Reports',
  'Microsoft.Graph.Identity.SignIns'
)

$requiredModuleVersion = [version]'2.32.0.0'
$requiredModuleVersionStr = '2.32.0'

$requiredScopes = @(
  'AuditLog.Read.All',
  'User.Read.All',
  'User.ReadWrite.All',
  'Directory.Read.All',
  'ThreatHunting.Read.All'
)

$overallOk = $true

# PowerShell version
try {
  $psv = $PSVersionTable.PSVersion
  if ($psv.Major -ge 7) {
    Write-Status OK "PowerShell $psv detected (7+ recommended)."
  } else {
    Write-Status WARN "PowerShell $psv detected. PowerShell 7+ is recommended for best compatibility."
    Write-Status WARN "Tip: Run 'pwsh' to start PowerShell 7 if installed."
  }
} catch {
  Write-Status WARN "Unable to detect PowerShell version: $($_.Exception.Message)"
}

# Check modules present and required version
$missingOrOutdated = @()
foreach ($m in $requiredGraphModules) {
  $available = @(Get-Module -ListAvailable -Name $m)
  if ($available.Count -eq 0) {
    $missingOrOutdated += "$m (not installed)"
    continue
  }
  $hasRequired = $available | Where-Object { $_.Version -eq $requiredModuleVersion } | ForEach-Object { $true } | Select-Object -First 1
  if (-not $hasRequired) {
    $highest = ($available | Sort-Object Version -Descending | Select-Object -First 1).Version
    $missingOrOutdated += "$m (installed highest: $highest, required: $requiredModuleVersion)"
  }
}

if ($missingOrOutdated.Count -gt 0) {
  Write-Status WARN ("Missing or wrong Graph module version(s): {0}. Run scripts/Install-GraphMinimal.ps1 to install required version $requiredModuleVersionStr." -f ($missingOrOutdated -join '; '))
  Write-Status WARN "If you previously installed these under Windows PowerShell (5.1), rerun the installer in PowerShell 7 (pwsh) so modules are placed in 'Documents/PowerShell/Modules' and visible to pwsh."
  try {
    $paths = ($env:PSModulePath -split ';') -join "`n          "
    Write-Status WARN "Current PSModulePath includes:`n          $paths"
  } catch { }
  $overallOk = $false
} else {
  Write-Status OK "All required Graph modules are installed at version $requiredModuleVersion."
}

# Try import (exact version). Avoid re-import conflicts if wrong version already loaded.
try {
  foreach ($m in $requiredGraphModules) {
    $loaded = Get-Module -Name $m | Select-Object -First 1
    if ($null -ne $loaded) {
      if ($loaded.Version -ne $requiredModuleVersion) {
        Write-Status WARN "$m loaded with version $($loaded.Version), but required is $requiredModuleVersion. Start a fresh pwsh session and rerun scripts/Install-GraphMinimal.ps1."
        $overallOk = $false
        continue
      }
      continue
    }
    Import-Module -Name $m -RequiredVersion $requiredModuleVersionStr -ErrorAction Stop
  }
  Write-Status OK "Required Graph modules available in session (version $requiredModuleVersion)."
} catch {
  Write-Status ERROR "Failed to import Graph modules: $($_.Exception.Message)"
  $overallOk = $false
}

# Graph connection and scopes
try {
  $ctx = Get-MgContext -ErrorAction SilentlyContinue
  if (-not $ctx) {
    Write-Status WARN "Microsoft Graph not connected. Run: Connect-MgGraph -Scopes '" + ($requiredScopes -join ',') + "'"
    $overallOk = $false
  } else {
    Write-Status OK ("Microsoft Graph connected. TenantId: {0}" -f $ctx.TenantId)
    $scopes = @($ctx.Scopes)
    $missingScopes = @()
    foreach ($s in $requiredScopes) { if ($scopes -notcontains $s) { $missingScopes += $s } }
    if ($missingScopes.Count -gt 0) {
      Write-Status WARN ("Missing scopes: {0}. Reconnect with Connect-MgGraph -Scopes ..." -f ($missingScopes -join ', '))
      $overallOk = $false
    } else {
      Write-Status OK "All required Graph scopes present."
    }

    # Light API sanity checks (non-destructive)
    try {
      Get-MgUser -Top 1 -Property Id,DisplayName,UserPrincipalName -ErrorAction Stop | Out-Null
      Write-Status OK "Get-MgUser succeeded."
    } catch {
      Write-Status WARN "Get-MgUser failed: $($_.Exception.Message)"
    }

    try {
      Get-MgAuditLogSignIn -Top 1 -ErrorAction Stop | Out-Null
      Write-Status OK "Get-MgAuditLogSignIn succeeded."
    } catch {
      Write-Status WARN "Get-MgAuditLogSignIn failed (AuditLog.Read.All may be restricted or data not available): $($_.Exception.Message)"
    }
  }
} catch {
  Write-Status ERROR "Graph checks failed: $($_.Exception.Message)"
  $overallOk = $false
}

if (-not $SkipEXO) {
  # EXO module presence
  $exo = Get-Module -ListAvailable -Name ExchangeOnlineManagement | Select-Object -First 1
  if ($null -eq $exo) {
    Write-Status WARN "ExchangeOnlineManagement module not found. Install if you plan to use EXO/IPPSSession workflows."
  } else {
    Write-Status OK "ExchangeOnlineManagement module detected (version $($exo.Version))."
  }

  # EXO connectivity sanity (best-effort, may fail without connection/RBAC)
  try {
    Get-EXOMailbox -ResultSize 1 -ErrorAction Stop | Out-Null
    Write-Status OK "EXO connectivity looks good (Get-EXOMailbox)."
  } catch {
    Write-Status WARN "EXO not connected or insufficient RBAC (Get-EXOMailbox failed). Run Connect-ExchangeOnline if needed."
  }

  # IPPSSession (Security & Compliance) sanity
  try {
    Get-ComplianceSearch -ResultSize 1 -ErrorAction Stop | Out-Null
    Write-Status OK "IPPSSession cmdlets available (Get-ComplianceSearch)."
  } catch {
    Write-Status WARN "IPPSSession not connected or insufficient RBAC. Run Connect-IPPSSession -EnableSearchOnlySession if needed."
  }
}

if ($overallOk) {
  Write-Status OK "Prerequisite checks passed."
  exit 0
} else {
  Write-Status WARN "Prerequisite checks completed with warnings/errors. See messages above."
  exit 1
}
