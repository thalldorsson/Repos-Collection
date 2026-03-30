<#
.SYNOPSIS
Adds failed webhook to fallback queue for manual retry.

.DESCRIPTION
Persists webhook payload to local queue when delivery fails after all retries.
Queue is durable across PowerShell session restarts and can be processed on-demand.

.PARAMETER WebhookUrl
The target webhook URL.

.PARAMETER Payload
The webhook payload (JSON string).

.PARAMETER FailureReason
Why the webhook was queued (e.g., "Failed after 5 attempts", "Circuit breaker open").

.PARAMETER CorrelationId
Optional correlation ID for tracing.

.OUTPUTS
[hashtable] with keys:
  - QueueId: Unique ID for queued webhook
  - QueuedAt: DateTime when added to queue
  - QueuePath: Path to queue file
  - FailureReason: Reason webhook was queued

.EXAMPLE
Add-FinOpsWebhookToQueue -WebhookUrl "https://teams.microsoft.com/webhook/..." `
    -Payload $jsonPayload -FailureReason "Failed after 5 attempts"

.NOTES
- Queue location: %APPDATA%\FinOps\WebhookQueue\
- Each webhook stored in separate JSON file with UUID name
- Queue items cleaned up after 30 days retention
- Fallback queue is persistent across sessions
#>
function Add-FinOpsWebhookToQueue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$WebhookUrl,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        $Payload,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$FailureReason,

        [Parameter(Mandatory = $false)]
        [string]$CorrelationId = [guid]::NewGuid().ToString()
    )

    try {
        # Get or create queue directory
        $queueDir = Join-Path -Path $env:APPDATA -ChildPath 'FinOps' | Join-Path -ChildPath 'WebhookQueue'
        if (-not (Test-Path -Path $queueDir)) {
            $null = New-Item -Path $queueDir -ItemType Directory -Force
        }

        # Convert payload to string if needed
        if ($Payload -isnot [string]) {
            $payloadStr = $Payload | ConvertTo-Json -Depth 10 -Compress
        }
        else {
            $payloadStr = $Payload
        }

        # Create queue entry
        $queueId = [guid]::NewGuid().ToString()
        $queueEntry = @{
            QueueId        = $queueId
            QueuedAt       = Get-Date -Format 'o'
            WebhookUrl     = $WebhookUrl
            EndpointHost   = ([System.Uri]$WebhookUrl).Host
            Payload        = $payloadStr
            FailureReason  = $FailureReason
            CorrelationId  = $CorrelationId
            Attempts       = 0  # Track retry attempts from queue
            LastAttemptAt  = $null
            NextRetryAt    = Get-Date -Format 'o'  # Immediate first retry
        }

        # Write queue entry to file (JSON format)
        $queueFile = Join-Path -Path $queueDir -ChildPath "$queueId.json"
        $queueEntry | ConvertTo-Json | Set-Content -Path $queueFile -Encoding UTF8

        # Log queue addition
        Write-FinOpsWebhookDeliveryLog -EndpointUrl $WebhookUrl -HttpStatusCode 0 -ResponseTimeMs 0 `
            -AttemptNumber 0 -CorrelationId $CorrelationId -Status 'Queued' -Error $FailureReason

        Write-Verbose "Webhook added to fallback queue: $queueId"

        return @{
            QueueId        = $queueId
            QueuedAt       = $queueEntry.QueuedAt
            QueuePath      = $queueFile
            FailureReason  = $FailureReason
            EndpointUrl    = $WebhookUrl
        }
    }
    catch {
        Write-Warning "Failed to add webhook to queue: $_"
        return @{
            Success = $false
            Error   = $_.Exception.Message
        }
    }
}

# Helper function to list queued webhooks
function Get-FinOpsWebhookQueue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$EndpointUrl,

        [Parameter(Mandatory = $false)]
        [string]$CorrelationId,

        [Parameter(Mandatory = $false)]
        [switch]$OldestFirst
    )

    $queueDir = Join-Path -Path $env:APPDATA -ChildPath 'FinOps' | Join-Path -ChildPath 'WebhookQueue'
    
    if (-not (Test-Path -Path $queueDir)) {
        return @()
    }

    $queued = @()

    Get-ChildItem -Path $queueDir -Filter '*.json' | ForEach-Object {
        try {
            $entry = Get-Content -Path $_.FullName | ConvertFrom-Json

            # Apply filters
            if ($EndpointUrl -and $entry.WebhookUrl -ne $EndpointUrl) { return }
            if ($CorrelationId -and $entry.CorrelationId -ne $CorrelationId) { return }

            $queued += [PSCustomObject]@{
                QueueId       = $entry.QueueId
                QueuedAt      = [datetime]::Parse($entry.QueuedAt)
                WebhookUrl    = $entry.WebhookUrl
                EndpointHost  = $entry.EndpointHost
                FailureReason = $entry.FailureReason
                CorrelationId = $entry.CorrelationId
                Attempts      = $entry.Attempts
                LastAttemptAt = if ($entry.LastAttemptAt) { [datetime]::Parse($entry.LastAttemptAt) } else { $null }
                NextRetryAt   = [datetime]::Parse($entry.NextRetryAt)
                FilePath      = $_.FullName
            }
        }
        catch {
            Write-Verbose "Failed to parse queued webhook: $_"
        }
    }

    if ($OldestFirst) {
        return $queued | Sort-Object -Property 'QueuedAt'
    }
    else {
        return $queued | Sort-Object -Property 'QueuedAt' -Descending
    }
}

# Helper function to remove item from queue
function Remove-FinOpsWebhookFromQueue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$QueueId
    )

    $queueDir = Join-Path -Path $env:APPDATA -ChildPath 'FinOps' | Join-Path -ChildPath 'WebhookQueue'
    $queueFile = Join-Path -Path $queueDir -ChildPath "$QueueId.json"

    if (Test-Path -Path $queueFile) {
        Remove-Item -Path $queueFile -Force
        return $true
    }

    return $false
}
