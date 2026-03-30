<#
.SYNOPSIS
    Sends data to Azure Log Analytics using HTTP Data Collector API.

.DESCRIPTION
    Reusable function for sending JSON data to Azure Log Analytics custom tables.
    Can be dot-sourced in other scripts or called standalone.
    No dependencies on Az modules or Azure AD authentication.

.PARAMETER Data
    PSCustomObject or array of objects to send. Will be converted to JSON.

.PARAMETER WorkspaceId
    Log Analytics Workspace ID (GUID format).

.PARAMETER WorkspaceKey
    Log Analytics Workspace Primary or Secondary Key (Base64 string).

.PARAMETER LogType
    Custom log table name (without _CL suffix). Default: WinREHealth

.PARAMETER TimeGeneratedField
    Field name containing timestamp. Default: Timestamp

.PARAMETER TimeoutSec
    HTTP request timeout in seconds. Default: 30

.EXAMPLE
    # Dot-source and use the function
    . .\Send-ToLogAnalytics.ps1
    $data = @{ ComputerName = $env:COMPUTERNAME; Timestamp = (Get-Date -Format o) }
    Send-ToLogAnalytics -Data $data -WorkspaceId "abc-123" -WorkspaceKey "key=="

.EXAMPLE
    # Call standalone (requires parameters)
    .\Send-ToLogAnalytics.ps1 -Data $myObject -WorkspaceId "abc-123" -WorkspaceKey "key==" -LogType "MyCustomLog"

.NOTES
    Author: WinRE Health Monitoring Team
    Version: 1.0.0
    Purpose: Reusable Log Analytics ingestion helper
    Reference: https://docs.microsoft.com/en-us/azure/azure-monitor/logs/data-collector-api
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, ValueFromPipeline = $true)]
    [PSCustomObject]$Data,

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceId,

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceKey,

    [Parameter(Mandatory = $false)]
    [string]$LogType = 'WinREHealthV2',

    [Parameter(Mandatory = $false)]
    [string]$TimeGeneratedField = 'Timestamp',

    [Parameter(Mandatory = $false)]
    [int]$TimeoutSec = 30
)

function Send-ToLogAnalytics {
    <#
    .SYNOPSIS
        Sends data to Azure Log Analytics using HTTP Data Collector API.

    .DESCRIPTION
        Internal function for sending JSON data to Log Analytics custom tables.
        Handles HMAC-SHA256 signature generation and HTTP POST request.

    .PARAMETER Data
        PSCustomObject or array of objects to send.

    .PARAMETER WorkspaceId
        Log Analytics Workspace ID (GUID).

    .PARAMETER WorkspaceKey
        Log Analytics Workspace Key (Base64).

    .PARAMETER LogType
        Custom log table name (without _CL suffix).

    .PARAMETER TimeGeneratedField
        Field name containing timestamp.

    .PARAMETER TimeoutSec
        HTTP request timeout in seconds.

    .EXAMPLE
        Send-ToLogAnalytics -Data $status -WorkspaceId $id -WorkspaceKey $key

    .OUTPUTS
        None. Throws exception on failure.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Data,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceId,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceKey,

        [Parameter(Mandatory = $false)]
        [string]$LogType = 'WinREHealthV2',

        [Parameter(Mandatory = $false)]
        [string]$TimeGeneratedField = 'Timestamp',

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSec = 30
    )

    $ErrorActionPreference = 'Stop'

    try {
        # Validate inputs
        if ([string]::IsNullOrWhiteSpace($WorkspaceId)) {
            throw "WorkspaceId is required"
        }
        if ([string]::IsNullOrWhiteSpace($WorkspaceKey)) {
            throw "WorkspaceKey is required"
        }

        # Ensure Data is an array
        if ($Data -isnot [Array]) {
            $Data = @($Data)
        }

        # Convert to JSON
        $json = $Data | ConvertTo-Json -Depth 10 -Compress
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($json)

        # Build RFC 1123 date
        $rfc1123date = [DateTime]::UtcNow.ToString('r')

        # Build signature string
        $method = 'POST'
        $contentType = 'application/json'
        $resource = '/api/logs'
        $xHeaders = "x-ms-date:${rfc1123date}"
        $stringToHash = "$method`n$($bodyBytes.Length)`n$contentType`n$xHeaders`n$resource"

        # Compute HMAC-SHA256
        $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
        $keyBytes = [Convert]::FromBase64String($WorkspaceKey)
        $hmac = [System.Security.Cryptography.HMACSHA256]::new($keyBytes)
        $sigBytes = $hmac.ComputeHash($bytesToHash)
        $encodedHash = [Convert]::ToBase64String($sigBytes)

        # Build authorization header
        $authorization = "SharedKey ${WorkspaceId}:${encodedHash}"

        # Build URI
        $uriBuilder = [System.UriBuilder]::new()
        $uriBuilder.Scheme = 'https'
        $uriBuilder.Host = "$WorkspaceId.ods.opinsights.azure.com"
        $uriBuilder.Path = $resource.TrimStart('/')
        $uriBuilder.Query = 'api-version=2016-04-01'
        $uri = $uriBuilder.Uri

        # Build headers
        $headers = @{
            'Authorization' = $authorization
            'Log-Type' = $LogType
            'x-ms-date' = $rfc1123date
        }

        # Add time-generated-field if specified
        if (-not [string]::IsNullOrWhiteSpace($TimeGeneratedField)) {
            $headers['time-generated-field'] = $TimeGeneratedField
        }

        Write-Verbose "Sending data to Log Analytics"
        Write-Verbose "  Workspace: $WorkspaceId"
        Write-Verbose "  Log Type: $LogType"
        Write-Verbose "  Payload Size: $($bodyBytes.Length) bytes"

        # Send HTTP POST
        $response = Invoke-RestMethod -Method $method -Uri $uri -Headers $headers `
            -ContentType $contentType -Body $bodyBytes -TimeoutSec $TimeoutSec `
            -UseBasicParsing

        Write-Verbose "Successfully sent data to Log Analytics (HTTP 200)"

    } catch {
        $statusCode = $_.Exception.Response.StatusCode.Value__ 2>$null
        $reasonPhrase = $_.Exception.Response.ReasonPhrase 2>$null

        $errorMsg = "Failed to send data to Log Analytics"
        if ($statusCode) {
            $errorMsg += " (HTTP $statusCode - $reasonPhrase)"
        }
        $errorMsg += ": $($_.Exception.Message)"

        # Provide specific guidance for common errors
        switch ($statusCode) {
            401 {
                $errorMsg += "`n  Cause: Invalid Workspace ID or Key"
                $errorMsg += "`n  Fix: Verify credentials from Azure Portal > Log Analytics > Agents"
            }
            403 {
                $errorMsg += "`n  Cause: Access denied (key permissions issue)"
                $errorMsg += "`n  Fix: Ensure using SECONDARY key with write permissions"
            }
            404 {
                $errorMsg += "`n  Cause: Workspace not found"
                $errorMsg += "`n  Fix: Verify Workspace ID is correct"
            }
            429 {
                $errorMsg += "`n  Cause: Rate limit exceeded"
                $errorMsg += "`n  Fix: Reduce ingestion frequency or check workspace tier"
            }
            500 {
                $errorMsg += "`n  Cause: Azure service error"
                $errorMsg += "`n  Fix: Retry after delay or check Azure service status"
            }
        }

        Write-Error $errorMsg
        throw
    }
}

