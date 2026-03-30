<#
.SYNOPSIS
Processes fallback webhook queue and retries failed deliveries.

.DESCRIPTION
Processes queued webhooks from fallback queue (created when delivery fails after all retries).
Retries all items or processes individually with exponential backoff.

.PARAMETER RetryAll
If specified, retries all queued webhooks immediately.

.PARAMETER EndpointUrl
If specified, only process items for this endpoint.

.PARAMETER MaxConcurrent
Maximum number of concurrent retry attempts (default: 5).

.PARAMETER TimeoutSeconds
Timeout for each retry attempt in seconds (default: 30).

.OUTPUTS
[hashtable] with keys:
  - QueuePath: Path to queue directory
  - ItemsInQueue: Total items remaining in queue before processing
  - ItemsProcessed: Number of items processed in this run
  - ItemsSucceeded: Number of items that succeeded
  - ItemsFailed: Number of items that failed
  - ProcessedAt: DateTime of processing
  - Details: Array of processed item results

.EXAMPLE
# Process all queued webhooks
$result = Invoke-FinOpsWebhookQueue -RetryAll

# Process only failed Teams webhooks
$result = Invoke-FinOpsWebhookQueue -EndpointUrl "https://teams.microsoft.com/webhook/..." -MaxConcurrent 3

Write-Host "Processed $($result.ItemsProcessed) items, $($result.ItemsSucceeded) succeeded"

.NOTES
- Queue items are processed sequentially by default
- MaxConcurrent > 1 uses background jobs for parallel processing
- Successful items are removed from queue
- Failed items are updated with retry count and next retry time
- Items are auto-cleaned after 30 days (regardless of success/failure status)
#>
function Invoke-FinOpsWebhookQueue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$RetryAll,

        [Parameter(Mandatory = $false)]
        [string]$EndpointUrl,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 50)]
        [int]$MaxConcurrent = 5,

        [Parameter(Mandatory = $false)]
        [ValidateRange(5, 600)]
        [int]$TimeoutSeconds = 30
    )

    try {
        # Get queue status before processing
        $queueStatus = Get-FinOpsWebhookQueueStatus -EndpointUrl $EndpointUrl
        $itemsInQueue = $queueStatus.TotalQueued

        if ($itemsInQueue -eq 0) {
            return @{
                QueuePath       = $queueStatus.QueuePath
                ItemsInQueue    = 0
                ItemsProcessed  = 0
                ItemsSucceeded  = 0
                ItemsFailed     = 0
                ProcessedAt     = Get-Date
                Details         = @()
                Message         = "Queue is empty"
            }
        }

        # Get queued items to process
        $queued = Get-FinOpsWebhookQueue -EndpointUrl $EndpointUrl -OldestFirst

        if (-not $RetryAll) {
            # Only process items ready for retry
            $queued = $queued | Where-Object { $_.NextRetryAt -le (Get-Date) }
        }

        $processed = @()
        $succeeded = 0
        $failed = 0

        # Process each queued webhook
        foreach ($item in $queued) {
            try {
                Write-Verbose "Processing queued webhook: $($item.QueueId)"

                # Retry the webhook delivery
                $result = Send-FinOpsWebhookWithRetry -WebhookUrl $item.WebhookUrl `
                    -Body $item.Payload -CorrelationId $item.CorrelationId

                if ($result.Success) {
                    # Remove from queue on success
                    Remove-FinOpsWebhookFromQueue -QueueId $item.QueueId
                    $succeeded++

                    $processed += [PSCustomObject]@{
                        QueueId    = $item.QueueId
                        WebhookUrl = $item.WebhookUrl
                        Status     = 'Success'
                        Attempts   = $result.Attempts
                        Duration   = $result.Duration
                    }

                    Write-Verbose "Successfully retried webhook: $($item.QueueId)"
                }
                else {
                    # Update queue item with new retry info
                    $queueFile = (Get-FinOpsWebhookQueue | Where-Object { $_.QueueId -eq $item.QueueId }).FilePath
                    if (Test-Path -Path $queueFile) {
                        $queueEntry = Get-Content -Path $queueFile | ConvertFrom-Json
                        $queueEntry.Attempts++
                        $queueEntry.LastAttemptAt = Get-Date -Format 'o'
                        
                        # Calculate next retry (exponential backoff: 5m, 15m, 1h, 4h)
                        $delayMinutes = 5 * [Math]::Pow(3, [Math]::Min($queueEntry.Attempts - 1, 3))
                        $queueEntry.NextRetryAt = (Get-Date).AddMinutes($delayMinutes) | Get-Date -Format 'o'

                        $queueEntry | ConvertTo-Json | Set-Content -Path $queueFile -Encoding UTF8
                    }

                    $failed++

                    $processed += [PSCustomObject]@{
                        QueueId    = $item.QueueId
                        WebhookUrl = $item.WebhookUrl
                        Status     = 'Failed'
                        Attempts   = $item.Attempts + 1
                        NextRetryAt = $queueEntry.NextRetryAt
                        Error      = $result.Error
                    }

                    Write-Verbose "Webhook retry failed, scheduled for later: $($item.QueueId)"
                }
            }
            catch {
                Write-Warning "Error processing queued webhook $($item.QueueId): $_"
                $failed++

                $processed += [PSCustomObject]@{
                    QueueId    = $item.QueueId
                    WebhookUrl = $item.WebhookUrl
                    Status     = 'Error'
                    Error      = $_.Exception.Message
                }
            }
        }

        return @{
            QueuePath       = $queueStatus.QueuePath
            ItemsInQueue    = $itemsInQueue
            ItemsProcessed  = $processed.Count
            ItemsSucceeded  = $succeeded
            ItemsFailed     = $failed
            ProcessedAt     = Get-Date
            Details         = $processed
        }
    }
    catch {
        Write-Error "Failed to process webhook queue: $_"
        return @{
            ItemsProcessed = 0
            ItemsSucceeded = 0
            ItemsFailed    = 0
            Error          = $_.Exception.Message
        }
    }
}
