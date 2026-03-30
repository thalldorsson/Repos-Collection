<#
.SYNOPSIS
Gets current webhook fallback queue status.

.DESCRIPTION
Returns detailed status of queued webhooks including count, oldest item, and retry eligibility.

.PARAMETER EndpointUrl
Optional filter by endpoint URL.

.PARAMETER IncludeDetails
If specified, returns detailed information about each queued webhook.

.OUTPUTS
[hashtable] with keys:
  - TotalQueued: Total number of items in queue
  - OldestQueuedAt: DateTime of oldest queued item
  - NewestQueuedAt: DateTime of newest queued item
  - ReadyForRetry: Number of items ready for retry (past NextRetryAt)
  - Details: Array of detailed queue items (if IncludeDetails specified)

.EXAMPLE
$status = Get-FinOpsWebhookQueueStatus
Write-Host "Queue contains $($status.TotalQueued) items"

$status = Get-FinOpsWebhookQueueStatus -IncludeDetails | Format-Table

.NOTES
- Queue stored in: %APPDATA%\FinOps\WebhookQueue\
- Each item in queue is independent JSON file
- Items auto-cleaned after 30 days retention
#>
function Get-FinOpsWebhookQueueStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$EndpointUrl,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeDetails
    )

    try {
        $queueDir = Join-Path -Path $env:APPDATA -ChildPath 'FinOps' | Join-Path -ChildPath 'WebhookQueue'
        
        if (-not (Test-Path -Path $queueDir)) {
            return @{
                TotalQueued    = 0
                OldestQueuedAt = $null
                NewestQueuedAt = $null
                ReadyForRetry  = 0
                Details        = @()
                QueuePath      = $queueDir
            }
        }

        $queued = Get-FinOpsWebhookQueue -EndpointUrl $EndpointUrl -OldestFirst
        $now = Get-Date
        $readyForRetry = 0

        if ($queued.Count -eq 0) {
            return @{
                TotalQueued    = 0
                OldestQueuedAt = $null
                NewestQueuedAt = $null
                ReadyForRetry  = 0
                Details        = @()
                QueuePath      = $queueDir
            }
        }

        # Count items ready for retry
        $queued | ForEach-Object {
            if ($_.NextRetryAt -le $now) {
                $readyForRetry++
            }
        }

        $result = @{
            TotalQueued    = $queued.Count
            OldestQueuedAt = $queued[0].QueuedAt
            NewestQueuedAt = $queued[-1].QueuedAt
            ReadyForRetry  = $readyForRetry
            QueuePath      = $queueDir
        }

        if ($IncludeDetails) {
            $result.Details = $queued | Select-Object -Property `
                QueueId, QueuedAt, WebhookUrl, EndpointHost, FailureReason, `
                Attempts, LastAttemptAt, NextRetryAt, `
                @{ Name = 'ReadyForRetry'; Expression = { $_.NextRetryAt -le $now } }
        }

        # Cleanup old items (30-day retention)
        $retentionDays = 30
        $cutoffDate = $now.AddDays(-$retentionDays)
        $queued | Where-Object { $_.QueuedAt -lt $cutoffDate } | ForEach-Object {
            Remove-FinOpsWebhookFromQueue -QueueId $_.QueueId -ErrorAction SilentlyContinue
        }

        return $result
    }
    catch {
        Write-Error "Failed to get webhook queue status: $_"
        return @{
            TotalQueued    = 0
            OldestQueuedAt = $null
            NewestQueuedAt = $null
            ReadyForRetry  = 0
            Details        = @()
            Error          = $_.Exception.Message
        }
    }
}
