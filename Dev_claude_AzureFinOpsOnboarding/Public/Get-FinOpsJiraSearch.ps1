function Get-FinOpsJiraSearch {
    <#
    .SYNOPSIS
        Executes a Jira JQL search and returns matching issues (lightweight projection by default).

    .DESCRIPTION
        Wraps the Jira Cloud /rest/api/3/search endpoint. Useful for diagnosing 404 results on a specific
        issue key (Jira intentionally returns 404 for unauthorized issue keys). By performing a JQL search
        such as 'key = ABC-123' you can distinguish between:
          * Issue truly not existing (0 results)
          * Lack of Browse Projects permission (also 0 results, but you will also see other keys absent)
        You can expand the returned fields via -Fields or request raw responses (-Raw).

    .PARAMETER BaseUrl
        Jira base URL (defaults to module default https://crayon-group.atlassian.net; override via env var FINOPS_JIRA_BASEURL) without trailing slash.

    .PARAMETER Jql
        JQL query string. Example: key = CGGS-714  OR  project = CGGS ORDER BY created DESC

    .PARAMETER Username
        Jira account email (for Basic auth with API token).

    .PARAMETER ApiToken
        Jira API token as SecureString.

    .PARAMETER AuthorizationHeader
        Optional pre-built Authorization header.

    .PARAMETER MaxResults
        Maximum number of issues to return (default 50, Jira hard caps at 1000 per call).

    .PARAMETER Fields
        Field IDs/names to request (comma-separated or array). Use '*' for all, 'summary,status' for common subset. Default: key,summary,status.

    .PARAMETER Raw
        Return the raw search JSON instead of a simplified projection.

    .EXAMPLE
        Get-FinOpsJiraSearch -BaseUrl https://your.atlassian.net -Jql 'key = CGGS-714' -Username you@org.com -ApiToken $apiToken

    .EXAMPLE
        Get-FinOpsJiraSearch -BaseUrl https://your.atlassian.net -Jql 'project = CGGS ORDER BY created DESC' -MaxResults 10 -Fields key,summary,assignee,status -Username you@org.com -ApiToken $apiToken

    .NOTES
        * A 0-result search for a specific key can mean non-existent OR no permission; compare with a broader project search.
        * For large pagination beyond MaxResults implement loop logic (future enhancement).
    #>
    [CmdletBinding()] param(
        [string]$BaseUrl,
        [Parameter(Mandatory)][string]$Jql,
        [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')][string]$Username,
        [SecureString]$ApiToken,
        [string]$AuthorizationHeader,
        [ValidateRange(1, 1000)][int]$MaxResults = 50,
        [string[]]$Fields,
        [switch]$Raw,
        [switch]$UseAtlassianMcp
    )

    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = $script:FinOpsDefaultJiraBaseUrl }

    if (-not $Fields -or $Fields.Count -eq 0) {
        $Fields = @('key', 'summary', 'status')
    }
    $fieldsParam = ($Fields -join ',')
    $encodedJql = [uri]::EscapeDataString($Jql)
    # Use MCP provider when requested
    if ($UseAtlassianMcp) {
        if (-not $script:AtlassianMcpProvider -or -not $script:AtlassianMcpProvider.Search) {
            throw "UseAtlassianMcp specified but provider.Search is not registered. Call Register-FinOpsAtlassianMcpProvider with -SearchScript."
        }
        $result = & $script:AtlassianMcpProvider.Search -Jql $Jql -MaxResults $MaxResults -Fields $Fields
    } else {
        if (-not $Username -and -not $AuthorizationHeader) { throw 'Username (or AuthorizationHeader) is required when not using Atlassian MCP.' }
        $rel = "/rest/api/3/search?jql=$encodedJql&maxResults=$MaxResults&fields=$fieldsParam"
        $result = Invoke-FinOpsJiraGet -BaseUrl $BaseUrl -RelativePath $rel -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader
    }
    if ($Raw) { return $result }
    $issues = $null
    if ($result -and $result.issues) { $issues = $result.issues }
    elseif ($result -is [System.Collections.IEnumerable]) { $issues = $result }
    if (-not $issues) { return @() }
    foreach ($issue in $issues) {
        [pscustomobject]@{
            Key = if ($issue.key) { $issue.key } else { $issue.fields.key }
            Summary = if ($issue.fields.summary) { $issue.fields.summary } else { $issue.summary }
            Status = if ($issue.fields.status.name) { $issue.fields.status.name } elseif ($issue.status.name) { $issue.status.name } else { $null }
            ProjectKey = if ($issue.fields.project.key) { $issue.fields.project.key } elseif ($issue.project.key) { $issue.project.key } else { $null }
        }
    }
}
