function Invoke-FinOpsCircuitBreaker {
    <#
    .SYNOPSIS
        Executes operations with circuit breaker pattern for resilience.
    
    .DESCRIPTION
        Protects operations from cascading failures by opening circuit after threshold failures.
        
        Circuit States:
        - Closed: Normal operation, requests pass through
        - Open: Too many failures, requests rejected immediately
        - HalfOpen: Testing recovery, limited requests allowed
        
        Transitions:
        - Closed → Open: After FailureThreshold consecutive failures
        - Open → HalfOpen: After ResetTimeout expires
        - HalfOpen → Closed: After SuccessThreshold consecutive successes
        - HalfOpen → Open: On any failure
    
    .PARAMETER CircuitName
        Unique name for the circuit (e.g., 'AzureManagementApi', 'FinOpsApi').
    
    .PARAMETER ScriptBlock
        The operation to execute with circuit breaker protection.
    
    .PARAMETER FailureThreshold
        Number of consecutive failures before opening circuit. Default is 5.
    
    .PARAMETER SuccessThreshold
        Number of consecutive successes in HalfOpen to close circuit. Default is 2.
    
    .PARAMETER ResetTimeout
        Seconds to wait before transitioning from Open to HalfOpen. Default is 60.
    
    .PARAMETER ExceptionFilter
        Optional scriptblock to determine if exception should trip circuit.
        Receives exception as parameter, returns $true to count as failure.
    
    .EXAMPLE
        $result = Invoke-FinOpsCircuitBreaker -CircuitName 'AzureManagementApi' -ScriptBlock {
            Invoke-RestMethod -Uri 'https://management.azure.com/...' -Headers $headers
        }
    
    .EXAMPLE
        # Custom failure threshold
        $result = Invoke-FinOpsCircuitBreaker -CircuitName 'FinOpsApi' -ScriptBlock {
            Get-FinOpsBearerToken
        } -FailureThreshold 3 -ResetTimeout 30
    
    .EXAMPLE
        # Filter exceptions - only 500+ errors trip circuit
        $result = Invoke-FinOpsCircuitBreaker -CircuitName 'ExternalApi' -ScriptBlock {
            Invoke-RestMethod -Uri $url
        } -ExceptionFilter { 
            param($ex)
            $ex.Exception.Response.StatusCode.value__ -ge 500
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CircuitName,
        
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        
        [Parameter()]
        [int]$FailureThreshold = 5,
        
        [Parameter()]
        [int]$SuccessThreshold = 2,
        
        [Parameter()]
        [int]$ResetTimeout = 60,
        
        [Parameter()]
        [scriptblock]$ExceptionFilter
    )
    
    # Initialize circuit breaker storage
    if (-not $script:FinOpsCircuitBreakers) {
        $script:FinOpsCircuitBreakers = @{}
    }
    
    # Get or create circuit
    if (-not $script:FinOpsCircuitBreakers.ContainsKey($CircuitName)) {
        $script:FinOpsCircuitBreakers[$CircuitName] = [PSCustomObject]@{
            Name = $CircuitName
            State = 'Closed'
            FailureCount = 0
            SuccessCount = 0
            LastFailureTime = $null
            LastStateChange = (Get-Date)
            TotalRequests = 0
            SuccessfulRequests = 0
            FailedRequests = 0
            RejectedRequests = 0
            FailureThreshold = $FailureThreshold
            SuccessThreshold = $SuccessThreshold
            ResetTimeout = $ResetTimeout
        }
        
        Write-FinOpsLog -Level 'Debug' -Message "Circuit breaker initialized" -Context @{
            Circuit = $CircuitName
            FailureThreshold = $FailureThreshold
            SuccessThreshold = $SuccessThreshold
            ResetTimeout = $ResetTimeout
        } -Category 'CircuitBreaker'
    }
    
    $circuit = $script:FinOpsCircuitBreakers[$CircuitName]
    $circuit.TotalRequests++
    
    # Check if circuit should transition from Open to HalfOpen
    if ($circuit.State -eq 'Open') {
        $timeSinceFailure = (Get-Date) - $circuit.LastFailureTime
        if ($timeSinceFailure.TotalSeconds -ge $circuit.ResetTimeout) {
            Set-CircuitState -Circuit $circuit -NewState 'HalfOpen'
        }
    }
    
    # Reject request if circuit is Open
    if ($circuit.State -eq 'Open') {
        $circuit.RejectedRequests++
        
        Write-FinOpsLog -Level 'Warning' -Message "Circuit breaker rejected request" -Context @{
            Circuit = $CircuitName
            State = 'Open'
            TimeSinceFailure = [Math]::Round(((Get-Date) - $circuit.LastFailureTime).TotalSeconds, 2)
            ResetTimeout = $circuit.ResetTimeout
        } -Category 'CircuitBreaker'
        
        throw (New-Object FinOpsException(
            "Circuit breaker '$CircuitName' is Open. Service may be unavailable.",
            4100,
            @{
                Circuit = $CircuitName
                State = 'Open'
                ResetTimeout = $circuit.ResetTimeout
                TimeSinceFailure = ((Get-Date) - $circuit.LastFailureTime).TotalSeconds
            },
            "Wait for circuit to reset (${ResetTimeout}s) or check service health"
        ))
    }
    
    # Execute operation
    try {
        $result = & $ScriptBlock
        
        # Success
        $circuit.SuccessfulRequests++
        $circuit.FailureCount = 0
        
        if ($circuit.State -eq 'HalfOpen') {
            $circuit.SuccessCount++
            
            Write-FinOpsLog -Level 'Debug' -Message "Circuit breaker success in HalfOpen state" -Context @{
                Circuit = $CircuitName
                SuccessCount = $circuit.SuccessCount
                SuccessThreshold = $circuit.SuccessThreshold
            } -Category 'CircuitBreaker'
            
            # Check if we can close the circuit
            if ($circuit.SuccessCount -ge $circuit.SuccessThreshold) {
                Set-CircuitState -Circuit $circuit -NewState 'Closed'
                $circuit.SuccessCount = 0
            }
        }
        
        return $result
    }
    catch {
        $shouldCountFailure = $true
        
        # Apply exception filter if provided
        if ($ExceptionFilter) {
            $shouldCountFailure = & $ExceptionFilter -ex $_
        }
        
        if ($shouldCountFailure) {
            $circuit.FailedRequests++
            $circuit.FailureCount++
            $circuit.LastFailureTime = Get-Date
            
            Write-FinOpsLog -Level 'Warning' -Message "Circuit breaker recorded failure" -Context @{
                Circuit = $CircuitName
                State = $circuit.State
                FailureCount = $circuit.FailureCount
                FailureThreshold = $circuit.FailureThreshold
                Error = $_.Exception.Message
            } -Category 'CircuitBreaker' -Exception $_.Exception
            
            # Check if we should open the circuit
            if ($circuit.State -eq 'Closed' -and $circuit.FailureCount -ge $circuit.FailureThreshold) {
                Set-CircuitState -Circuit $circuit -NewState 'Open'
            }
            elseif ($circuit.State -eq 'HalfOpen') {
                # Any failure in HalfOpen reopens circuit
                Set-CircuitState -Circuit $circuit -NewState 'Open'
                $circuit.SuccessCount = 0
            }
        }
        
        throw
    }
}

