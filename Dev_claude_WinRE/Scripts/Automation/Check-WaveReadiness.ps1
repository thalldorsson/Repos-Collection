<#
.SYNOPSIS
  Evaluates migration wave health and returns GO/CAUTION/NO-GO with metrics.

.DESCRIPTION
  Queries Log Analytics for current wave status, applies thresholds and operational guardrails,
  and emits a structured result suitable for Automation runbooks or manual execution.

.PARAMETER TargetWave
  The migration wave name (e.g., "Wave 2", "Pilot").

.PARAMETER WorkspaceId
  Azure Log Analytics Workspace ID (GUID).

.PARAMETER GoThreshold
  Percentage of healthy devices required for GO.

.PARAMETER CautionThreshold
  Percentage of healthy devices for CAUTION band.

.PARAMETER MinSampleSize
  Minimum devices required to consider statistics valid.

.PARAMETER MaxPendingRebootPct
  Maximum percent of devices with pending reboot allowed for GO.

.PARAMETER MaxCriticalPct
  Maximum percent of devices in Critical status allowed for GO.

.OUTPUTS
  PSCustomObject with properties: Wave, Devices, HealthyPct, CriticalPct, PendingRebootPct,
  Decision, Reasons[], Timestamp.

.NOTES
  Safe to run on-prem or in Azure Automation with Az.Accounts and Az.OperationalInsights available.
#>
param(
  [Parameter(Mandatory=$true)] [string]$TargetWave,
  [Parameter(Mandatory=$true)] [string]$WorkspaceId,
  [double]$GoThreshold = 95.0,
  [double]$CautionThreshold = 90.0,
  [int]$MinSampleSize = 25,
  [double]$MaxPendingRebootPct = 5.0,
  [double]$MaxCriticalPct = 0.0
)

$Timestamp = (Get-Date).ToString("s")
$reasons = New-Object System.Collections.Generic.List[string]

# KQL query
$kql = @"
WinREHealthStatus_CL
| where TimeGenerated > ago(1d)
| where isnotempty(MigrationWave_s) and MigrationWave_s == '$TargetWave'
| summarize 
    Devices = dcount(ComputerName_s),
    Healthy = dcountif(ComputerName_s, Status_s == "Healthy"),
    Critical = dcountif(ComputerName_s, Status_s == "Critical"),
    PendingReboot = dcountif(ComputerName_s, PendingReboot_b == true)
| extend HealthyPct = round((Healthy * 100.0) / Devices, 2)
| extend CriticalPct = round((Critical * 100.0) / Devices, 2)
| extend PendingRebootPct = round((PendingReboot * 100.0) / Devices, 2)
"@

try {
  $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $kql -ErrorAction Stop
} catch {
  throw "Failed to query Log Analytics: $($_.Exception.Message)"
}

if (-not $result.Results -or $result.Results.Count -eq 0) {
  throw "No data returned for wave '$TargetWave'. Ensure ingestion is active."
}

$row = $result.Results[0]
$devices = [int]$row.Devices
$healthyPct = [double]$row.HealthyPct
$criticalPct = [double]$row.CriticalPct
$pendingPct = [double]$row.PendingRebootPct

# Guardrails
if ($devices -lt $MinSampleSize) { $reasons.Add("Insufficient sample size ($devices < $MinSampleSize)") }
if ($pendingPct -gt $MaxPendingRebootPct) { $reasons.Add("Pending reboot too high ($pendingPct% > $MaxPendingRebootPct%)") }
if ($criticalPct -gt $MaxCriticalPct) { $reasons.Add("Critical device percentage too high ($criticalPct% > $MaxCriticalPct%)") }

$decision = "NO-GO"
if ($healthyPct -ge $GoThreshold -and $reasons.Count -eq 0) {
  $decision = "GO"
} elseif ($healthyPct -ge $CautionThreshold) {
  $decision = "CAUTION"
}

$newObj = [PSCustomObject]@{
  Wave = $TargetWave
  Devices = $devices
  HealthyPct = $healthyPct
  CriticalPct = $criticalPct
  PendingRebootPct = $pendingPct
  Decision = $decision
  Reasons = $reasons.ToArray()
  Timestamp = $Timestamp
}

$newObj | ConvertTo-Json -Depth 4 | Write-Output
