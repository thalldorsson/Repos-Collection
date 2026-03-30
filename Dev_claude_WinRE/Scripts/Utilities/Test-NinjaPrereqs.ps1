<# 
.SYNOPSIS
  WinRE Health Preflight for NinjaOne

.DESCRIPTION
  Verifies NinjaOne prerequisites:
   - Org-level Script Variables mapping (WorkspaceId/WorkspaceKey/ENABLE_AZURE_LOGGING)
   - Required Device Custom Fields exist (reports any missing)
   - NinjaOne environment/cmdlets available
   - Optional write/read sanity check to a test field

.PARAMETERS
  WorkspaceId          LA_WORKSPACE_ID mapped to this parameter (String/Text)
  WorkspaceKey         LA_WORKSPACE_KEY mapped to this parameter (String/Text)

.NOTES
  Safe to run on endpoints; does not ingest data nor modify WinRE.
  Parameters are optional for local/manual runs: script will fall back to $env:la_workspace_id and $env:la_workspace_key when parameters are empty. In NinjaOne production runs, enforce Mandatory in the UI.
#>

param(
  # In production (Ninja UI), set these as Mandatory; in local/manual runs, env fallbacks are supported
  [string]$WorkspaceId,
  [string]$WorkspaceKey,

  # Optional: attempt a harmless set/read to a temp field
  [switch]$SanityWriteCheck,

  # Optional: list all known fields and their current values (uses required list)
  [switch]$ListFields,

  # Optional: print concise NinjaOne binding guide and exit
  [switch]$ShowBindingGuide,

  # Optional: choose one existing field for sanity check (defaults to winreScriptVersion)
  [string]$SanityFieldName = 'winreScriptVersion',

  # Default Log Analytics log type / table name
  [string]$LogType = 'WinREHealthV2'
)

# Minimum fields for dashboards/conditions
$RequiredNinjaFields = @(
  'winreEnabled','winreSeverity','winreKB5034441Vulnerable','winreConfidenceScore',
  'winreRecommendation','winrePartitionSizeMB','winrePartitionFreeMB','winreLastCheck',
  'winreBitLockerStatus','winreWindows11Ready','winreSecureBoot','winreFirmwareType'
)

# Optional extended metrics (enable as needed)
$OptionalNinjaFields = @(
  'winreTpmPresent','winreTpmReady','winrePendingReboot','winreIsRecoveryGptGuid',
  'winrePartitionGptType','winreIsLastPartition','winreAdjacentToOSPartition',
  'winreSupportedMaxSizeMB','winreCanGrowTo500MB','winreBCDId','winreRemediationReady',
  'winreRecommendedActionCode','winreScriptVersion','winreSchemaVersion',
  'winrePartitionFreeTrendMBPerDay','winreDaysUntilSpaceCritical','winreTrendDirection',
  'winreTrendAnalysisPeriodDays','winreDeviceCriticality','winreCriticalityPriority',
  'winreCriticalityReason',
  # Health status fields promoted to core in detectors
  'winrePartitionHealthStatus','winrePartitionOperationalStatus',
  'winreDiskHealthStatus','winreDiskOperationalStatus','winreBCDRecoveryGuid'
)

# Treat extended metrics as required for alignment
$RequiredNinjaFields = $RequiredNinjaFields + $OptionalNinjaFields

$errors   = @()
$warnings = @()
$info     = @()


function Write-Result([string]$level, [string]$msg) {
  $prefix = "{0}: " -f $level
  Write-Output ($prefix + $msg)
}

# Optional: show binding guide and exit early
if ($ShowBindingGuide) {
  Write-Result "INFO" "NinjaOne binding steps:"
  Write-Output "- Open the script in NinjaOne (Automation > Scripting)."
  Write-Output "- In the right panel, under 'Parameters':"
  Write-Output "    WorkspaceId  → Use org variable LA_WORKSPACE_ID (Text/String)"
  Write-Output "    WorkspaceKey → Use org variable LA_WORKSPACE_KEY (String/Text)"
  Write-Output "- Save. Then in Automation Library run dialog: choose Preset parameters by name (WorkspaceId, WorkspaceKey) and confirm values auto-fill (ID GUID, long secret)."
  Write-Output "- Ingestion proceeds automatically when credentials are present (no separate logging toggle)."
  Write-Output "- Run as System on a managed device."
  Write-Output ""
  exit 0
}

