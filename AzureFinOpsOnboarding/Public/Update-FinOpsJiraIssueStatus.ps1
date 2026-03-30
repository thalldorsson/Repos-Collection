function Update-FinOpsJiraIssueStatus {
    <#
    .SYNOPSIS
        Transitions a Jira issue to a new status.

    .DESCRIPTION
        Changes the status of a Jira issue by querying available transitions and then posting
        a transition request. The target status name must match one of the available transitions
        for the issue (which varies by project workflow).

    .PARAMETER BaseUrl
        Jira base URL (e.g. https://crayon-group.atlassian.net) without trailing slash.

    .PARAMETER IssueKey
        Jira issue key (e.g. CGGS-714).

    .PARAMETER TargetStatus
        Target status name (e.g. "Done", "In Progress"). Must match available transitions exactly.

    .PARAMETER Comment
        Optional comment to add during transition.

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
        Update-FinOpsJiraIssueStatus -BaseUrl https://crayon-group.atlassian.net -IssueKey CGGS-714 -TargetStatus "Done" -Comment "Onboarding complete" -Username you@company.com -ApiToken $apiToken

    .NOTES
        Target status must be a valid transition for the issue. Use Get-FinOpsJiraIssueTransitions 
        to discover available statuses first.
    #>
    [CmdletBinding()] param(
        [Parameter()][string]$BaseUrl,
        [Parameter(Mandatory)][string]$IssueKey,
        [Parameter(Mandatory)][string]$TargetStatus,
        [string]$Comment,
        [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')][string]$Username,
        [SecureString]$ApiToken,
        [string]$AuthorizationHeader,
        [switch]$UseAtlassianMcp
    )
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = $script:FinOpsDefaultJiraBaseUrl }
    
    # Prefer Atlassian MCP provider when requested/registered
    if ($UseAtlassianMcp) {
        if (-not $script:AtlassianMcpProvider -or -not $script:AtlassianMcpProvider.TransitionIssue) {
            throw "UseAtlassianMcp specified but no TransitionIssue delegate is registered. Call Register-FinOpsAtlassianMcpProvider -TransitionIssueScript ... first."
        }
        return & $script:AtlassianMcpProvider.TransitionIssue -IssueKey $IssueKey -TargetStatus $TargetStatus -Comment $Comment
    }
    
    if (-not $UseAtlassianMcp -and -not $Username -and -not $AuthorizationHeader) {
        throw "Username (or AuthorizationHeader) is required when not using Atlassian MCP."
    }
    
    # Get available transitions to find the matching transition ID
    $transitions = Get-FinOpsJiraIssueTransitions -BaseUrl $BaseUrl -IssueKey $IssueKey -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader
    
    $matchingTransition = $transitions | Where-Object { $_.to.name -eq $TargetStatus }
    if (-not $matchingTransition) {
        $available = $transitions | Select-Object -ExpandProperty 'to.name' | Sort-Object -Unique
        throw "Target status '$TargetStatus' not found in available transitions. Available statuses: $($available -join ', ')"
    }
    
    $relative = "/rest/api/3/issues/$IssueKey/transitions"
    
    # Build transition request
    $transitionObj = @{
        transition = @{ id = $matchingTransition.id }
    }
    
    # Add comment if provided
    if ($Comment) {
        $transitionObj.update = @{
            comment = @(
                @{
                    add = @{ body = $Comment }
                }
            )
        }
    }
    
    Invoke-FinOpsJiraPost -BaseUrl $BaseUrl -RelativePath $relative -Body $transitionObj -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader
}
