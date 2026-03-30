<#
.SYNOPSIS
Sends webhook with automatic retry logic and exponential backoff.

.DESCRIPTION
Implements resilient webhook delivery with:
- Automatic retry on transient failures (5xx, timeouts)
- Exponential backoff delays (2s, 8s, 32s, 128s)
- Pre-delivery health checks
- Circuit breaker integration
- Comprehensive audit logging with correlation ID

.PARAMETER WebhookUrl
The target webhook URL.

.PARAMETER Body
The payload to send (string or object, will be converted to JSON if needed).

.PARAMETER Method
HTTP method (default: 'POST').

.PARAMETER Headers
Optional headers to include in request.

.PARAMETER CorrelationId
Unique ID for tracking operation across all retry attempts.

.PARAMETER Config
Configuration hashtable with retry parameters.

.OUTPUTS
[hashtable] with keys:
  - Success: [bool] True if delivery successful
  - Attempts: [int] Number of attempts made
  - FinalStatusCode: [int] HTTP status code of last attempt
  - FinalResponse: [object] Response from last attempt
  - Error: [string] Error message if failed
  - Duration: [int] Total time in milliseconds

.EXAMPLE
$payload = @{ message = "Customer onboarded"; customerId = "CUST001" } | ConvertTo-Json
$result = Send-FinOpsWebhookWithRetry -WebhookUrl $url -Body $payload -CorrelationId "op-12345"

