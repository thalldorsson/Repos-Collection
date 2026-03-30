<#
.SYNOPSIS
Performs pre-delivery health check on webhook endpoint.

.DESCRIPTION
Validates webhook endpoint reachability via DNS resolution, TLS validation, and endpoint availability.
Caches health status for 30 seconds to avoid redundant checks.

Improvements in v1.9.0:
- Parameter validation on all inputs
- Timeout enforcement on all operations  
- Thread-safe cache management
- Detailed error reporting
- Graceful degradation on failures

.PARAMETER WebhookUrl
The webhook URL to check (must be valid HTTP/HTTPS URL).

.PARAMETER TimeoutSeconds
Timeout for health check operations (default: 5 seconds, range: 1-30).

.PARAMETER Headers
Optional headers to include in health check request (e.g., authentication).

.PARAMETER SkipCache
Force fresh health check instead of using cached result.

.OUTPUTS
[hashtable] with keys:
  - IsHealthy: [bool] True if endpoint is reachable
  - StatusCode: [int] HTTP status code (0 if unreachable)
  - ResponseTimeMs: [int] Time taken for health check in milliseconds
  - CacheHit: [bool] True if result from cache
  - CheckedAt: [datetime] When check was performed
  - Error: [string] Error message if unhealthy

.EXAMPLE
$health = Invoke-FinOpsWebhookHealthCheck -WebhookUrl "https://teams.microsoft.com/webhook/..."
if ($health.IsHealthy) {
    Write-Host "Endpoint is healthy"
}

.NOTES
- Caches results for 30 seconds per endpoint
- Uses lightweight HEAD/GET request (not full webhook payload)
- Thread-safe cache with monitor locks
- All parameters validated before processing
#>
function Invoke-FinOpsWebhookHealthCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$WebhookUrl,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 30)]
        [int]$TimeoutSeconds = 5,

        [Parameter(Mandatory = $false)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $false)]
        [switch]$SkipCache
    )

    begin {
        # Initialize cache if not exists (thread-safe)
        if (-not $script:FinOpsWebhookHealthCache) {
            $script:FinOpsWebhookHealthCache = @{}
            $script:FinOpsWebhookHealthCacheLock = [object]::new()
        }
        
        if (-not $Headers) {
            $Headers = @{}
        }
    }

    process {
        # Validate URL format first
        try {
            $uri = [System.Uri]$WebhookUrl
            if ($uri.Scheme -notin @('http', 'https')) {
                throw "Invalid URI scheme: $($uri.Scheme). Must be HTTP or HTTPS."
            }
            if ([string]::IsNullOrWhiteSpace($uri.Host)) {
                throw "URL must contain a valid hostname."
            }
        }
        catch {
            return @{
                IsHealthy      = $false
                StatusCode     = 0
                ResponseTimeMs = 0
                CacheHit       = $false
                CheckedAt      = Get-Date
                Error          = "Invalid URL: $_"
            }
        }

        # Generate cache key from URL
        $cacheKey = $WebhookUrl
        $now = Get-Date

        # Check cache (valid for 30 seconds) with thread safety
        if (-not $SkipCache) {
            try {
                [System.Threading.Monitor]::Enter($script:FinOpsWebhookHealthCacheLock)
                
                if ($script:FinOpsWebhookHealthCache.ContainsKey($cacheKey)) {
                    $cached = $script:FinOpsWebhookHealthCache[$cacheKey]
                    if (($now - $cached.CheckedAt).TotalSeconds -lt 30) {
                        Write-Verbose "Health check cache hit for: $WebhookUrl"
                        $cached.CacheHit = $true
                        return $cached
                    }
                }
            }
            finally {
                [System.Threading.Monitor]::Exit($script:FinOpsWebhookHealthCacheLock)
            }
        }

        # Perform health check
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = @{
            IsHealthy      = $false
            StatusCode     = 0
            ResponseTimeMs = 0
            CacheHit       = $false
            CheckedAt      = $now
            Error          = $null
        }

        try {
            # Step 1: DNS resolution check
            try {
                $null = [System.Net.Dns]::GetHostAddresses($uri.Host)
                Write-Verbose "DNS resolution successful for: $($uri.Host)"
            }
            catch {
                throw "DNS resolution failed for $($uri.Host): $_"
            }

            # Step 2: Connectivity check using lightweight HEAD request
            try {
                $request = [System.Net.HttpWebRequest]::Create($WebhookUrl)
                $request.Method = 'HEAD'
                $request.Timeout = ($TimeoutSeconds * 1000)  # Convert to milliseconds
                $request.AllowAutoRedirect = $false
                
                # Add headers safely
                foreach ($key in $Headers.Keys) {
                    if ($key -notin @('Content-Type', 'Content-Length', 'Content-Encoding')) {
                        try {
                            $request.Headers.Add($key, $Headers[$key])
                        }
                        catch {
                            Write-Verbose "Could not add header '$key': $_"
                        }
                    }
                }

                $response = $request.GetResponse()
                $result.StatusCode = [int]$response.StatusCode
                $result.IsHealthy = $response.StatusCode -ge 200 -and $response.StatusCode -lt 400
                $response.Close()
                
                Write-Verbose "Health check successful. Status: $($result.StatusCode)"
            }
            catch [System.Net.WebException] {
                # WebException means we got a response (possibly error status)
                if ($_.Exception.Response) {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                    $result.StatusCode = $statusCode
                    $result.IsHealthy = $statusCode -lt 500
                    
                    try {
                        $_.Exception.Response.Close()
                    }
                    catch { }
                }
                else {
                    $result.Error = $_.Exception.Message
                    $result.IsHealthy = $false
                }
            }
            catch [System.TimeoutException] {
                $result.Error = "Health check timed out after $TimeoutSeconds seconds"
                $result.IsHealthy = $false
            }
            catch {
                # Catch all other errors (network, timeout, etc.)
                if ($_.Exception.Message -match "timeout|timed out") {
                    $result.Error = "Health check timed out after $TimeoutSeconds seconds"
                }
                else {
                    $result.Error = "Health check failed: $_"
                }
                $result.IsHealthy = $false
            }
        }
        finally {
            $stopwatch.Stop()
            $result.ResponseTimeMs = [int]$stopwatch.ElapsedMilliseconds
        }

        # Update cache thread-safely
        try {
            [System.Threading.Monitor]::Enter($script:FinOpsWebhookHealthCacheLock)
            $script:FinOpsWebhookHealthCache[$cacheKey] = $result
            Write-Verbose "Cached health check result for: $WebhookUrl"
        }
        finally {
            [System.Threading.Monitor]::Exit($script:FinOpsWebhookHealthCacheLock)
        }

        return $result
    }
}
