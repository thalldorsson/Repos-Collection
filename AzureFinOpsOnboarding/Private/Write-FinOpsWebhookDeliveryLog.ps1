<#
.SYNOPSIS
Writes webhook delivery audit log entries.

.DESCRIPTION
Creates structured JSON log entries for all webhook delivery attempts.
Logs are stored in rotating daily files with 90-day retention.
Each entry includes correlation ID for tracing operations.

.PARAMETER EndpointUrl
The webhook endpoint URL.

.PARAMETER HttpStatusCode
HTTP response status code (0 if no response).

.PARAMETER ResponseTimeMs
Time taken for the request in milliseconds.

.PARAMETER AttemptNumber
Which attempt this is (1 for first attempt, 2+ for retries).

.PARAMETER CorrelationId
Unique ID linking this log to the parent operation.

.PARAMETER Status
Status of this attempt: 'Success', 'Failed', 'Retrying', 'HealthCheckFailed', 'CircuitOpen', 'Error'.

.PARAMETER Error
Error message if failed.

.PARAMETER RetryDelay
Delay before next retry in seconds.

.PARAMETER CircuitState
Current state of circuit breaker ('Closed', 'Open', 'HalfOpen').

.OUTPUTS
[void]. Writes to log file and optionally Event Viewer.

.EXAMPLE
Write-FinOpsWebhookDeliveryLog -EndpointUrl "https://teams.microsoft.com/webhook/..." `
    -HttpStatusCode 200 -ResponseTimeMs 245 -AttemptNumber 1 `
    -CorrelationId "op-12345" -Status 'Success'

.NOTES
- Logs stored in: %APPDATA%\FinOps\Logs\WebhookDelivery\
- Files rotated daily with format: webhook-delivery-YYYY-MM-DD.json
- Old logs deleted after 90 days
- Each entry is valid JSON for easy parsing and querying
#>
function Write-FinOpsWebhookDeliveryLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EndpointUrl,

        [Parameter(Mandatory = $true)]
        [int]$HttpStatusCode,

        [Parameter(Mandatory = $true)]
        [int]$ResponseTimeMs,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 100)]
        [int]$AttemptNumber,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$CorrelationId,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Success', 'Failed', 'Retrying', 'HealthCheckFailed', 'CircuitOpen', 'Error')]
        [string]$Status,

        [Parameter(Mandatory = $false)]
        [string]$Error = $null,

        [Parameter(Mandatory = $false)]
        [int]$RetryDelay = 0,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Closed', 'Open', 'HalfOpen')]
        [string]$CircuitState = 'Closed'
    )

    try {
        # Get or create log directory
        $logDir = Join-Path -Path $env:APPDATA -ChildPath 'FinOps' | Join-Path -ChildPath 'Logs' | Join-Path -ChildPath 'WebhookDelivery'
        if (-not (Test-Path -Path $logDir)) {
            $null = New-Item -Path $logDir -ItemType Directory -Force
        }

        # Determine log file path (rotate daily)
        $logDate = Get-Date -Format 'yyyy-MM-dd'
        $logFile = Join-Path -Path $logDir -ChildPath "webhook-delivery-$logDate.jsonl"

        # Create log entry
        $logEntry = @{
            Timestamp        = Get-Date -Format 'o'  # ISO 8601 format
            CorrelationId    = $CorrelationId
            EndpointUrl      = $EndpointUrl
            EndpointHost     = ([System.Uri]$EndpointUrl).Host
            AttemptNumber    = $AttemptNumber
            Status           = $Status
            HttpStatusCode   = $HttpStatusCode
            ResponseTimeMs   = $ResponseTimeMs
            RetryDelay       = if ($RetryDelay -gt 0) { $RetryDelay } else { $null }
            CircuitState     = $CircuitState
            Error            = if (-not [string]::IsNullOrWhiteSpace($Error)) { $Error } else { $null }
            Source           = 'AzureFinOpsOnboarding'
        }

        # Convert to JSON and append to log file
        $jsonEntry = $logEntry | ConvertTo-Json -Compress
        Add-Content -Path $logFile -Value $jsonEntry -Encoding UTF8

        # Cleanup old logs (90-day retention)
        $retentionDays = 90
        $cutoffDate = (Get-Date).AddDays(-$retentionDays)
        Get-ChildItem -Path $logDir -Filter 'webhook-delivery-*.jsonl' | Where-Object {
            [datetime]::ParseExact($_.BaseName -replace 'webhook-delivery-', '', 'yyyy-MM-dd') -lt $cutoffDate
        } | Remove-Item -Force -ErrorAction SilentlyContinue

    }
    catch {
        Write-Warning "Failed to write webhook delivery log: $_"
        # Don't throw - logging failure shouldn't block webhook delivery
    }
}

# Function to query webhook delivery logs
function Get-FinOpsWebhookDeliveryLogEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$CorrelationId,

        [Parameter(Mandatory = $false)]
        [string]$EndpointUrl,

        [Parameter(Mandatory = $false)]
        [datetime]$StartDate,

        [Parameter(Mandatory = $false)]
        [datetime]$EndDate,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Success', 'Failed', 'Retrying', 'HealthCheckFailed', 'CircuitOpen', 'Error')]
        [string]$Status,

        [Parameter(Mandatory = $false)]
        [int]$MaxResults = 1000
    )

    $logDir = Join-Path -Path $env:APPDATA -ChildPath 'FinOps' | Join-Path -ChildPath 'Logs' | Join-Path -ChildPath 'WebhookDelivery'
    
    if (-not (Test-Path -Path $logDir)) {
        return @()
    }

    $entries = @()

    # Read all log files in date range
    Get-ChildItem -Path $logDir -Filter 'webhook-delivery-*.jsonl' | ForEach-Object {
        try {
            $fileDate = [datetime]::ParseExact($_.BaseName -replace 'webhook-delivery-', '', 'yyyy-MM-dd')
            
            if ($StartDate -and $fileDate -lt $StartDate) { return }
            if ($EndDate -and $fileDate -gt $EndDate) { return }

            Get-Content -Path $_.FullName | ForEach-Object {
                try {
                    $entry = $_ | ConvertFrom-Json
                    
                    # Apply filters
                    if ($CorrelationId -and $entry.CorrelationId -ne $CorrelationId) { return }
                    if ($EndpointUrl -and $entry.EndpointUrl -ne $EndpointUrl) { return }
                    if ($Status -and $entry.Status -ne $Status) { return }

                    $entries += $entry

                    if ($entries.Count -ge $MaxResults) {
                        return  # Break inner loop
                    }
                }
                catch {
                    Write-Verbose "Failed to parse log entry: $_"
                }
            }
        }
        catch {
            Write-Verbose "Failed to read log file: $_"
        }
    }

    return $entries | Select-Object -First $MaxResults
}
