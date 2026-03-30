function Add-FinOpsJiraComment {
    <#
    .SYNOPSIS
        Adds a comment to a Jira issue.

    .DESCRIPTION
        Posts a comment to a Jira issue via REST API or Atlassian Rovo MCP Server.
        Supports plain text comments and optional rich ADF (Advanced Document Format) for formatting.

    .PARAMETER BaseUrl
        Jira base URL (e.g. https://crayon-group.atlassian.net) without trailing slash.

    .PARAMETER IssueKey
        Jira issue key (e.g. CGGS-714).

    .PARAMETER Comment
        Comment text to post.

    .PARAMETER Username
        Jira account email used with API token for Basic Auth.

    .PARAMETER ApiToken
        Jira API token as SecureString.

    .PARAMETER AuthorizationHeader
        Optional pre-built Authorization header (overrides Username/ApiToken).

    .PARAMETER UseAdf
        Switch to use Advanced Document Format for rich formatting. 
        When not specified, comment is posted as plain text.

    .PARAMETER UseAtlassianMcp
        Switch to use Atlassian Rovo MCP Server delegate for the operation.

    .EXAMPLE
        $apiToken = Read-Host 'Token' -AsSecureString
        Add-FinOpsJiraComment -BaseUrl https://crayon-group.atlassian.net -IssueKey CGGS-714 -Comment "Onboarding completed successfully" -Username you@company.com -ApiToken $apiToken

    .NOTES
        Response includes comment ID, creation timestamp, and author information.
    #>
    [CmdletBinding()] param(
        [Parameter()][string]$BaseUrl,
        [Parameter(Mandatory)][string]$IssueKey,
        [Parameter(Mandatory)][string]$Comment,
        [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')][string]$Username,
        [SecureString]$ApiToken,
        [string]$AuthorizationHeader,
        [switch]$UseAdf,
        [switch]$UseAtlassianMcp
    )
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = $script:FinOpsDefaultJiraBaseUrl }
    
    # Prefer Atlassian MCP provider when requested/registered
    if ($UseAtlassianMcp) {
        if (-not $script:AtlassianMcpProvider -or -not $script:AtlassianMcpProvider.AddComment) {
            throw "UseAtlassianMcp specified but no AddComment delegate is registered. Call Register-FinOpsAtlassianMcpProvider -AddCommentScript ... first."
        }
        return & $script:AtlassianMcpProvider.AddComment -IssueKey $IssueKey -Comment $Comment
    }
    
    if (-not $UseAtlassianMcp -and -not $Username -and -not $AuthorizationHeader) {
        throw "Username (or AuthorizationHeader) is required when not using Atlassian MCP."
    }
    
    $relative = "/rest/api/3/issues/$IssueKey/comments"
    
    Invoke-FinOpsJiraPost -BaseUrl $BaseUrl -RelativePath $relative -Body $bodyObj -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader
}
