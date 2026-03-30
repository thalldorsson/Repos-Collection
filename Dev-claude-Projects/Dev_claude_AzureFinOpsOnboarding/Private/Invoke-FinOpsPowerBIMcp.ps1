function Invoke-FinOpsPowerBIMcp {
    <#
    .SYNOPSIS
        Internal helper to invoke a Power BI MCP delegate.

    .DESCRIPTION
        Looks up a registered scriptblock delegate in $script:PowerBIMcpProvider by operation name
        and invokes it with the provided arguments. Throws a clear error if missing.

    .PARAMETER Operation
        The MCP operation to invoke. One of: GetReport, GetWorkspace, GetWorkspaces, PublishReport, 
        GrantReportAccess, GetReportUsers, RevokeReportAccess, GetDataset, RefreshDataset, ExportReport.

    .PARAMETER Arguments
        Hashtable of named arguments to pass to the delegate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet(
            'GetReport',
            'GetWorkspace', 
            'GetWorkspaces',
            'PublishReport',
            'GrantReportAccess',
            'GetReportUsers',
            'RevokeReportAccess',
            'GetDataset',
            'RefreshDataset',
            'ExportReport'
        )]
        [string]$Operation,
        [hashtable]$Arguments
    )
    
    if (-not $script:PowerBIMcpProvider) {
        throw 'Power BI MCP provider not registered. Call Register-FinOpsPowerBIMcpProvider first.'
    }
    
    $delegate = $script:PowerBIMcpProvider[$Operation]
    if (-not $delegate) {
        throw "Power BI MCP provider does not implement operation '$Operation'."
    }
    
    & $delegate @Arguments
}
