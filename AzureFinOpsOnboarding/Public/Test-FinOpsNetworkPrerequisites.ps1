function Test-FinOpsNetworkPrerequisites {
    <#
    .SYNOPSIS
        Quick network prerequisite check for FinOps onboarding.

    .DESCRIPTION
        Minimal, low-noise checks:
        - Verify TLS 1.2 is enabled.
        - Note presence of HTTP(S)_PROXY env vars.
        - Optional HEAD checks for Jira, SharePoint, Power BI; TCP 443 check for Teams webhook.
        - Treat 401/403 from HEAD as reachable (auth expected).

    .PARAMETER JiraBaseUrl
        Base Jira URL (e.g. https://contoso.atlassian.net). Adds /rest/api/3/serverInfo for the check.

    .PARAMETER SharePointUrl
        SharePoint site or document URL to test via HEAD.

    .PARAMETER PowerBIEndpoint
        Power BI API root. Default https://api.powerbi.com; appends /v1.0/myorg/groups for the check.

    .PARAMETER TeamsWebhookUrl
        Teams incoming webhook URL. TCP 443 connectivity only (no payload sent).

    .PARAMETER TimeoutSeconds
        Per-endpoint timeout in seconds. Default 10.

    .OUTPUTS
        PSCustomObject with TLS/proxy flags and per-endpoint results.
    #>
    [CmdletBinding()]
    param(
        [ValidatePattern('^https://.*')][string]$JiraBaseUrl,
        [ValidatePattern('^https://.*')][string]$SharePointUrl,
        [ValidatePattern('^https://.*')][string]$PowerBIEndpoint = 'https://api.powerbi.com',
        [ValidatePattern('^https://.*')][string]$TeamsWebhookUrl,
        [ValidateRange(1,120)][int]$TimeoutSeconds = 10
    )

    $testedAt = Get-Date
    $result = [PSCustomObject]@{
        AllEndpointsReachable = $false
        Tls12Supported        = $false
        ProxyDetected         = $false
        EndpointResults       = @()
        TestedAt              = $testedAt
    }

    # TLS 1.2 check
    $tls = [Net.ServicePointManager]::SecurityProtocol
    $result.Tls12Supported = ($tls -band [Net.SecurityProtocolType]::Tls12) -eq [Net.SecurityProtocolType]::Tls12
    if (-not $result.Tls12Supported) {
        Write-Warning "TLS 1.2 not enabled. Enable with: [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12"
    }

    # Proxy detection (env only to stay simple)
    $envProxy = @($env:HTTP_PROXY, $env:HTTPS_PROXY) | Where-Object { $_ }
    if ($envProxy.Count -gt 0) {
        $result.ProxyDetected = $true
        Write-Host "Proxy detected via environment variables" -ForegroundColor Yellow
    }

    # Build endpoints
    $endpoints = @()
    if ($JiraBaseUrl)     { $endpoints += @{ Name='Jira';        Url="$JiraBaseUrl/rest/api/3/serverInfo"; Mode='Head'   } }
    if ($SharePointUrl)   { $endpoints += @{ Name='SharePoint';  Url=$SharePointUrl;                        Mode='Head'   } }
    if ($PowerBIEndpoint) { $endpoints += @{ Name='PowerBI';     Url="$PowerBIEndpoint/v1.0/myorg/groups"; Mode='Head'   } }
    if ($TeamsWebhookUrl) { $endpoints += @{ Name='TeamsWebhook';Url=$TeamsWebhookUrl;                      Mode='Tcp443' } }

    foreach ($ep in $endpoints) {
        $epResult = [PSCustomObject]@{
            Name       = $ep.Name
            Url        = $ep.Url
            Reachable  = $false
            StatusCode = $null
            LatencyMs  = $null
            Error      = $null
        }

        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            if ($ep.Mode -eq 'Tcp443') {
                $uri = [Uri]$ep.Url
                $tcp = Test-NetConnection -ComputerName $uri.Host -Port 443 -WarningAction SilentlyContinue -InformationLevel Quiet
                $sw.Stop()
                if ($tcp) {
                    $epResult.Reachable = $true
                    $epResult.LatencyMs = [Math]::Round($sw.Elapsed.TotalMilliseconds, 2)
                }
                else {
                    $epResult.Error = "TCP 443 blocked"
                }
            }
            else {
                try {
                    $resp = Invoke-WebRequest -Uri $ep.Url -Method Head -TimeoutSec $TimeoutSeconds -ErrorAction Stop
                    $sw.Stop()
                    $epResult.Reachable  = $true
                    $epResult.StatusCode = $resp.StatusCode
                    $epResult.LatencyMs  = [Math]::Round($sw.Elapsed.TotalMilliseconds, 2)
                }
                catch {
                    $sw.Stop()
                    if ($_.Exception.Response -and $_.Exception.Response.StatusCode.Value__ -in 401,403) {
                        $epResult.Reachable  = $true
                        $epResult.StatusCode = $_.Exception.Response.StatusCode.Value__
                        $epResult.LatencyMs  = [Math]::Round($sw.Elapsed.TotalMilliseconds, 2)
                    }
                    else {
                        throw
                    }
                }
            }
        }
        catch {
            $epResult.Error = $_.Exception.Message
        }

        $result.EndpointResults += $epResult
    }

    $reachableCount = ($result.EndpointResults | Where-Object { $_.Reachable }).Count
    $totalCount     = $result.EndpointResults.Count
    $result.AllEndpointsReachable = ($totalCount -gt 0 -and $reachableCount -eq $totalCount)

    return $result
}
