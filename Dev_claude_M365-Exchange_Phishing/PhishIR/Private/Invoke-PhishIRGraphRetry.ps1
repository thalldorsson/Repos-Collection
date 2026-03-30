function Invoke-PhishIRGraphRetry {
    <#
    .SYNOPSIS
    Execute Graph API call with exponential backoff retry for transient failures.

    .DESCRIPTION
    Wrapper for Microsoft Graph commands that implements retry logic with exponential
    backoff and jitter for HTTP 429 (throttling) and 5xx (server error) responses.

    Automatically retries transient failures up to MaxRetries times with increasing
    delay between attempts.

    .PARAMETER ScriptBlock
    Script block containing the Graph command to execute.

    .PARAMETER MaxRetries
    Maximum number of retry attempts. Default is 3.

    .PARAMETER InitialDelaySeconds
    Initial delay in seconds before first retry. Default is 2.

    .PARAMETER MaxDelaySeconds
    Maximum delay in seconds between retries. Default is 60.

    .EXAMPLE
    Invoke-PhishIRGraphRetry -ScriptBlock {
        Submit-MgBetaSecurityTiIndicator -Value $indicators
    }

    Execute submission with automatic retry on throttling or server errors.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [Parameter()]
        [int]$MaxRetries = 3,

        [Parameter()]
        [int]$InitialDelaySeconds = 2,

        [Parameter()]
        [int]$MaxDelaySeconds = 60
    )

    $attempt = 0
    $delay = $InitialDelaySeconds

    while ($attempt -le $MaxRetries) {
        try {
            $attempt++
            Write-Verbose "Attempt $attempt of $($MaxRetries + 1)"
            
            $result = & $ScriptBlock
            return $result

        } catch {
            $error = $_
            $shouldRetry = $false

            # Check for throttling (429) or server errors (5xx)
            if ($error.Exception.Response.StatusCode -eq 429) {
                Write-Warning "Rate limit hit (429). Retrying after $delay seconds..."
                $shouldRetry = $true
            }
            elseif ($error.Exception.Response.StatusCode -ge 500) {
                Write-Warning "Server error ($($error.Exception.Response.StatusCode)). Retrying after $delay seconds..."
                $shouldRetry = $true
            }
            elseif ($error.Exception.Message -match 'timeout|connection') {
                Write-Warning "Network issue detected. Retrying after $delay seconds..."
                $shouldRetry = $true
            }

            # If not retriable or max attempts reached, throw
            if (-not $shouldRetry -or $attempt -gt $MaxRetries) {
                throw $error
            }

            # Add jitter (random 0-25% variation)
            $jitter = Get-Random -Minimum 0 -Maximum ([int]($delay * 0.25))
            $actualDelay = $delay + $jitter

            Write-Verbose "Waiting $actualDelay seconds before retry..."
            Start-Sleep -Seconds $actualDelay

            # Exponential backoff (double delay, cap at max)
            $delay = [Math]::Min($delay * 2, $MaxDelaySeconds)
        }
    }
}
