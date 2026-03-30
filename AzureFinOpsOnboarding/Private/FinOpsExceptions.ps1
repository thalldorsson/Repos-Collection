class FinOpsException : System.Exception {
    [string]$ErrorCode
    [hashtable]$Context
    [string]$Remediation
    
    FinOpsException([string]$errorCode, [string]$message) : base($message) {
        $this.ErrorCode = $errorCode
        $this.Context = @{}
        $this.Remediation = ''
    }
    
    FinOpsException([string]$errorCode, [string]$message, [hashtable]$context) : base($message) {
        $this.ErrorCode = $errorCode
        $this.Context = $context
        $this.Remediation = ''
    }
    
    FinOpsException([string]$errorCode, [string]$message, [hashtable]$context, [string]$remediation) : base($message) {
        $this.ErrorCode = $errorCode
        $this.Context = $context
        $this.Remediation = $remediation
    }
}

class FinOpsValidationException : FinOpsException {
    FinOpsValidationException([string]$errorCode, [string]$message) : base($errorCode, $message) { }
    FinOpsValidationException([string]$errorCode, [string]$message, [hashtable]$context) : base($errorCode, $message, $context) { }
    FinOpsValidationException([string]$errorCode, [string]$message, [hashtable]$context, [string]$remediation) : base($errorCode, $message, $context, $remediation) { }
}

class FinOpsAuthenticationException : FinOpsException {
    FinOpsAuthenticationException([string]$errorCode, [string]$message) : base($errorCode, $message) { }
    FinOpsAuthenticationException([string]$errorCode, [string]$message, [hashtable]$context) : base($errorCode, $message, $context) { }
    FinOpsAuthenticationException([string]$errorCode, [string]$message, [hashtable]$context, [string]$remediation) : base($errorCode, $message, $context, $remediation) { }
}

class FinOpsApiException : FinOpsException {
    [int]$StatusCode
    [string]$RequestId
    
    FinOpsApiException([string]$errorCode, [string]$message, [int]$statusCode) : base($errorCode, $message) {
        $this.StatusCode = $statusCode
    }
    
    FinOpsApiException([string]$errorCode, [string]$message, [int]$statusCode, [hashtable]$context) : base($errorCode, $message, $context) {
        $this.StatusCode = $statusCode
    }
    
    FinOpsApiException([string]$errorCode, [string]$message, [int]$statusCode, [hashtable]$context, [string]$remediation) : base($errorCode, $message, $context, $remediation) {
        $this.StatusCode = $statusCode
    }
}

class FinOpsConfigurationException : FinOpsException {
    FinOpsConfigurationException([string]$errorCode, [string]$message) : base($errorCode, $message) { }
    FinOpsConfigurationException([string]$errorCode, [string]$message, [hashtable]$context) : base($errorCode, $message, $context) { }
    FinOpsConfigurationException([string]$errorCode, [string]$message, [hashtable]$context, [string]$remediation) : base($errorCode, $message, $context, $remediation) { }
}

function New-FinOpsErrorResult {
    <#
    .SYNOPSIS
        Creates a standardized error result object.
    
    .DESCRIPTION
        Wraps exceptions and error information into a consistent PSCustomObject format
        for non-breaking error returns. Used when functions should return error details
        instead of throwing exceptions.
    
    .PARAMETER Exception
        The exception that occurred.
    
    .PARAMETER ErrorCode
        Structured error code (e.g., 'INVALID_TENANT_ID', 'AUTH_FAILED').
    
    .PARAMETER AdditionalContext
        Additional context beyond what's in the exception.
    
    .EXAMPLE
        try {
            # Operation that might fail
        }
        catch {
            return New-FinOpsErrorResult -Exception $_
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Exception]$Exception,
        
        [Parameter()]
        [string]$ErrorCode,
        
        [Parameter()]
        [hashtable]$AdditionalContext = @{}
    )
    
    $errorResult = [PSCustomObject]@{
        Success = $false
        Error = $true
        ErrorCode = if ($Exception -is [FinOpsException]) { $Exception.ErrorCode } else { $ErrorCode }
        ErrorMessage = $Exception.Message
        ErrorType = $Exception.GetType().Name
        Context = if ($Exception -is [FinOpsException]) { $Exception.Context + $AdditionalContext } else { $AdditionalContext }
        Remediation = if ($Exception -is [FinOpsException]) { $Exception.Remediation } else { '' }
        Timestamp = (Get-Date).ToUniversalTime().ToString('o')
    }
    
    # Add API-specific fields if applicable
    if ($Exception -is [FinOpsApiException]) {
        $errorResult | Add-Member -NotePropertyName 'StatusCode' -NotePropertyValue $Exception.StatusCode
        $errorResult | Add-Member -NotePropertyName 'RequestId' -NotePropertyValue $Exception.RequestId
    }
    
    return $errorResult
}

