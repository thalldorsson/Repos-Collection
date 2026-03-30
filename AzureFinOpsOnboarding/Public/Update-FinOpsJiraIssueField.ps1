function Update-FinOpsJiraIssueField {
    <#
    .SYNOPSIS
        Updates one or more fields on a Jira issue.

    .DESCRIPTION
        Modifies issue fields via REST API or Atlassian Rovo MCP Server.
        Supports updating standard fields (summary, description, labels) and custom fields.

    .PARAMETER BaseUrl
        Jira base URL (e.g. https://crayon-group.atlassian.net) without trailing slash.

    .PARAMETER IssueKey
        Jira issue key (e.g. CGGS-714).

    .PARAMETER Fields
        Hashtable of field updates. Keys are field IDs (e.g. 'summary', 'description', 'customfield_10001').
        Values are the field values to set.

    .PARAMETER Username
        Jira account email used with API token for Basic Auth.

    .PARAMETER ApiToken
        Jira API token as SecureString.

    .PARAMETER AuthorizationHeader
        Optional pre-built Authorization header (overrides Username/ApiToken).

    .PARAMETER UseAtlassianMcp
        Switch to use Atlassian Rovo MCP Server delegate for the operation.

    .EXAMPLE
        $apiToken = Read-Host 'Token' -AsSecureString
        $fieldUpdates = @{
            summary = 'Updated issue title'
            labels = @('finops', 'onboarded')
        }
        Update-FinOpsJiraIssueField -BaseUrl https://crayon-group.atlassian.net -IssueKey CGGS-714 -Fields $fieldUpdates -Username you@company.com -ApiToken $apiToken

    .NOTES
        Field IDs can be discovered via Get-FinOpsJiraFieldMetadata.
    #>
    [CmdletBinding()] param(
        [Parameter()][string]$BaseUrl,
        [Parameter(Mandatory)][string]$IssueKey,
        [Parameter(Mandatory)][hashtable]$Fields,
        [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')][string]$Username,
        [SecureString]$ApiToken,
        [string]$AuthorizationHeader,
        [switch]$UseAtlassianMcp
    )
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = $script:FinOpsDefaultJiraBaseUrl }
    
    # Prefer Atlassian MCP provider when requested/registered
    if ($UseAtlassianMcp) {
        if (-not $script:AtlassianMcpProvider -or -not $script:AtlassianMcpProvider.UpdateIssueFields) {
            throw "UseAtlassianMcp specified but no UpdateIssueFields delegate is registered. Call Register-FinOpsAtlassianMcpProvider -UpdateIssueFieldsScript ... first."
        }
        return & $script:AtlassianMcpProvider.UpdateIssueFields -IssueKey $IssueKey -Fields $Fields
    }
    
    if (-not $UseAtlassianMcp -and -not $Username -and -not $AuthorizationHeader) {
        throw "Username (or AuthorizationHeader) is required when not using Atlassian MCP."
    }
    
    $relative = "/rest/api/3/issues/$IssueKey"
    
    # Build field update object
    $updateObj = @{ fields = $Fields }
    
    Invoke-FinOpsJiraPut -BaseUrl $BaseUrl -RelativePath $relative -Body $updateObj -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader
}