function Set-CircuitState {
    <#
    .SYNOPSIS
        Internal helper to transition circuit state with logging.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Circuit,
        
        [Parameter(Mandatory)]
        [ValidateSet('Closed', 'Open', 'HalfOpen')]
        [string]$NewState
    )
    
    $oldState = $Circuit.State
    $Circuit.State = $NewState
    $Circuit.LastStateChange = Get-Date
    
    if ($NewState -eq 'Closed') {
        $Circuit.FailureCount = 0
        $Circuit.SuccessCount = 0
    }
    
    Write-FinOpsLog -Level 'Warning' -Message "Circuit breaker state changed" -Context @{
        Circuit = $Circuit.Name
        OldState = $oldState
        NewState = $NewState
        FailureCount = $Circuit.FailureCount
        SuccessCount = $Circuit.SuccessCount
        TotalRequests = $Circuit.TotalRequests
        SuccessfulRequests = $Circuit.SuccessfulRequests
        FailedRequests = $Circuit.FailedRequests
        RejectedRequests = $Circuit.RejectedRequests
    } -Category 'CircuitBreaker'
    
    # Write audit log for state changes
    Write-FinOpsAuditLog -Category 'Configuration' -Action 'CircuitBreakerStateChange' -Resource $Circuit.Name -Status 'Success' -Details @{
        OldState = $oldState
        NewState = $NewState
        FailureCount = $Circuit.FailureCount
    }
}