.NOTES
- Uses health check to validate endpoint before first delivery
- Retries only transient failures (5xx, timeout, connection errors)
- Does NOT retry client errors (4xx except 429 rate limiting)
- Logs all attempts with correlation ID for audit trail
- Falls back to queue if all retries exhausted
#>
function Send-FinOpsWebhookWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$WebhookUrl,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        $Body,

        [Parameter(Mandatory = $false)]
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')]
        [string]$Method = 'POST',

        [Parameter(Mandatory = $false)]
        [hashtable]$Headers = @{},

        [Parameter(Mandatory = $false)]
        [string]$CorrelationId = [guid]::NewGuid().ToString(),

        [Parameter(Mandatory = $false)]
        [hashtable]$Config = $null
    )

    # Load config if not provided
    if (-not $Config) {
        $fullConfig = Get-FinOpsWebhookConfig
        $Config = @{
            MaxRetries                    = $fullConfig.WebhookRetry.MaxRetries
            InitialRetryDelaySeconds      = $fullConfig.WebhookRetry.InitialRetryDelaySeconds
            BackoffMultiplier             = $fullConfig.WebhookRetry.BackoffMultiplier
            HealthCheckTimeoutSeconds     = $fullConfig.WebhookRetry.HealthCheckTimeoutSeconds
            CircuitBreakerFailureThreshold = $fullConfig.CircuitBreaker.FailureThreshold
            CircuitBreakerResetSeconds    = $fullConfig.CircuitBreaker.ResetSeconds
        }
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $attemptCount = 0
    $lastStatusCode = 0
    $lastResponse = $null
    $lastError = $null
    $maxAttempts = $Config.MaxRetries + 1

    # Convert body to JSON if it's not already a string
    if ($Body -isnot [string]) {
        $bodyStr = $Body | ConvertTo-Json -Depth 10 -Compress
    }
    else {
        $bodyStr = $Body
    }

    # Ensure Content-Type is set
    if (-not $Headers.ContainsKey('Content-Type')) {
        $Headers['Content-Type'] = 'application/json'
    }

    # Add correlation ID to headers for tracing
    $Headers['X-Correlation-Id'] = $CorrelationId

    try {
        # Step 1: Check circuit breaker
        $circuitStatus = Invoke-FinOpsCircuitBreaker -EndpointId (Get-WebhookEndpointId -Url $WebhookUrl) -TestOnly
        if ($circuitStatus.State -eq 'Open') {
            Write-FinOpsWebhookDeliveryLog -EndpointUrl $WebhookUrl -HttpStatusCode 0 -ResponseTimeMs 0 -AttemptNumber 1 `
                -CorrelationId $CorrelationId -Status 'CircuitOpen' -CircuitState 'Open'
            
            # Add to fallback queue
            Add-FinOpsWebhookToQueue -WebhookUrl $WebhookUrl -Payload $bodyStr -FailureReason 'Circuit breaker open'
            
            return @{
                Success          = $false
                Attempts         = 0
                FinalStatusCode  = 0
                FinalResponse    = $null
                Error            = "Circuit breaker is open for endpoint. Webhook queued for retry."
                Duration         = $stopwatch.ElapsedMilliseconds
                CircuitState     = 'Open'
            }
        }

        # Step 2: Health check before delivery
        $healthCheck = Invoke-FinOpsWebhookHealthCheck -WebhookUrl $WebhookUrl -TimeoutSeconds $Config.HealthCheckTimeoutSeconds
        if (-not $healthCheck.IsHealthy) {
            Write-FinOpsWebhookDeliveryLog -EndpointUrl $WebhookUrl -HttpStatusCode $healthCheck.StatusCode -ResponseTimeMs $healthCheck.ResponseTimeMs `
                -AttemptNumber 1 -CorrelationId $CorrelationId -Status 'HealthCheckFailed' -Error $healthCheck.Error
            
            Add-FinOpsWebhookToQueue -WebhookUrl $WebhookUrl -Payload $bodyStr -FailureReason "Health check failed: $($healthCheck.Error)"
            
            return @{
                Success          = $false
                Attempts         = 1
                FinalStatusCode  = $healthCheck.StatusCode
                FinalResponse    = $null
                Error            = "Health check failed: $($healthCheck.Error)"
                Duration         = $stopwatch.ElapsedMilliseconds
                HealthCheckFailed = $true
            }
        }

        # Step 3: Attempt delivery with retries
        for ($attemptCount = 1; $attemptCount -le $maxAttempts; $attemptCount++) {
            $attemptStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

            try {
                $params = @{
                    Uri             = $WebhookUrl
                    Method          = $Method
                    Body            = $bodyStr
                    Headers         = $Headers
                    TimeoutSec      = 30
                    ErrorAction     = 'Stop'
                }

                $lastResponse = Invoke-RestMethod @params
                $lastStatusCode = 200  # Invoke-RestMethod doesn't throw on 2xx

                Write-FinOpsWebhookDeliveryLog -EndpointUrl $WebhookUrl -HttpStatusCode 200 -ResponseTimeMs $attemptStopwatch.ElapsedMilliseconds `
                    -AttemptNumber $attemptCount -CorrelationId $CorrelationId -Status 'Success'

                $stopwatch.Stop()
                return @{
                    Success          = $true
                    Attempts         = $attemptCount
                    FinalStatusCode  = 200
                    FinalResponse    = $lastResponse
                    Error            = $null
                    Duration         = $stopwatch.ElapsedMilliseconds
                }
            }
            catch [System.Net.Http.HttpRequestException], [System.Net.WebException] {
                $attemptStopwatch.Stop()
                $statusCode = 0
                $errorMsg = $_.Exception.Message

                if ($_.Exception.Response) {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                    $lastStatusCode = $statusCode
                }

                $isTransientFailure = $statusCode -ge 500 -or $statusCode -eq 0 -or $statusCode -eq 429

                # Log the attempt
                Write-FinOpsWebhookDeliveryLog -EndpointUrl $WebhookUrl -HttpStatusCode $statusCode -ResponseTimeMs $attemptStopwatch.ElapsedMilliseconds `
                    -AttemptNumber $attemptCount -CorrelationId $CorrelationId -Status 'Failed' -Error $errorMsg

                if ($isTransientFailure -and $attemptCount -lt $maxAttempts) {
                    # Calculate exponential backoff delay
                    $delaySeconds = $Config.InitialRetryDelaySeconds * [Math]::Pow($Config.BackoffMultiplier, $attemptCount - 1)
                    Write-FinOpsWebhookDeliveryLog -EndpointUrl $WebhookUrl -HttpStatusCode $statusCode -ResponseTimeMs 0 `
                        -AttemptNumber $attemptCount -CorrelationId $CorrelationId -Status 'Retrying' -RetryDelay $delaySeconds

                    Start-Sleep -Seconds $delaySeconds
                }
                else {
                    # Permanent failure or max retries reached
                    $lastError = $errorMsg
                    $lastStatusCode = $statusCode
                    break
                }
            }
            catch {
                $attemptStopwatch.Stop()
                $lastError = $_.Exception.Message

                Write-FinOpsWebhookDeliveryLog -EndpointUrl $WebhookUrl -HttpStatusCode 0 -ResponseTimeMs $attemptStopwatch.ElapsedMilliseconds `
                    -AttemptNumber $attemptCount -CorrelationId $CorrelationId -Status 'Error' -Error $lastError

                break
            }
        }

        # If we got here, all retries failed - add to fallback queue
        Add-FinOpsWebhookToQueue -WebhookUrl $WebhookUrl -Payload $bodyStr -FailureReason "Failed after $($attemptCount) attempts: $lastError"

        # Update circuit breaker failure count
        $endpointId = Get-WebhookEndpointId -Url $WebhookUrl
        if (-not $script:FinOpsCircuitBreakerState) {
            $script:FinOpsCircuitBreakerState = @{}
        }
        if (-not $script:FinOpsCircuitBreakerState.ContainsKey($endpointId)) {
            $script:FinOpsCircuitBreakerState[$endpointId] = @{
                FailureCount = 0
                State        = 'Closed'
                LastFailure  = $null
                OpenedAt     = $null
            }
        }
        $script:FinOpsCircuitBreakerState[$endpointId].FailureCount++
        $script:FinOpsCircuitBreakerState[$endpointId].LastFailure = Get-Date

        return @{
            Success          = $false
            Attempts         = $attemptCount
            FinalStatusCode  = $lastStatusCode
            FinalResponse    = $lastResponse
            Error            = "Failed after $($attemptCount) attempts: $lastError"
            Duration         = $stopwatch.ElapsedMilliseconds
            Queued           = $true
        }
    }
    finally {
        if ($stopwatch.IsRunning) {
            $stopwatch.Stop()
        }
    }
}

# Helper function to generate consistent endpoint ID
function Get-WebhookEndpointId {
    param([string]$Url)
    $uri = [System.Uri]$Url
    return "$($uri.Scheme)://$($uri.Host)$($uri.AbsolutePath)" -replace '\?.*$', ''
}
