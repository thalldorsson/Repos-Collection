function Get-FinOpsJiraIssue {
    <#
    .SYNOPSIS
        Retrieves a raw Jira issue object (wrapper around internal Invoke-FinOpsJiraGet).

    .DESCRIPTION
        Public convenience wrapper that returns the deserialized JSON for a Jira issue key using the
        same authentication model as other onboarding functions. Useful when you want to inspect
        the full structure to build a -FieldMap for Get-FinOpsOnboardingFromJiraIssue.

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
        Get-FinOpsJiraIssue -BaseUrl https://crayon-group.atlassian.net -IssueKey CGGS-714 -Username you@company.com -ApiToken $apiToken | ConvertTo-Json -Depth 8

    .NOTES
        Returns the raw issue (as PowerShell objects). Use ConvertTo-Json -Depth 8 (or higher) to serialize deeply nested properties.
    #>
    [CmdletBinding()] param(
        [Parameter()][string]$BaseUrl,
        [Parameter(Mandatory)][string]$IssueKey,
        [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')][string]$Username,
        [SecureString]$ApiToken,
        [string]$AuthorizationHeader,
        [string[]]$Expand,
        [string[]]$Fields,
        [switch]$UseAtlassianMcp
    )
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = $script:FinOpsDefaultJiraBaseUrl }
    $queryParts = @()
    if ($Expand -and $Expand.Count -gt 0) { $queryParts += 'expand=' + ($Expand -join ',') }
    if ($Fields -and $Fields.Count -gt 0) { $queryParts += 'fields=' + ($Fields -join ',') }
    $q = if ($queryParts.Count -gt 0) { '?' + ($queryParts -join '&') } else { '' }
    $relative = "/rest/api/3/issue/$IssueKey$q"
    
    # Prefer Atlassian MCP provider when requested/registered
    if ($UseAtlassianMcp) {
        if (-not $script:AtlassianMcpProvider -or -not $script:AtlassianMcpProvider.GetIssue) {
            throw "UseAtlassianMcp specified but no Atlassian MCP provider is registered. Call Register-FinOpsAtlassianMcpProvider first."
        }
        return & $script:AtlassianMcpProvider.GetIssue -IssueKey $IssueKey -Expand $Expand -Fields $Fields
    }
    
    if (-not $UseAtlassianMcp -and -not $Username -and -not $AuthorizationHeader) {
        throw "Username (or AuthorizationHeader) is required when not using Atlassian MCP."
    }
    Invoke-FinOpsJiraGet -BaseUrl $BaseUrl -RelativePath $relative -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader
}
