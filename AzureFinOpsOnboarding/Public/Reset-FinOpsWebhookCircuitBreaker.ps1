<#
.SYNOPSIS
Resets webhook circuit breaker to Closed state.

.DESCRIPTION
Manually resets a circuit breaker from Open/HalfOpen back to Closed state.
Clears failure count and allows webhooks to be sent to the endpoint again.
Useful after endpoint outage is resolved.

.PARAMETER WebhookUrl
The webhook endpoint to reset.

.OUTPUTS
[hashtable] with keys:
  - EndpointUrl: The webhook URL
  - PreviousState: Circuit state before reset
  - NewState: Circuit state after reset (always 'Closed')
  - FailureCount: Failure count after reset (always 0)
  - ResetAt: DateTime when reset occurred

.EXAMPLE
# Reset circuit for Teams webhook
Reset-FinOpsWebhookCircuitBreaker -WebhookUrl "https://teams.microsoft.com/webhook/..."

# Output:
# EndpointUrl  : https://teams.microsoft.com/webhook/...
# PreviousState: Open
# NewState     : Closed
# FailureCount : 0
# ResetAt      : 2026-01-21 14:35:10

.NOTES
- Requires manually acknowledging that endpoint issue is resolved
- Circuit will immediately allow webhook deliveries again
- Should only be used after verifying endpoint is healthy
- Logged to audit trail for compliance
#>
function Reset-FinOpsWebhookCircuitBreaker {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$WebhookUrl
    )

    $endpointId = Get-WebhookEndpointId -Url $WebhookUrl
    
    # Get current state for return value
    $currentState = Invoke-FinOpsCircuitBreaker -EndpointId $endpointId -TestOnly
    $previousState = $currentState.State

    if ($PSCmdlet.ShouldProcess($WebhookUrl, "Reset circuit breaker")) {
        # Reset circuit breaker
        $newState = Invoke-FinOpsCircuitBreaker -EndpointId $endpointId -Reset

        # Log the reset action
        Write-FinOpsWebhookDeliveryLog -EndpointUrl $WebhookUrl -HttpStatusCode 0 -ResponseTimeMs 0 `
            -AttemptNumber 0 -CorrelationId "manual-reset-$(Get-Date -Format 'yyyyMMddHHmmss')" `
            -Status 'CircuitResetManual' -Error "Manual reset from $previousState to Closed"

        Write-Verbose "Circuit breaker reset for endpoint: $WebhookUrl (was $previousState)"

        return @{
            EndpointUrl  = $WebhookUrl
            PreviousState = $previousState
            NewState     = $newState.State
            FailureCount = $newState.FailureCount
            ResetAt      = Get-Date
        }
    }
}
