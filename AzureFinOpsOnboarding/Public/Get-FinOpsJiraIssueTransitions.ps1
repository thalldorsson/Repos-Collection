function Get-FinOpsJiraIssueTransitions {
    <#
    .SYNOPSIS
        Retrieves available transitions (status changes) for a Jira issue.

    .DESCRIPTION
        Queries the Jira REST API to get all possible transitions that can be performed on an issue.
        This is required before calling Update-FinOpsJiraIssueStatus to know which statuses are valid.

    .PARAMETER BaseUrl
        Jira base URL (e.g. https://crayon-group.atlassian.net) without trailing slash.

    .PARAMETER IssueKey
        Jira issue key (e.g. CGGS-714).

    .PARAMETER Username
        Jira account email used with API token for Basic Auth.

    .PARAMETER ApiToken
        Jira API token as SecureString.

    .PARAMETER AuthorizationHeader
        Optional pre-built Authorization header (overrides Username/ApiToken).

    .EXAMPLE
        $apiToken = Read-Host 'Token' -AsSecureString
        $transitions = Get-FinOpsJiraIssueTransitions -BaseUrl https://crayon-group.atlassian.net -IssueKey CGGS-714 -Username you@company.com -ApiToken $apiToken
        $transitions | Select-Object id, name, @{n='TargetStatus';e={$_.to.name}}

    .NOTES
        Returns array of transition objects, each containing id, name, and to.name (target status).
        Status names are project-specific and case-sensitive.
    #>
    [CmdletBinding()] param(
        [Parameter()][string]$BaseUrl,
        [Parameter(Mandatory)][string]$IssueKey,
        [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')][string]$Username,
        [SecureString]$ApiToken,
        [string]$AuthorizationHeader
    )
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = $script:FinOpsDefaultJiraBaseUrl }
    
    if (-not $Username -and -not $AuthorizationHeader) {
        throw "Username (or AuthorizationHeader) is required."
    }
    
    $relative = "/rest/api/3/issues/$IssueKey/transitions"
    $response = Invoke-FinOpsJiraGet -BaseUrl $BaseUrl -RelativePath $relative -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader
    
    return $response.transitions
}
