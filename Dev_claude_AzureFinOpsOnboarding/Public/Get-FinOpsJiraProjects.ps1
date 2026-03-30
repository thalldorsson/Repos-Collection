function Get-FinOpsJiraProjects {
    <#
    .SYNOPSIS
        Lists Jira projects visible to the authenticated user (key, name, type, simplified, id).

    .DESCRIPTION
        Calls /rest/api/3/project/search to enumerate projects the current credentials can access. Useful for
        diagnosing 404/400 issue lookups (e.g. confirming whether a project key exists or is accessible to the user
        whose API token is supplied). Supports optional full pagination with -All.

    .PARAMETER BaseUrl
        Jira base URL (defaults to module default https://crayon-group.atlassian.net; override with env var FINOPS_JIRA_BASEURL). No trailing slash.

    .PARAMETER Username
        Jira account email for Basic auth.

    .PARAMETER ApiToken
        Jira API token as SecureString.

    .PARAMETER AuthorizationHeader
        Optional pre-computed Authorization header; Username/ApiToken still validated.

    .PARAMETER Max
        Maximum number of projects to return (default 200). When -All is not set, results are truncated to this count.

    .PARAMETER All
        If specified, pages until all accessible projects are returned (may be slow on very large instances).

    .EXAMPLE
        Get-FinOpsJiraProjects -BaseUrl https://example.atlassian.net -Username user@example.com -ApiToken $apiToken

    .EXAMPLE
        # Find a specific key ignoring case
        Get-FinOpsJiraProjects -BaseUrl https://example.atlassian.net -Username user@example.com -ApiToken $apiToken -All | Where-Object Key -eq 'FIN'

    .OUTPUTS
        PSCustomObject with: Key, Name, ProjectType, Simplified, Id
    #>
    [CmdletBinding()] param(
        [string]$BaseUrl,
        [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')][string]$Username,
        [SecureString]$ApiToken,
        [string]$AuthorizationHeader,
        [int]$Max = 200,
        [switch]$All,
        [switch]$UseAtlassianMcp
    )

    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = $script:FinOpsDefaultJiraBaseUrl }

    $accum = New-Object System.Collections.Generic.List[object]
    $startAt = 0
    if ($UseAtlassianMcp) {
        if (-not $script:AtlassianMcpProvider -or -not $script:AtlassianMcpProvider.GetProjects) {
            throw "UseAtlassianMcp specified but provider.GetProjects is not registered. Call Register-FinOpsAtlassianMcpProvider with -GetProjectsScript."
        }
        $projects = & $script:AtlassianMcpProvider.GetProjects -Max $Max -All:$All
        foreach ($p in $projects) {
            $accum.Add([pscustomobject]@{
                Key = $p.key
                Name = $p.name
                ProjectType = if ($p.projectTypeKey) { $p.projectTypeKey } else { $p.projectType }
                Simplified = $p.simplified
                Id = $p.id
            })
        }
    } else {
        if (-not $Username -and -not $AuthorizationHeader) { throw 'Username (or AuthorizationHeader) is required when not using Atlassian MCP.' }
        do {
            $take = [Math]::Min($Max, 1000)
            $rel = "/rest/api/3/project/search?startAt=$startAt&maxResults=$take"
            $resp = Invoke-FinOpsJiraGet -BaseUrl $BaseUrl -RelativePath $rel -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader
            if ($resp.values) {
                foreach ($p in $resp.values) {
                    $accum.Add([pscustomobject]@{
                            Key = $p.key
                            Name = $p.name
                            ProjectType = $p.projectTypeKey
                            Simplified = $p.simplified
                            Id = $p.id
                        })
                }
            }
            $total = $resp.total
            $startAt += $take
            $more = $All -and ($accum.Count -lt $total)
        } while ($more)
    }

    if (-not $All -and $accum.Count -gt $Max) {
        return $accum | Select-Object -First $Max
    }
    $accum
}
