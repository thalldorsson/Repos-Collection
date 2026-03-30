<#
.SYNOPSIS
  Monitors Device Reset deployment success per wave and raises alerts when thresholds are breached.

.DESCRIPTION
  Aggregates success, failure, and "stuck" states for devices within a migration wave, based on
  telemetry available in Log Analytics (e.g., custom table DeviceResetStatus_CL or mapped signals
  from Intune/Win32 app deployment).

.PARAMETER TargetWave
  The migration wave name.

.PARAMETER WorkspaceId
  Azure Log Analytics Workspace ID.

.PARAMETER AlertThresholdSuccess
  Minimum acceptable success rate percentage before alerting.

.PARAMETER MaxStuckDevices
  Number of devices allowed in stuck state before alerting.

.OUTPUTS
  JSON summary object and optional Write-Error for alerting pipelines.
#>
param(
  [Parameter(Mandatory=$true)] [string]$TargetWave,
  [Parameter(Mandatory=$true)] [string]$WorkspaceId,
  [double]$AlertThresholdSuccess = 90.0,
  [int]$MaxStuckDevices = 10
)

$kql = @"
// Device Reset status by wave (replace with your actual table or signals)
let window = 24h;
DeviceResetStatus_CL
| where TimeGenerated > ago(window)
| where MigrationWave_s == '$TargetWave'
| summarize 
    Total = dcount(ComputerName_s),
    Success = dcountif(ComputerName_s, Status_s == "Success"),
    Failed = dcountif(ComputerName_s, Status_s == "Failed"),
    Stuck = dcountif(ComputerName_s, Status_s == "Installing")
| extend SuccessRate = round((Success * 100.0) / Total, 2)
"@

try {
  $res = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $kql -ErrorAction Stop
} catch {
  throw "Failed to query Log Analytics: $($_.Exception.Message)"
}

if (-not $res.Results -or $res.Results.Count -eq 0) {
  throw "No Device Reset telemetry found for wave '$TargetWave'."
}

$row = $res.Results[0]
$summary = [PSCustomObject]@{
  Wave = $TargetWave
  Total = [int]$row.Total
  Success = [int]$row.Success
  Failed = [int]$row.Failed
  Stuck = [int]$row.Stuck
  SuccessRate = [double]$row.SuccessRate
  Alert = $false
  Reasons = @()
}

if ($summary.SuccessRate -lt $AlertThresholdSuccess) {
  $summary.Alert = $true
  $summary.Reasons += "Success rate below threshold ($($summary.SuccessRate)% < $AlertThresholdSuccess%)"
}
if ($summary.Stuck -gt $MaxStuckDevices) {
  $summary.Alert = $true
  $summary.Reasons += "Too many stuck devices ($($summary.Stuck) > $MaxStuckDevices)"
}

$summary | ConvertTo-Json -Depth 4 | Write-Output

if ($summary.Alert) {
  $reasonText = ($summary.Reasons -join '; ')
  Write-Error ("Device Reset alert for wave {0}: {1}" -f $TargetWave, $reasonText)
}
