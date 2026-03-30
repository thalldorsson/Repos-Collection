function Invoke-FinOpsJiraGet {
    <#
    .SYNOPSIS
        Internal helper to invoke a Jira Cloud / Server REST GET request.
    .DESCRIPTION
        Supports either:
          - Basic auth with username + API token (recommended for Jira Cloud)
          - Direct Authorization header override (if -AuthorizationHeader provided)
        Returns deserialized JSON (Invoke-RestMethod).
    .PARAMETER BaseUrl
        Base URL of Jira instance, e.g. https://yourorg.atlassian.net
    .PARAMETER RelativePath
        REST path beginning with / (e.g. /rest/api/3/issue/ABC-123)
    .PARAMETER Username
        Jira account (email) when using Basic auth.
    .PARAMETER ApiToken
        SecureString representing Jira API token (or password for server editions).
    .PARAMETER AuthorizationHeader
        Optional pre-built Authorization header value (overrides Username/ApiToken logic).
    .PARAMETER MaxRetries
        Maximum number of retry attempts for transient failures. Default is 3.
    .PARAMETER InitialDelaySeconds
        Initial delay in seconds before first retry attempt. Default is 2 seconds.
    .EXAMPLE
        Invoke-FinOpsJiraGet -BaseUrl https://contoso.atlassian.net -RelativePath "/rest/api/3/issue/ABC-1" -Username user@contoso.com -ApiToken $token
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$RelativePath,
        [string]$Username,
        [SecureString]$ApiToken,
        [string]$AuthorizationHeader,
        [Parameter(Mandatory=$false)][int]$MaxRetries = 3,
        [Parameter(Mandatory=$false)][int]$InitialDelaySeconds = 2
    )
    if ($RelativePath -notmatch '^/') { $RelativePath = '/' + $RelativePath }
    $uri = ($BaseUrl.TrimEnd('/')) + $RelativePath
    $headers = @{ 'Accept' = 'application/json' }
    if ($AuthorizationHeader) {
        $headers['Authorization'] = $AuthorizationHeader
    } elseif ($Username -and $ApiToken) {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ApiToken)
        try {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            $pair = "$Username`:$plain"
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($pair)
            $headers['Authorization'] = 'Basic ' + [Convert]::ToBase64String($bytes)
        }
        finally { if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) } }
    } else {
        throw 'Either supply -AuthorizationHeader or both -Username and -ApiToken.'
    }
    try {
        Invoke-FinOpsRestMethodWithRetry -Uri $uri -Method Get -Headers $headers -MaxRetries $MaxRetries -InitialDelaySeconds $InitialDelaySeconds -ErrorAction Stop
    }
    catch {
        $baseMsg = "Jira GET failed: $uri"
        $ex = $_.Exception
        $statusLine = ''
        $bodySnippet = ''
        $parsedMessages = ''
        try {
            if ($ex.Response) {
                $statusCode = $null
                $statusDesc = $null
                # Intentionally catching and ignoring parsing errors - these are optional values
                try { $statusCode = [int]$ex.Response.StatusCode } catch { Write-Verbose "Status code not available" }
                try { $statusDesc = $ex.Response.StatusDescription } catch { Write-Verbose "Status description not available" }
                if ($statusCode) { $statusLine = " (HTTP $statusCode $statusDesc)" }
                $stream = $ex.Response.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $raw = $reader.ReadToEnd()
                    if ($raw) {
                        # Attempt to parse Jira error JSON to surface errorMessages/warningMessages
                        try {
                            $json = $null
                            $json = $raw | ConvertFrom-Json -ErrorAction Stop
                            $errs = @()
                            if ($json.errorMessages) { $errs += ($json.errorMessages | ForEach-Object { $_ }) }
                            if ($json.errors) {
                                foreach ($kv in $json.errors.GetEnumerator()) { $errs += "$($kv.Key): $($kv.Value)" }
                            }
                            $warns = @()
                            if ($json.warningMessages) { $warns += ($json.warningMessages | ForEach-Object { $_ }) }
                            if ($errs.Count -gt 0) { $parsedMessages += " Errors: " + ($errs -join ' | ') }
                            if ($warns.Count -gt 0) { $parsedMessages += " Warnings: " + ($warns -join ' | ') }
                        } catch {
                            # fallback to raw snippet if not JSON
                            $trunc = if ($raw.Length -gt 400) { $raw.Substring(0, 400) + '...' } else { $raw }
                            $bodySnippet = " Body: " + ($trunc -replace '\r?\n', ' ')
                        }
                        if (-not $parsedMessages) {
                            # Provide trimmed raw body if no structured messages extracted
                            $trunc2 = if ($raw.Length -gt 400) { $raw.Substring(0, 400) + '...' } else { $raw }
                            if (-not $bodySnippet) { $bodySnippet = " Body: " + ($trunc2 -replace '\r?\n', ' ') }
                        }
                    }
                }
            }
        } catch {
            # Ignore errors during error message extraction - we'll throw the original error
            Write-Verbose "Failed to extract detailed error message from response"
        }
        throw [System.Exception]::new($baseMsg + $statusLine + $parsedMessages + $bodySnippet, $ex)
    }
}
