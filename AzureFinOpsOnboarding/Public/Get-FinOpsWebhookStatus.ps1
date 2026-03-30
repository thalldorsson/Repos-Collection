<#
.SYNOPSIS
Gets webhook delivery status and circuit breaker state.

.DESCRIPTION
Returns current circuit breaker state and delivery metrics for a webhook endpoint.

.PARAMETER WebhookUrl
The webhook endpoint to check status for.

.PARAMETER Detailed
If specified, includes delivery history from last 7 days.

.OUTPUTS
[hashtable] with keys:
  - EndpointUrl: The webhook URL
  - CircuitState: 'Closed' | 'Open' | 'HalfOpen'
  - FailureCount: Current failure count
  - LastFailure: DateTime of last failure (if any)
  - OpenedAt: DateTime when circuit opened (if Open/HalfOpen)
  - ShouldAttempt: [bool] True if webhooks will be sent to this endpoint
  - SuccessRate: Percentage of successful deliveries (last 24 hours)
  - TotalAttempts: Total delivery attempts (last 24 hours)
  - SuccessfulDeliveries: Count of successful deliveries (last 24 hours)

.EXAMPLE
Get-FinOpsWebhookStatus -WebhookUrl "https://teams.microsoft.com/webhook/..."

.NOTES
- Queries circuit breaker state in memory
- Queries delivery logs for success metrics
- Returns real-time status
#>
function Get-FinOpsWebhookStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$WebhookUrl,

        [Parameter(Mandatory = $false)]
        [switch]$Detailed
    )

    # Get circuit breaker status
    $circuitStatus = Invoke-FinOpsCircuitBreaker -EndpointId (Get-WebhookEndpointId -Url $WebhookUrl) -TestOnly

    # Get delivery metrics from logs (last 24 hours)
    $cutoffTime = (Get-Date).AddHours(-24)
    $logs = Get-FinOpsWebhookDeliveryLogEntry -EndpointUrl $WebhookUrl -StartDate $cutoffTime

    $successful = @($logs | Where-Object { $_.Status -eq 'Success' }).Count
    $total = @($logs | Where-Object { $_.Status -in @('Success', 'Failed') }).Count
    $successRate = if ($total -gt 0) { [math]::Round(($successful / $total) * 100, 2) } else { 0 }

    $result = @{
        EndpointUrl          = $WebhookUrl
        EndpointHost         = ([System.Uri]$WebhookUrl).Host
        CircuitState         = $circuitStatus.State
        FailureCount         = $circuitStatus.FailureCount
        LastFailure          = $circuitStatus.LastFailure
        OpenedAt             = $circuitStatus.OpenedAt
        ShouldAttempt        = $circuitStatus.ShouldAttempt
        SuccessRate          = $successRate
        TotalAttempts        = $total
        SuccessfulDeliveries = $successful
        MetricsWindowHours   = 24
    }

    if ($Detailed) {
        $result.RecentAttempts = $logs | Select-Object -Last 10 | Select-Object -Property `
            Timestamp, Status, AttemptNumber, HttpStatusCode, ResponseTimeMs, CorrelationId
    }

    return $result
}
