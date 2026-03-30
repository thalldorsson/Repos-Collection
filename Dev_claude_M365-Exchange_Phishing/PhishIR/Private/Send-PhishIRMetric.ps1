function Send-PhishIRMetric {
    <#
    .SYNOPSIS
    Record operational metrics for PhishIR module usage and performance tracking.

    .DESCRIPTION
    Logs metrics to a JSONL file for dashboard reporting, trend analysis, and capacity planning.
    Supports tagging for multi-dimensional analysis (e.g., by severity, incident type, tenant).

    Common use cases:
    - Track incident creation rates
    - Monitor sign-in query performance
    - Measure URL blocking throughput
    - Audit SIEM ingestion volumes
    - Capacity planning (incidents/month, storage growth)

    Metrics are written to Storage.Exports.BasePath/metrics.jsonl and can be ingested into:
    - Power BI (via Direct Query or scheduled import)
    - Azure Monitor (via custom metrics API)
    - Splunk/Sentinel (via file-based ingestion)

    .PARAMETER MetricName
    Name of the metric (e.g., 'incident.created', 'signins.queried', 'urls.blocked').
    Use dot notation for hierarchical organization.

    .PARAMETER Value
    Numeric value of the metric (count, duration, bytes, etc.).

    .PARAMETER Tags
    Hashtable of tags for multi-dimensional filtering (e.g., @{ Severity = 'High'; Type = 'ExcelPhishing' }).

    .PARAMETER Unit
    Optional unit of measurement (e.g., 'count', 'seconds', 'bytes').

    .EXAMPLE
    Send-PhishIRMetric -MetricName 'incident.created' -Value 1 -Tags @{ Severity = 'High'; Type = 'ExcelPhishing' }

    Record incident creation with severity and type tags.

    .EXAMPLE
    Send-PhishIRMetric -MetricName 'signins.queried' -Value 150 -Unit 'count'

    Track number of sign-ins queried.

    .EXAMPLE
    $duration = Measure-Command { Get-PhishIRUserSignInHistory -UserPrincipalNames $users }
    Send-PhishIRMetric -MetricName 'signins.query.duration' -Value $duration.TotalSeconds -Unit 'seconds' -Tags @{ UserCount = $users.Count }

    Measure and record sign-in query performance.

    .EXAMPLE
    # Dashboard query (Power BI / KQL)
    # Total incidents by type (last 30 days)
    # metrics.jsonl | where MetricName == 'incident.created' | where Timestamp > ago(30d) | summarize count() by Tags.Type

    .NOTES
    Metrics are stored in JSONL format (one metric per line) for efficient streaming and ingestion.
    File location: <Storage.Exports.BasePath>/metrics.jsonl

    Recommended metric naming conventions:
    - incident.created, incident.updated, incident.closed
    - signins.queried, signins.risky
    - urls.extracted, urls.blocked
    - siem.ingested (Sentinel/Splunk)
    - storage.bytes (disk usage)

    .LINK
    Add-PhishIRIncidentRecord
    Get-PhishIRUserSignInHistory
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$MetricName,

        [Parameter(Mandatory = $true)]
        [double]$Value,

        [Parameter(Mandatory = $false)]
        [hashtable]$Tags = @{},

        [Parameter(Mandatory = $false)]
        [string]$Unit
    )

    try {
        # Build metric record
        $metric = [ordered]@{
            Timestamp = (Get-Date).ToUniversalTime().ToString('o')
            MetricName = $MetricName
            Value = $Value
        }

        if ($Unit) {
            $metric['Unit'] = $Unit
        }

        if ($Tags.Count -gt 0) {
            $metric['Tags'] = $Tags
        }

        # Convert to JSON (single line)
        $jsonLine = $metric | ConvertTo-Json -Depth 5 -Compress

        # Determine metrics file path
        try {
            $exportsPath = Get-PhishIRStoragePath -PathType 'All' -CreateIfMissing
            $metricsFile = Join-Path $exportsPath['IncidentReports'] 'metrics.jsonl'
        } catch {
            # Fallback to legacy path
            $moduleRoot = Split-Path -Parent $PSScriptRoot
            $metricsDir = Join-Path (Join-Path $moduleRoot 'Exports') 'Reports'
            if (-not (Test-Path $metricsDir)) {
                New-Item -ItemType Directory -Path $metricsDir -Force | Out-Null
            }
            $metricsFile = Join-Path $metricsDir 'metrics.jsonl'
        }

        # Append metric to file (thread-safe)
        $mutex = $null
        try {
            $mutexName = 'Global/PhishIRMetricsMutex'
            $mutex = New-Object System.Threading.Mutex($false, $mutexName)
            $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(5))

            if ($acquired) {
                Add-Content -Path $metricsFile -Value $jsonLine -Encoding UTF8
                Write-Verbose "Metric recorded: $MetricName = $Value"
            } else {
                Write-Warning "Failed to acquire metrics file lock within timeout"
            }
        } finally {
            if ($mutex) {
                $mutex.ReleaseMutex() | Out-Null
                $mutex.Dispose()
            }
        }
    } catch {
        Write-Warning "Failed to record metric '$MetricName': $($_.Exception.Message)"
    }
}
