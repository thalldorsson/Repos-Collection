function Get-FinOpsJiraIssueProperties {
    <#
    .SYNOPSIS
        Lists and optionally retrieves Jira issue entity properties (key/value JSON) to help locate data not in standard fields.
    .DESCRIPTION
        Some Forge / Connect apps or UI panels surface data (like a URL) that is stored in issue properties rather than customfield_* values.
        This helper first calls /rest/api/3/issue/{key}/properties to list keys. If -FetchValues is supplied it also retrieves each
        property's JSON value. You can filter the combined results with -ValueContains (case-insensitive substring) to quickly locate a URL.
    .PARAMETER BaseUrl
        Jira base URL (defaults to module default https://crayon-group.atlassian.net; override with env var FINOPS_JIRA_BASEURL). No trailing slash.
    .PARAMETER IssueKey
        Issue key (e.g. FIN-123).
    .PARAMETER Username
        Jira account email.
    .PARAMETER ApiToken
        SecureString API token.
    .PARAMETER AuthorizationHeader
        Optional raw Authorization header override.
    .PARAMETER FetchValues
        When set, fetches each property's value; otherwise lists only keys. (Each extra call counts toward rate limits.)
    .PARAMETER ValueContains
        Substring filter applied after fetching values. Ignored unless -FetchValues.
    .OUTPUTS
        PSCustomObject with Key, Value (if fetched), Length.
    .EXAMPLE
        Get-FinOpsJiraIssueProperties -BaseUrl https://org.atlassian.net -IssueKey FIN-1 -Username user@org -ApiToken $tok -FetchValues -ValueContains deila
    #>
    [CmdletBinding()] param(
        [string]$BaseUrl,
        [Parameter(Mandatory)][string]$IssueKey,
        [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')][string]$Username,
        [SecureString]$ApiToken,
        [string]$AuthorizationHeader,
        [switch]$FetchValues,
        [string]$ValueContains,
        [switch]$UseAtlassianMcp
    )
    if ($UseAtlassianMcp) {
        $items = Invoke-FinOpsJiraMcp -Operation GetIssueProperties -Arguments @{ IssueKey = $IssueKey; FetchValues = [bool]$FetchValues; ValueContains = $ValueContains }
        return ($items | Sort-Object Key)
    }
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = $script:FinOpsDefaultJiraBaseUrl }
    if (-not $Username -or -not $ApiToken) { throw 'Username and ApiToken are required when not using -UseAtlassianMcp.' }
    $list = Invoke-FinOpsJiraGet -BaseUrl $BaseUrl -RelativePath "/rest/api/3/issue/$IssueKey/properties" -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader
    $items = @()
    foreach ($p in $list.keys) {
        if (-not $FetchValues) {
            $items += [pscustomobject]@{ Key = $p; Value = $null; Length = 0 }
        } else {
            try {
                $valObj = Invoke-FinOpsJiraGet -BaseUrl $BaseUrl -RelativePath "/rest/api/3/issue/$IssueKey/properties/$p" -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader
                $val = $valObj.value
                $flat = if ($null -eq $val) { '' } elseif ($val -is [string]) { $val } else { ($val | ConvertTo-Json -Depth 6 -Compress) }
                $items += [pscustomobject]@{ Key = $p; Value = $flat; Length = $flat.Length }
            } catch {
                $items += [pscustomobject]@{ Key = $p; Value = "<fetch error: $($_.Exception.Message)>"; Length = 0 }
            }
        }
    }
    if ($FetchValues -and $ValueContains) {
        $lc = $ValueContains.ToLowerInvariant()
        $items = $items | Where-Object { $_.Value -and $_.Value.ToLowerInvariant().Contains($lc) }
    }
    $items | Sort-Object Key
}