function Get-FinOpsCircuitBreakers {
    <#
    .SYNOPSIS
        Retrieves circuit breaker status information.
    
    .DESCRIPTION
        Returns status of all or specific circuit breakers.
    
    .PARAMETER CircuitName
        Optional circuit name to filter.
    
    .EXAMPLE
        Get-FinOpsCircuitBreakers
    
    .EXAMPLE
        Get-FinOpsCircuitBreakers -CircuitName 'AzureManagementApi'
    
    .EXAMPLE
        Get-FinOpsCircuitBreakers | Where-Object State -eq 'Open'
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$CircuitName
    )
    
    if (-not $script:FinOpsCircuitBreakers) {
        return @()
    }
    
    if ($CircuitName) {
        if ($script:FinOpsCircuitBreakers.ContainsKey($CircuitName)) {
            return $script:FinOpsCircuitBreakers[$CircuitName]
        }
        return $null
    }
    
    return $script:FinOpsCircuitBreakers.Values
}

function Reset-FinOpsCircuitBreaker {
    <#
    .SYNOPSIS
        Manually resets a circuit breaker to Closed state.
    
    .DESCRIPTION
        Forces a circuit breaker back to Closed state, clearing failure counters.
        Use with caution - only reset when you're sure the underlying service is healthy.
    
    .PARAMETER CircuitName
        Name of circuit to reset.
    
    .EXAMPLE
        Reset-FinOpsCircuitBreaker -CircuitName 'AzureManagementApi'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [string]$CircuitName
    )
    
    if (-not $script:FinOpsCircuitBreakers -or -not $script:FinOpsCircuitBreakers.ContainsKey($CircuitName)) {
        Write-Warning "Circuit breaker '$CircuitName' not found"
        return
    }
    
    $circuit = $script:FinOpsCircuitBreakers[$CircuitName]
    
    if ($PSCmdlet.ShouldProcess($CircuitName, "Reset circuit breaker to Closed state")) {
        $oldState = $circuit.State
        Set-CircuitState -Circuit $circuit -NewState 'Closed'
        
        Write-FinOpsLog -Level 'Warning' -Message "Circuit breaker manually reset" -Context @{
            Circuit = $CircuitName
            OldState = $oldState
            NewState = 'Closed'
        } -Category 'CircuitBreaker'
    }
}

function Clear-FinOpsCircuitBreakers {
    <#
    .SYNOPSIS
        Removes all circuit breaker state.
    
    .DESCRIPTION
        Clears all circuit breaker instances from memory.
    
    .EXAMPLE
        Clear-FinOpsCircuitBreakers
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param()
    
    if ($PSCmdlet.ShouldProcess("All circuit breakers ($($script:FinOpsCircuitBreakers.Count) instances)", "Clear all circuits")) {
        if ($script:FinOpsCircuitBreakers) {
            $count = $script:FinOpsCircuitBreakers.Count
            $script:FinOpsCircuitBreakers.Clear()
            Write-FinOpsLog -Level 'Info' -Message "All circuit breakers cleared" -Context @{
                Count = $count
            } -Category 'CircuitBreaker'
        }
    }
}