# If called as standalone script (not dot-sourced)
if ($MyInvocation.InvocationName -ne '.') {
    # Fall back to environment variables if not provided
    if ([string]::IsNullOrWhiteSpace($WorkspaceId)) {
        $WorkspaceId = $env:la_workspace_id
        if ([string]::IsNullOrWhiteSpace($WorkspaceId)) {
            $WorkspaceId = $env:LA_WORKSPACE_ID
        }
    }
    if ([string]::IsNullOrWhiteSpace($WorkspaceKey)) {
        $WorkspaceKey = $env:la_workspace_key
        if ([string]::IsNullOrWhiteSpace($WorkspaceKey)) {
            $WorkspaceKey = $env:LA_WORKSPACE_KEY
        }
    }

    if (-not $Data) {
        Write-Host "ERROR: No data provided" -ForegroundColor Red
        Write-Host "Usage: .\Send-ToLogAnalytics.ps1 -Data `$myObject -WorkspaceId 'id' -WorkspaceKey 'key'" -ForegroundColor Yellow
        Write-Host "   OR: . .\Send-ToLogAnalytics.ps1  # Dot-source to use as function" -ForegroundColor Yellow
        exit 1
    }

    if ([string]::IsNullOrWhiteSpace($WorkspaceId) -or [string]::IsNullOrWhiteSpace($WorkspaceKey)) {
        Write-Host "ERROR: WorkspaceId and WorkspaceKey are required" -ForegroundColor Red
        Write-Host "Provide via parameters or environment variables:" -ForegroundColor Yellow
        Write-Host "  `$env:la_workspace_id = 'your-workspace-id'" -ForegroundColor Yellow
        Write-Host "  `$env:la_workspace_key = 'your-workspace-key'" -ForegroundColor Yellow
        exit 1
    }

    # Call the function
    try {
        Send-ToLogAnalytics -Data $Data -WorkspaceId $WorkspaceId -WorkspaceKey $WorkspaceKey `
            -LogType $LogType -TimeGeneratedField $TimeGeneratedField -TimeoutSec $TimeoutSec `
            -Verbose:$VerbosePreference

        Write-Host "✅ Data sent successfully to Log Analytics" -ForegroundColor Green
        Write-Host "   Workspace: $WorkspaceId" -ForegroundColor Gray
        Write-Host "   Table: ${LogType}_CL" -ForegroundColor Gray
        exit 0
    } catch {
        Write-Host "❌ Failed to send data: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# Note: This script can be dot-sourced to make Send-ToLogAnalytics function available
# in the calling scope. Export-ModuleMember only works in .psm1 modules, not .ps1 scripts.
