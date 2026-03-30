function Invoke-FinOpsJiraMcp {
    <#
    .SYNOPSIS
        Internal helper to invoke an Atlassian MCP delegate.

    .DESCRIPTION
        Looks up a registered scriptblock delegate in $script:AtlassianMcpProvider by operation name
        and invokes it with the provided arguments. Throws a clear error if missing.

    .PARAMETER Operation
        The MCP operation to invoke. One of: GetIssue, Search, GetProjects, GetFields, GetRemoteLinks, GetIssueProperties, GetIssueComments.

    .PARAMETER Arguments
        Hashtable of named arguments to pass to the delegate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GetIssue','Search','GetProjects','GetFields','GetRemoteLinks','GetIssueProperties','GetIssueComments')]
        [string]$Operation,
        [hashtable]$Arguments
    )
    if (-not $script:AtlassianMcpProvider) {
        throw 'Atlassian MCP provider not registered. Call Register-FinOpsAtlassianMcpProvider first.'
    }
    $delegate = $script:AtlassianMcpProvider[$Operation]
    if (-not $delegate) {
        throw "Atlassian MCP provider does not implement operation '$Operation'."
    }
    & $delegate @Arguments
}