function Write-FinOpsError {
    <#
    .SYNOPSIS
        Writes structured error information to logs.
    
    .DESCRIPTION
        Logs error details using the structured logging framework with automatic
        sensitive data masking and context enrichment.
    
    .PARAMETER Exception
        The exception to log.
    
    .PARAMETER ErrorCode
        Structured error code.
    
    .PARAMETER AdditionalContext
        Additional context to include in the log.
    
    .PARAMETER Category
        Log category. Default is 'Error'.
    
    .EXAMPLE
        try {
            # Operation
        }
        catch {
            Write-FinOpsError -Exception $_ -ErrorCode 'API_CALL_FAILED' -AdditionalContext @{
                Endpoint = $uri
                Attempt = $retryCount
            }
            throw
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Exception]$Exception,
        
        [Parameter()]
        [string]$ErrorCode,
        
        [Parameter()]
        [hashtable]$AdditionalContext = @{},
        
        [Parameter()]
        [string]$Category = 'Error'
    )
    
    # Build context from exception
    $context = $AdditionalContext.Clone()
    
    if ($Exception -is [FinOpsException]) {
        $context.ErrorCode = $Exception.ErrorCode
        $context.Remediation = $Exception.Remediation
        foreach ($key in $Exception.Context.Keys) {
            $context[$key] = $Exception.Context[$key]
        }
    }
    elseif ($ErrorCode) {
        $context.ErrorCode = $ErrorCode
    }
    
    $context.ExceptionType = $Exception.GetType().Name
    
    if ($Exception -is [FinOpsApiException]) {
        $context.StatusCode = $Exception.StatusCode
        $context.RequestId = $Exception.RequestId
    }
    
    # Log error with full stack trace at Debug level
    Write-FinOpsLog -Level 'Error' -Message $Exception.Message -Context $context -Category $Category -Exception $Exception
}

function Test-FinOpsParameter {
    <#
    .SYNOPSIS
        Validates parameters with structured error messages.
    
    .DESCRIPTION
        Common parameter validation with FinOps-specific error handling.
        Throws FinOpsValidationException with remediation guidance on failure.
    
    .PARAMETER TenantId
        Azure tenant ID to validate.
    
    .PARAMETER SubscriptionId
        Azure subscription ID to validate.
    
    .PARAMETER ThrowOnError
        Throw exception on validation failure (default). If false, returns validation result.
    
    .EXAMPLE
        Test-FinOpsParameter -TenantId $TenantId
        # Throws FinOpsValidationException if invalid
    
    .EXAMPLE
        $isValid = Test-FinOpsParameter -SubscriptionId $subId -ThrowOnError:$false
    #>
    [CmdletBinding()]
    param(
        [Parameter(ParameterSetName = 'TenantId')]
        [string]$TenantId,
        
        [Parameter(ParameterSetName = 'SubscriptionId')]
        [string]$SubscriptionId,
        
        [Parameter()]
        [switch]$ThrowOnError = $true
    )
    
    if ($PSCmdlet.ParameterSetName -eq 'TenantId') {
        $guidPattern = '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'
        if ($TenantId -notmatch $guidPattern) {
            if ($ThrowOnError) {
                throw [FinOpsValidationException]::new(
                    'INVALID_TENANT_ID',
                    "Tenant ID '$TenantId' is not a valid GUID format",
                    @{
                        ProvidedValue = $TenantId
                        ExpectedFormat = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
                    },
                    'Verify tenant ID from Azure Portal (Azure Active Directory > Properties > Tenant ID)'
                )
            }
            return $false
        }
    }
    
    if ($PSCmdlet.ParameterSetName -eq 'SubscriptionId') {
        $guidPattern = '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'
        if ($SubscriptionId -notmatch $guidPattern) {
            if ($ThrowOnError) {
                throw [FinOpsValidationException]::new(
                    'INVALID_SUBSCRIPTION_ID',
                    "Subscription ID '$SubscriptionId' is not a valid GUID format",
                    @{
                        ProvidedValue = $SubscriptionId
                        ExpectedFormat = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
                    },
                    'Verify subscription ID from Azure Portal (Subscriptions > Overview)'
                )
            }
            return $false
        }
    }
    
    return $true
}

# Error code constants for reference
$script:FinOpsErrorCodes = @{
    # Validation errors (1000-1999)
    INVALID_TENANT_ID = 1001
    INVALID_SUBSCRIPTION_ID = 1002
    INVALID_PARAMETER = 1003
    MISSING_REQUIRED_PARAMETER = 1004
    
    # Authentication errors (2000-2999)
    AUTH_FAILED = 2001
    TOKEN_EXPIRED = 2002
    INSUFFICIENT_PERMISSIONS = 2003
    INVALID_CREDENTIALS = 2004
    
    # API errors (3000-3999)
    API_CALL_FAILED = 3001
    API_RATE_LIMIT = 3002
    API_TIMEOUT = 3003
    API_NOT_FOUND = 3004
    API_FORBIDDEN = 3005
    
    # Configuration errors (4000-4999)
    INVALID_CONFIGURATION = 4001
    MISSING_CONFIGURATION = 4002
    
    # Data errors (5000-5999)
    NO_DATA_AVAILABLE = 5001
    DATA_PARSING_FAILED = 5002
    
    # General errors (9000-9999)
    UNKNOWN_ERROR = 9000
    OPERATION_CANCELLED = 9001
}
