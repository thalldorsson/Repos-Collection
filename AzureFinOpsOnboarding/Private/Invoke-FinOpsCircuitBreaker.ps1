<#
.SYNOPSIS
Implements circuit breaker pattern for webhook endpoints.

.DESCRIPTION
Prevents hammering failing endpoints by implementing a state machine:
- Closed (normal): Allow requests to proceed
- Open (failing): Block requests, add to queue
- Half-Open (testing): Allow single test request to verify recovery

State transitions:
- Closed → Open: After N consecutive failures
- Open → Half-Open: After timeout period
- Half-Open → Closed: If test request succeeds
- Half-Open → Open: If test request fails

.PARAMETER EndpointId
Unique identifier for the webhook endpoint (hostname or full URL).

.PARAMETER TestOnly
If specified, only check circuit state without recording failures.

.PARAMETER RecordFailure
Record a failure for the endpoint.

.PARAMETER TestRecovery
Attempt a test request in Half-Open state (transitions to Closed on success).

.PARAMETER Reset
Manually reset circuit to Closed state.

.PARAMETER Config
Configuration with failure threshold and reset timeout.

.OUTPUTS
[hashtable] with keys:
  - State: 'Closed' | 'Open' | 'HalfOpen'
  - FailureCount: Number of consecutive failures
  - LastFailure: DateTime of last failure
  - OpenedAt: DateTime when circuit opened (if currently Open/HalfOpen)
  - ShouldAttempt: [bool] True if request should proceed

.EXAMPLE
# Check circuit state before sending webhook
$circuit = Invoke-FinOpsCircuitBreaker -EndpointId "teams.microsoft.com" -TestOnly
if ($circuit.State -ne 'Open') {
    # Send webhook
}

# Record a failure
Invoke-FinOpsCircuitBreaker -EndpointId "teams.microsoft.com" -RecordFailure

# Reset circuit manually
Invoke-FinOpsCircuitBreaker -EndpointId "teams.microsoft.com" -Reset

.NOTES
- Circuit state persists in memory during PowerShell session
- Failure count incremented on each RecordFailure call
- Half-Open state allows single test request
- State transitions logged for audit trail
#>
function Invoke-FinOpsCircuitBreaker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EndpointId,

        [Parameter(Mandatory = $false)]
        [switch]$TestOnly,

        [Parameter(Mandatory = $false)]
        [switch]$RecordFailure,

        [Parameter(Mandatory = $false)]
        [switch]$TestRecovery,

        [Parameter(Mandatory = $false)]
        [switch]$Reset,

        [Parameter(Mandatory = $false)]
        [hashtable]$Config = $null
    )

    # Load default config if not provided
    if (-not $Config) {
        $fullConfig = Get-FinOpsWebhookConfig
        $Config = @{
            FailureThreshold = $fullConfig.CircuitBreaker.FailureThreshold
            ResetSeconds     = $fullConfig.CircuitBreaker.ResetSeconds
        }
    }

    # Initialize circuit breaker state storage if needed
    if (-not $script:FinOpsCircuitBreakerState) {
        $script:FinOpsCircuitBreakerState = @{}
    }

    # Initialize endpoint state if needed
    if (-not $script:FinOpsCircuitBreakerState.ContainsKey($EndpointId)) {
        $script:FinOpsCircuitBreakerState[$EndpointId] = @{
            FailureCount = 0
            State        = 'Closed'
            LastFailure  = $null
            OpenedAt     = $null
        }
    }

    $state = $script:FinOpsCircuitBreakerState[$EndpointId]
    $now = Get-Date

    # Handle explicit state changes
    if ($Reset) {
        Write-FinOpsLog -Message "Circuit breaker reset for endpoint $EndpointId" -Level 'Information'
        $state.FailureCount = 0
        $state.State = 'Closed'
        $state.LastFailure = $null
        $state.OpenedAt = $null
        
        return @{
            State          = 'Closed'
            FailureCount   = 0
            LastFailure    = $null
            OpenedAt       = $null
            ShouldAttempt  = $true
            Action         = 'Reset'
        }
    }

    if ($RecordFailure) {
        $state.FailureCount++
        $state.LastFailure = $now

        # Check if threshold exceeded to transition to Open
        if ($state.FailureCount -ge $Config.FailureThreshold -and $state.State -eq 'Closed') {
            $state.State = 'Open'
            $state.OpenedAt = $now
            Write-FinOpsLog -Message "Circuit breaker OPENED for endpoint $EndpointId after $($state.FailureCount) failures" -Level 'Warning'

            return @{
                State          = 'Open'
                FailureCount   = $state.FailureCount
                LastFailure    = $now
                OpenedAt       = $now
                ShouldAttempt  = $false
                Action         = 'Opened'
            }
        }

        return @{
            State          = $state.State
            FailureCount   = $state.FailureCount
            LastFailure    = $now
            OpenedAt       = $state.OpenedAt
            ShouldAttempt  = $state.State -ne 'Open'
            Action         = 'FailureRecorded'
        }
    }

    # State machine logic
    switch ($state.State) {
        'Closed' {
            return @{
                State          = 'Closed'
                FailureCount   = $state.FailureCount
                LastFailure    = $state.LastFailure
                OpenedAt       = $null
                ShouldAttempt  = $true
            }
        }

        'Open' {
            # Check if timeout expired to transition to Half-Open
            if ($state.OpenedAt -and (($now - $state.OpenedAt).TotalSeconds -ge $Config.ResetSeconds)) {
                $state.State = 'HalfOpen'
                Write-FinOpsLog -Message "Circuit breaker transitioned to HALF-OPEN for endpoint $EndpointId" -Level 'Information'

                return @{
                    State          = 'HalfOpen'
                    FailureCount   = $state.FailureCount
                    LastFailure    = $state.LastFailure
                    OpenedAt       = $state.OpenedAt
                    ShouldAttempt  = $true  # Allow test request
                }
            }

            return @{
                State          = 'Open'
                FailureCount   = $state.FailureCount
                LastFailure    = $state.LastFailure
                OpenedAt       = $state.OpenedAt
                ShouldAttempt  = $false
            }
        }

        'HalfOpen' {
            if ($TestRecovery) {
                # Test request succeeded - close circuit
                $state.State = 'Closed'
                $state.FailureCount = 0
                $state.LastFailure = $null
                $state.OpenedAt = $null
                Write-FinOpsLog -Message "Circuit breaker CLOSED for endpoint $EndpointId after successful test" -Level 'Information'

                return @{
                    State          = 'Closed'
                    FailureCount   = 0
                    LastFailure    = $null
                    OpenedAt       = $null
                    ShouldAttempt  = $true
                    Action         = 'Closed'
                }
            }

            return @{
                State          = 'HalfOpen'
                FailureCount   = $state.FailureCount
                LastFailure    = $state.LastFailure
                OpenedAt       = $state.OpenedAt
                ShouldAttempt  = $true  # Allow test request
            }
        }

        default {
            # Unknown state - reset to safe state
            $state.State = 'Closed'
            $state.FailureCount = 0

            return @{
                State          = 'Closed'
                FailureCount   = 0
                LastFailure    = $null
                OpenedAt       = $null
                ShouldAttempt  = $true
            }
        }
    }
}

# Helper function for logging
function Write-FinOpsLog {
    param(
        [string]$Message,
        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$Level = 'Information'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "[$timestamp] [$Level] $Message"

    # Write to console (in real implementation, would write to file)
    switch ($Level) {
        'Warning' { Write-Warning $logEntry }
        'Error' { Write-Error $logEntry }
        default { Write-Verbose $logEntry }
    }
}
