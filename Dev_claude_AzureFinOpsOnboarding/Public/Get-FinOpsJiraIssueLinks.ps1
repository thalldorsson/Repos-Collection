function Get-FinOpsJiraIssueLinks {
    <#
    .SYNOPSIS
        Retrieves web/remote link style related data for a Jira issue (remote links + rendered description optional).
    .DESCRIPTION
        Some URL-like values a user sees in the Jira UI are not stored in a plain customfield_* value but
        instead originate from:
          * Remote links ( /rest/api/3/issue/{key}/remotelink )
          * Issue links (expand=issuelinks)
          * Rendered fields (expand=renderedFields) when the underlying field stores markup
        This helper surfaces remote links plus (optionally) expanded renderedFields so you can locate a URL that
        appears in the browser but is missing from the raw customfield list (e.g. customfield_12489 null).
    .PARAMETER BaseUrl
        Jira base URL (defaults to module default https://crayon-group.atlassian.net; override via env var FINOPS_JIRA_BASEURL).
    .PARAMETER IssueKey
        Issue key.
    .PARAMETER Username
        Jira user email.
    .PARAMETER ApiToken
        SecureString API token.
    .PARAMETER AuthorizationHeader
        Optional override header.
    .PARAMETER IncludeRenderedFields
        When set, also returns the issue with expand=renderedFields for deep inspection.
    .OUTPUTS
        PSCustomObject with RemoteLinks, (optionally) IssueRendered, and Summary subset.
    .EXAMPLE
        Get-FinOpsJiraIssueLinks -BaseUrl https://org.atlassian.net -IssueKey FIN-123 -Username user@org -ApiToken $tok -IncludeRenderedFields
    #>
    [CmdletBinding()] param(
        [string]$BaseUrl,
        [Parameter(Mandatory)][string]$IssueKey,
        [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')][string]$Username,
        [SecureString]$ApiToken,
        [string]$AuthorizationHeader,
        [switch]$IncludeRenderedFields,
        [switch]$UseAtlassianMcp
    )
    if ($UseAtlassianMcp) {
        $remote = Invoke-FinOpsJiraMcp -Operation GetRemoteLinks -Arguments @{ IssueKey = $IssueKey }
        $rendered = $null
        if ($IncludeRenderedFields) {
            $rendered = Invoke-FinOpsJiraMcp -Operation GetIssue -Arguments @{ IssueKey = $IssueKey; Expand = @('renderedFields') }
        }
    } else {
        if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = $script:FinOpsDefaultJiraBaseUrl }
        if (-not $Username -or -not $ApiToken) { throw 'Username and ApiToken are required when not using -UseAtlassianMcp.' }
        $remote = Invoke-FinOpsJiraGet -BaseUrl $BaseUrl -RelativePath "/rest/api/3/issue/$IssueKey/remotelink" -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader
        $rendered = $null
        if ($IncludeRenderedFields) {
            $rendered = Get-FinOpsJiraIssue -BaseUrl $BaseUrl -IssueKey $IssueKey -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader -Expand renderedFields
        }
    }
    [pscustomobject]@{
        IssueKey = $IssueKey
        RemoteLinks = $remote
        Rendered = $rendered
        # NOTE: Replaced PowerShell 7 null-conditional operator (?.) with PS 5.1 compatible checks
        ExtractedUrls = (@($remote | ForEach-Object {
                    $_.object.url
                    $_.object.title
                    if ($_.application -and $_.application.name) { $_.application.name }
                }) | Where-Object { $_ } | Select-Object -Unique)
    }
}