# 1) NinjaOne runtime sanity
try {
  $ninjaDeviceId = $env:COMPUTERNAME
  if (-not $ninjaDeviceId) { $warnings += "COMPUTERNAME missing (unlikely)" }

  # Check cmdlets exist
  $hasSet = Get-Command Ninja-Property-Set -ErrorAction SilentlyContinue
  $hasGet = Get-Command Ninja-Property-Get -ErrorAction SilentlyContinue
  if (-not $hasSet) { $errors += "Ninja-Property-Set cmdlet not available (ensure Ninja runtime context)" }
  if (-not $hasGet) { $warnings += "Ninja-Property-Get not available (not strictly required)" }
} catch {
  $errors += "Failed to verify Ninja runtime: $($_.Exception.Message)"
}

# 2) Org-level Script Variable mappings (with env fallback for local/manual runs)
$effectiveWorkspaceId  = $WorkspaceId
$effectiveWorkspaceKey = $WorkspaceKey
if ([string]::IsNullOrWhiteSpace($effectiveWorkspaceId))  { $effectiveWorkspaceId  = $env:la_workspace_id }
if ([string]::IsNullOrWhiteSpace($effectiveWorkspaceKey)) { $effectiveWorkspaceKey = $env:la_workspace_key }

if ([string]::IsNullOrWhiteSpace($effectiveWorkspaceId)) {
  $errors += "WorkspaceId parameter is empty. Map parameter WorkspaceId → Org Script Variable LA_WORKSPACE_ID (Text/String), or set env la_workspace_id"
} else {
  $info += "WorkspaceId provided: $effectiveWorkspaceId"
}

if ([string]::IsNullOrWhiteSpace($effectiveWorkspaceKey)) {
  $errors += "WorkspaceKey parameter is empty. Map parameter WorkspaceKey → Org Script Variable LA_WORKSPACE_KEY (String/Text), or set env la_workspace_key"
} else {
  $info += "WorkspaceKey provided (non-empty)"
}

$info += "Ingestion proceeds when both WorkspaceId and WorkspaceKey are present (no separate logging toggle). Default LogType/table: $LogType"

# 3) Device Custom Fields existence check (agent-context reliable)
$missingFields = @()
foreach ($field in $RequiredNinjaFields) {
  $exists = $false
  try {
    # Prefer a strict GET first; some Ninja cmdlets emit non-terminating errors by default
    $null = Ninja-Property-Get $field -ErrorAction Stop
    $exists = $true
  } catch {
    # Fallback probe: a harmless set of empty string to detect existence, but force terminating on failure
    try {
      Ninja-Property-Set $field "" -ErrorAction Stop 2>$null
      $exists = $true
    } catch {
      $exists = $false
    }
  }
  if (-not $exists) { $missingFields += $field }
}

if ($missingFields.Count -gt 0) {
  $errors += "Missing required Device Custom Fields (exact casing, Device scope): " + ($missingFields -join ', ')
} else {
  $info += "All required Device Custom Fields exist (verified on agent context)"
}

# Optional fields check removed: extended metrics are now required

# 4) Optional sanity write/read
if ($SanityWriteCheck -and $hasSet) {
  try {
    $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Ninja-Property-Set $SanityFieldName "Preflight ok @ $stamp"
    $info += "Sanity write to $SanityFieldName succeeded"
  } catch {
    $warnings += "Sanity write to $SanityFieldName failed: $($_.Exception.Message)"
  }
}

# 5) Optional: list current field values (required list)
if ($ListFields -and $hasGet) {
  Write-Result "INFO" "Listing current Ninja field values (required set):"
  foreach ($field in $RequiredNinjaFields) {
    try {
      $val = Ninja-Property-Get $field -ErrorAction Stop
      Write-Output ("  {0} = {1}" -f $field, $val)
    } catch {
      Write-Output ("  {0} = <missing or unreadable> ({1})" -f $field, $_.Exception.Message)
    }
  }
}

# 6) Summary
if ([string]::IsNullOrWhiteSpace($ninjaDeviceId)) { $nd = "<unknown>" } else { $nd = $ninjaDeviceId }
Write-Result "INFO" ("Ninja Device ID: " + $nd)

foreach ($i in $info)     { Write-Result "INFO"    $i }
foreach ($w in $warnings) { Write-Result "WARNING" $w }
foreach ($e in $errors)   { Write-Result "ERROR"   $e }

# Exit code convention: if any errors → 1, else 0
if ($errors.Count -gt 0) {
  exit 1
} else {
  exit 0
}
