function Register-FinOpsAtlassianMcpProvider {
    <#
    .SYNOPSIS
        Registers scriptblock delegates for Atlassian MCP-backed Jira operations.

    .DESCRIPTION
        Stores scriptblocks in a module-scoped hashtable ($script:AtlassianMcpProvider) enabling
        Jira helper functions to invoke MCP instead of direct REST calls. Any subset of operations
        may be registered; functions will throw if a requested delegate is absent.

    .PARAMETER GetIssueScript
        Delegate for single issue retrieval. Parameters: -IssueKey, -Expand, -Fields.

    .PARAMETER SearchScript
        Delegate for JQL search. Parameters: -Jql, -MaxResults, -Fields.

    .PARAMETER GetProjectsScript
        Delegate for listing projects. Parameters: -Max, -All.

    .PARAMETER GetFieldsScript
        Delegate for retrieving field metadata. No parameters required; may ignore optional ones.

    .PARAMETER GetRemoteLinksScript
        Delegate for retrieving remote links of an issue. Parameters: -IssueKey.

    .PARAMETER GetIssuePropertiesScript
        Delegate for listing and/or fetching issue properties. Parameters: -IssueKey, -FetchValues, -ValueContains.

    .PARAMETER GetIssueCommentsScript
        Delegate for retrieving issue comments. Parameters: -IssueKey.

    .EXAMPLE
        Register-FinOpsAtlassianMcpProvider -GetIssueScript { param($IssueKey) Invoke-Whatever -Issue $IssueKey }

    .EXAMPLE
        Register-FinOpsAtlassianMcpProvider -SearchScript { param($Jql,$MaxResults,$Fields) Invoke-Search -Jql $Jql }

    .NOTES
        Unregistered delegates are simply unavailable; calling functions using -UseAtlassianMcp will validate.
    #>
    [CmdletBinding()] param(
        [ScriptBlock]$GetIssueScript,
        [ScriptBlock]$SearchScript,
        [ScriptBlock]$GetProjectsScript,
        [ScriptBlock]$GetFieldsScript,
        [ScriptBlock]$GetRemoteLinksScript,
        [ScriptBlock]$GetIssuePropertiesScript,
        [ScriptBlock]$GetIssueCommentsScript
    )
    if (-not $script:AtlassianMcpProvider) { $script:AtlassianMcpProvider = @{} }
    if ($GetIssueScript)           { $script:AtlassianMcpProvider.GetIssue           = $GetIssueScript }
    if ($SearchScript)             { $script:AtlassianMcpProvider.Search             = $SearchScript }
    if ($GetProjectsScript)        { $script:AtlassianMcpProvider.GetProjects        = $GetProjectsScript }
    if ($GetFieldsScript)          { $script:AtlassianMcpProvider.GetFields          = $GetFieldsScript }
    if ($GetRemoteLinksScript)     { $script:AtlassianMcpProvider.GetRemoteLinks     = $GetRemoteLinksScript }
    if ($GetIssuePropertiesScript) { $script:AtlassianMcpProvider.GetIssueProperties = $GetIssuePropertiesScript }
    if ($GetIssueCommentsScript)   { $script:AtlassianMcpProvider.GetIssueComments   = $GetIssueCommentsScript }
    $registered = $script:AtlassianMcpProvider.Keys -join ', '
    Write-Verbose "Atlassian MCP delegates registered: $registered"
}
