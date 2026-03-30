function Invoke-FinOpsRestMethodWithRetry {
    <#
    .SYNOPSIS
        Invokes a REST method with automatic retry logic for transient failures.
    
    .DESCRIPTION
        Wraps Invoke-RestMethod with intelligent retry logic to handle transient failures
        such as rate limiting (429), service unavailable (503), and network timeouts.
        
        Supports multiple retry strategies:
        - Exponential: 2^attempt * base (default: 2s, 4s, 8s, 16s...)
        - Linear: attempt * base (2s, 4s, 6s, 8s...)
        - Fibonacci: Fibonacci sequence * base (2s, 2s, 4s, 6s, 10s...)
        
        Automatically respects Retry-After headers (both seconds and HTTP date formats).
        Tracks rate limit headers (X-RateLimit-Remaining, X-RateLimit-Reset) for preemptive throttling.
    
    .PARAMETER Uri
        The URI for the REST API endpoint.
    
    .PARAMETER Method
        HTTP method (GET, POST, PUT, DELETE, PATCH).
    
    .PARAMETER Headers
        Optional headers hashtable.
    
    .PARAMETER Body
        Optional request body (string or object).
    
    .PARAMETER ContentType
        Optional content type (e.g., 'application/json').
    
    .PARAMETER MaxRetries
        Maximum number of retry attempts. Default is 3.
    
    .PARAMETER InitialDelaySeconds
        Initial delay in seconds before first retry. Default is 2.
    
    .PARAMETER TimeoutSec
        Request timeout in seconds. Default is 100.
    
    .PARAMETER RateLimitStrategy
        Retry delay strategy: Exponential, Linear, or Fibonacci. Default is Exponential.
    
    .PARAMETER MaxDelaySeconds
        Maximum delay between retries in seconds. Default is 60. Caps calculated delays.
    
    .PARAMETER RespectRateLimitHeaders
        If true, checks X-RateLimit-Remaining and preemptively delays when low. Default is true.
    
    .EXAMPLE
        $result = Invoke-FinOpsRestMethodWithRetry -Uri $apiUrl -Method Get -Headers $headers -MaxRetries 3
    
    .EXAMPLE
        # Linear backoff for APIs with predictable rate limits
        $result = Invoke-FinOpsRestMethodWithRetry -Uri $url -Method Post -Body $body -RateLimitStrategy Linear
    
    .EXAMPLE
        # Respect rate limit headers for preemptive throttling
        $result = Invoke-FinOpsRestMethodWithRetry -Uri $url -Method Get -Headers $headers -RespectRateLimitHeaders
    
    .OUTPUTS
        Object returned from the REST API call.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        
        [Parameter(Mandatory = $true)]
        [ValidateSet('Get', 'Post', 'Put', 'Delete', 'Patch')]
        [string]$Method,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$Headers,
        
        [Parameter(Mandatory = $false)]
        [object]$Body,
        
        [Parameter(Mandatory = $false)]
        [string]$ContentType,
        
        [Parameter(Mandatory = $false)]
        [int]$MaxRetries = 3,
        
        [Parameter(Mandatory = $false)]
        [int]$InitialDelaySeconds = 2,
        
        [Parameter(Mandatory = $false)]
        [int]$TimeoutSec = 100,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('Exponential', 'Linear', 'Fibonacci')]
        [string]$RateLimitStrategy = 'Exponential',
        
        [Parameter(Mandatory = $false)]
        [int]$MaxDelaySeconds = 60,
        
        [Parameter(Mandatory = $false)]
        [switch]$RespectRateLimitHeaders = $true
    )
    
    $attempt = 0
    $lastException = $null
    $fibonacci = @(1, 1)  # For Fibonacci strategy
    
    while ($attempt -le $MaxRetries) {
        try {
            Write-FinOpsLog -Level 'Debug' -Message "REST call attempt" -Context @{
                Attempt = $attempt + 1
                MaxAttempts = $MaxRetries + 1
                Method = $Method
                Uri = $Uri
            } -Category 'API'
            
            $params = @{
                Uri        = $Uri
                Method     = $Method
                TimeoutSec = $TimeoutSec
                ErrorAction = 'Stop'
            }
            
            if ($Headers) { $params.Headers = $Headers }
            if ($Body) { $params.Body = $Body }
            if ($ContentType) { $params.ContentType = $ContentType }
            
            # Add correlation ID if logging is enabled
            if ($script:FinOpsLogSettings -and $script:FinOpsLogSettings.CorrelationId) {
                if (-not $params.Headers) { $params.Headers = @{} }
                $params.Headers['X-Correlation-ID'] = $script:FinOpsLogSettings.CorrelationId
            }
            
            # PowerShell 7+ supports -ResponseHeadersVariable, PowerShell 5.1 does not
            if ($PSVersionTable.PSVersion.Major -ge 7) {
                $response = Invoke-RestMethod @params -ResponseHeadersVariable responseHeaders
                
                # Check rate limit headers for preemptive throttling
                if ($RespectRateLimitHeaders -and $responseHeaders) {
                    $rateLimitRemaining = $responseHeaders['X-RateLimit-Remaining']
                    $rateLimitReset = $responseHeaders['X-RateLimit-Reset']
                    
                    if ($rateLimitRemaining) {
                        $remaining = [int]$rateLimitRemaining
                        
                        Write-FinOpsLog -Level 'Debug' -Message "Rate limit status" -Context @{
                            Remaining = $remaining
                            Reset = $rateLimitReset
                            Uri = $Uri
                        } -Category 'RateLimit'
                        
                        # Preemptive delay if very low
                        if ($remaining -le 5) {
                            $preemptiveDelay = 2
                            Write-FinOpsLog -Level 'Warning' -Message "Rate limit low, preemptive delay" -Context @{
                                Remaining = $remaining
                                Delay = $preemptiveDelay
                            } -Category 'RateLimit'
                            Start-Sleep -Seconds $preemptiveDelay
                        }
                    }
                }
            }
            else {
                # PowerShell 5.1 fallback - no response headers available
                $response = Invoke-RestMethod @params
            }
            
            if ($attempt -gt 0) {
                Write-FinOpsLog -Level 'Info' -Message "REST call succeeded after retries" -Context @{
                    Attempts = $attempt
                    Method = $Method
                    Uri = $Uri
                } -Category 'API'
            }
            
            return $response
            
        } catch {
            $lastException = $_
            $attempt++
            
            # Check if error is retryable
            $isRetryable = $false
            $statusCode = $null
            $retryAfterSeconds = $null
            
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
                
                Write-FinOpsLog -Level 'Warning' -Message "REST call failed" -Context @{
                    StatusCode = $statusCode
                    Method = $Method
                    Uri = $Uri
                    Attempt = $attempt
                    Error = $_.Exception.Message
                } -Category 'API' -Exception $_.Exception
                
                # Retryable status codes: 429 (Too Many Requests), 503 (Service Unavailable), 504 (Gateway Timeout), 408 (Request Timeout)
                if ($statusCode -in @(408, 429, 503, 504)) {
                    $isRetryable = $true
                    
                    # Parse Retry-After header
                    if ($_.Exception.Response.Headers) {
                        $retryAfterHeader = $_.Exception.Response.Headers['Retry-After']
                        
                        if ($retryAfterHeader) {
                            # Try parsing as seconds (integer)
                            if ([int]::TryParse($retryAfterHeader, [ref]$null)) {
                                $retryAfterSeconds = [int]$retryAfterHeader
                            }
                            # Try parsing as HTTP date
                            elseif ([datetime]::TryParse($retryAfterHeader, [ref]$null)) {
                                $retryAfterDate = [datetime]::Parse($retryAfterHeader)
                                $retryAfterSeconds = [Math]::Max(0, ($retryAfterDate - (Get-Date)).TotalSeconds)
                            }
                            
                            if ($retryAfterSeconds) {
                                Write-FinOpsLog -Level 'Info' -Message "Retry-After header detected" -Context @{
                                    RetryAfter = $retryAfterSeconds
                                    StatusCode = $statusCode
                                } -Category 'RateLimit'
                            }
                        }
                    }
                }
            } elseif ($_.Exception.Message -match 'timeout|timed out|connection|network') {
                Write-FinOpsLog -Level 'Warning' -Message "REST call failed with network error" -Context @{
                    Method = $Method
                    Uri = $Uri
                    Attempt = $attempt
                    Error = $_.Exception.Message
                } -Category 'API' -Exception $_.Exception
                $isRetryable = $true
            }
            
            # If not retryable or max retries exceeded, throw
            if (-not $isRetryable -or $attempt -gt $MaxRetries) {
                if (-not $isRetryable) {
                    Write-FinOpsLog -Level 'Error' -Message "Error is not retryable" -Context @{
                        StatusCode = $statusCode
                        Error = $_.Exception.Message
                    } -Category 'API'
                } else {
                    Write-FinOpsLog -Level 'Error' -Message "Max retries exceeded" -Context @{
                        MaxRetries = $MaxRetries
                        Attempt = $attempt
                    } -Category 'API'
                }
                throw $lastException
            }
            
            # Calculate delay based on strategy
            $baseDelay = $InitialDelaySeconds
            $calculatedDelay = switch ($RateLimitStrategy) {
                'Exponential' {
                    $baseDelay * [Math]::Pow(2, $attempt - 1)
                }
                'Linear' {
                    $baseDelay * $attempt
                }
                'Fibonacci' {
                    if ($attempt -ge $fibonacci.Count) {
                        $fibonacci += $fibonacci[-1] + $fibonacci[-2]
                    }
                    $baseDelay * $fibonacci[$attempt - 1]
                }
            }
            
            # Cap at MaxDelaySeconds
            $calculatedDelay = [Math]::Min($calculatedDelay, $MaxDelaySeconds)
            
            # Use Retry-After if provided and greater
            $delay = if ($retryAfterSeconds) {
                [Math]::Max($calculatedDelay, $retryAfterSeconds)
            } else {
                $calculatedDelay
            }
            
            # Add jitter (random ±10%) to prevent thundering herd
            $jitter = $delay * 0.1 * ((Get-Random -Minimum -10 -Maximum 10) / 10)
            $delay = [Math]::Max(1, $delay + $jitter)
            
            Write-FinOpsLog -Level 'Warning' -Message "Retrying after delay" -Context @{
                Attempt = $attempt
                MaxRetries = $MaxRetries
                Strategy = $RateLimitStrategy
                Delay = [Math]::Round($delay, 2)
                RetryAfterHeader = $retryAfterSeconds
                StatusCode = $statusCode
            } -Category 'API'
            
            Start-Sleep -Seconds $delay
        }
    }
    
    # Should not reach here, but throw last exception if we do
    throw $lastException
}
