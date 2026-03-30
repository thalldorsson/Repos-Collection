<#
.SYNOPSIS
Common helper utilities for webhook modules.

.DESCRIPTION
Provides shared utility functions for validation, error handling, and diagnostics.

.NOTES
This is a private module - do not expose publicly.
#>

# Helper: Validate webhook URL format
function Assert-ValidWebhookUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WebhookUrl,

        [Parameter(Mandatory = $false)]
        [string]$ParameterName = 'WebhookUrl'
    )

    if ([string]::IsNullOrWhiteSpace($WebhookUrl)) {
        throw "Parameter '$ParameterName' cannot be null or empty."
    }

    try {
        $uri = [System.Uri]$WebhookUrl
        
        if ($uri.Scheme -notin @('http', 'https')) {
            throw "Invalid scheme '$($uri.Scheme)'. Must be 'http' or 'https'."
        }
        
        if ([string]::IsNullOrWhiteSpace($uri.Host)) {
            throw "URL must contain a valid hostname."
        }

        return $uri
    }
    catch {
        throw "Invalid webhook URL '$WebhookUrl': $_"
    }
}

# Helper: Safe JSON serialization with size limits
function ConvertTo-SafeJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $InputObject,

        [Parameter(Mandatory = $false)]
        [int]$MaxSizeBytes = 10485760  # 10MB
    )

    try {
        $json = $InputObject | ConvertTo-Json -Depth 10 -Compress -ErrorAction Stop
        
        if ($json.Length -gt $MaxSizeBytes) {
            throw "JSON payload exceeds maximum size of $MaxSizeBytes bytes (got $($json.Length) bytes)."
        }

        return $json
    }
    catch {
        throw "Failed to serialize to JSON: $_"
    }
}

# Helper: Create directories safely with error handling
function Ensure-Directory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [string]$Description = "directory"
    )

    if (Test-Path -Path $Path -PathType Container) {
        return $Path
    }

    try {
        $null = New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop
        Write-Verbose "Created $Description at: $Path"
        return $Path
    }
    catch {
        throw "Failed to create $Description at '$Path': $_"
    }
}

# Helper: Safe file write with backups
function Write-SafeFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Content,

        [Parameter(Mandatory = $false)]
        [switch]$Append,

        [Parameter(Mandatory = $false)]
        [System.Text.Encoding]$Encoding = [System.Text.Encoding]::UTF8
    )

    try {
        $directory = Split-Path -Parent $Path
        $null = Ensure-Directory -Path $directory -Description "log directory" -ErrorAction Stop

        if ($Append) {
            Add-Content -Path $Path -Value $Content -Encoding $Encoding -ErrorAction Stop
        }
        else {
            Set-Content -Path $Path -Value $Content -Encoding $Encoding -ErrorAction Stop
        }
    }
    catch {
        Write-Warning "Failed to write to file '$Path': $_"
        throw
    }
}

# Helper: Sanitize sensitive data from strings
function Sanitize-SensitiveData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$InputString
    )

    if ([string]::IsNullOrWhiteSpace($InputString)) {
        return $InputString
    }

    # Sanitize common credentials patterns
    $sanitized = $InputString
    
    # Mask Bearer tokens
    $sanitized = $sanitized -replace 'Bearer\s+[^\s]+', 'Bearer [REDACTED]'
    
    # Mask Authorization headers
    $sanitized = $sanitized -replace 'Authorization:\s*[^\s]+', 'Authorization: [REDACTED]'
    
    # Mask API keys
    $sanitized = $sanitized -replace 'api[_-]?key\s*[:=]\s*[^\s"'']+', 'api_key=<REDACTED>'
    
    # Mask passwords
    $sanitized = $sanitized -replace 'password\s*[:=]\s*[^\s"'']+', 'password=<REDACTED>'
    
    # Mask webhook URLs in query parameters
    $sanitized = $sanitized -replace 'webhook[_-]?url\s*[:=]\s*https?://[^\s&"'']+', 'webhook_url=[REDACTED]'

    return $sanitized
}

# Helper: Exponential backoff calculation with jitter
function Get-BackoffDelay {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$AttemptNumber,

        [Parameter(Mandatory = $false)]
        [int]$InitialDelaySeconds = 2,

        [Parameter(Mandatory = $false)]
        [int]$Multiplier = 4,

        [Parameter(Mandatory = $false)]
        [switch]$AddJitter
    )

    if ($AttemptNumber -le 0) {
        return 0
    }

    # Calculate base delay with exponential backoff
    $baseDelay = $InitialDelaySeconds * [Math]::Pow($Multiplier, $AttemptNumber - 1)
    
    # Cap at reasonable maximum (2 hours)
    $maxDelay = 7200
    $delay = [Math]::Min([int]$baseDelay, $maxDelay)

    # Add random jitter (0-20%) to prevent thundering herd
    if ($AddJitter) {
        $jitterRange = [int]($delay * 0.2)
        $jitter = Get-Random -Minimum 0 -Maximum $jitterRange
        $delay += $jitter
    }

    return $delay
}

# Helper: Safe invoke of web requests with timeout enforcement
function Invoke-WebRequestSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $false)]
        [string]$Method = 'GET',

        [Parameter(Mandatory = $false)]
        [string]$Body,

        [Parameter(Mandatory = $false)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 30
    )

    try {
        $params = @{
            Uri             = $Uri
            Method          = $Method
            TimeoutSec      = $TimeoutSeconds
            ErrorAction     = 'Stop'
        }

        if ($Body) {
            $params['Body'] = $Body
        }

        if ($Headers) {
            $params['Headers'] = $Headers
        }

        Invoke-WebRequest @params
    }
    catch [System.Net.WebException] {
        if ($_.Exception.Response) {
            return [PSCustomObject]@{
                StatusCode = [int]$_.Exception.Response.StatusCode
                Response   = $null
                Error      = $_.Exception.Message
            }
        }
        throw
    }
    catch {
        throw "Web request failed: $_"
    }
}

# Helper: Get correlation ID or generate new one
function Get-CorrelationId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ProvidedId
    )

    if (-not [string]::IsNullOrWhiteSpace($ProvidedId)) {
        return $ProvidedId
    }

    return "finops-$(Get-Date -Format 'yyyyMMddHHmmssffff')-$([guid]::NewGuid().ToString('n').Substring(0, 8))"
}

