<#
.SYNOPSIS
Gets webhook delivery audit log entries.

.DESCRIPTION
Queries webhook delivery logs with flexible filtering options.
Useful for troubleshooting webhook delivery issues and compliance auditing.

.PARAMETER CorrelationId
Filter by correlation ID (links all operations in a single workflow).

.PARAMETER EndpointUrl
Filter by webhook URL.

.PARAMETER StartDate
Filter by start date (inclusive).

.PARAMETER EndDate
Filter by end date (inclusive).

.PARAMETER Status
Filter by delivery status: 'Success', 'Failed', 'Retrying', 'HealthCheckFailed', 'CircuitOpen', 'Error'.

.PARAMETER MaxResults
Maximum number of log entries to return (default: 1000).

.OUTPUTS
[array] of log entries with properties:
  - Timestamp: When the delivery attempt occurred
  - CorrelationId: Unique operation ID
  - EndpointUrl: Webhook URL
  - EndpointHost: Hostname from URL
  - AttemptNumber: Which attempt (1, 2, 3...)
  - Status: Delivery status
  - HttpStatusCode: Response code (0 if no response)
  - ResponseTimeMs: Time taken in milliseconds
  - CircuitState: Circuit breaker state at time of attempt
  - Error: Error message if failed

.EXAMPLE
# Get all failed deliveries in last 7 days
$failed = Get-FinOpsWebhookDeliveryLog -Status 'Failed' -StartDate (Get-Date).AddDays(-7)

# Get all attempts for specific operation
$opLogs = Get-FinOpsWebhookDeliveryLog -CorrelationId "op-12345"

# Get Team webhook history
$teamLogs = Get-FinOpsWebhookDeliveryLog -EndpointUrl "https://teams.microsoft.com/webhook/..."

.NOTES
- Logs stored in: %APPDATA%\FinOps\Logs\WebhookDelivery\
- Files rotated daily
- Retention period: 90 days
- Each log entry is in JSONL format (one JSON object per line)
#>
function Get-FinOpsWebhookDeliveryLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$CorrelationId,

        [Parameter(Mandatory = $false)]
        [string]$EndpointUrl,

        [Parameter(Mandatory = $false)]
        [datetime]$StartDate,

        [Parameter(Mandatory = $false)]
        [datetime]$EndDate = (Get-Date),

        [Parameter(Mandatory = $false)]
        [ValidateSet('Success', 'Failed', 'Retrying', 'HealthCheckFailed', 'CircuitOpen', 'Error')]
        [string]$Status,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 10000)]
        [int]$MaxResults = 1000
    )

    Get-FinOpsWebhookDeliveryLogEntry -CorrelationId $CorrelationId -EndpointUrl $EndpointUrl `
        -StartDate $StartDate -EndDate $EndDate -Status $Status -MaxResults $MaxResults
}
