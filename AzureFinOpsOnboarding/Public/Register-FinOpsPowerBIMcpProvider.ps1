function Register-FinOpsPowerBIMcpProvider {
    <#
    .SYNOPSIS
        Registers MCP (Model Context Protocol) delegate scriptblocks for Power BI operations.

    .DESCRIPTION
        Stores scriptblock delegates in a module-scoped hashtable ($script:PowerBIMcpProvider).
        Power BI helper functions can use these delegates instead of calling Power BI APIs directly
        when -UsePowerBIMcp is specified. This enables integration with AI agents and MCP servers.

    .PARAMETER GetReportScript
        Delegate for retrieving a single report.
        Parameters: ReportName (string), WorkspaceId (string, optional)
        Returns: PSCustomObject with Id, Name, WorkspaceId properties

    .PARAMETER GetWorkspaceScript
        Delegate for retrieving a single workspace by ID.
        Parameters: WorkspaceId (string)
        Returns: PSCustomObject with Id, Name properties

    .PARAMETER GetWorkspacesScript
        Delegate for listing all accessible workspaces.
        Parameters: Filter (string, optional)
        Returns: Array of PSCustomObjects with Id, Name properties

    .PARAMETER PublishReportScript
        Delegate for publishing a .pbix file to a workspace.
        Parameters: FilePath (string), WorkspaceId (string), ReportName (string, optional)
        Returns: PSCustomObject with ReportId, WorkspaceId, Name

    .PARAMETER GrantReportAccessScript
        Delegate for granting report access to a principal (user/group).
        Parameters: ReportId, WorkspaceId, PrincipalId, PrincipalType, AccessRight
        Returns: void or confirmation object

    .PARAMETER GetReportUsersScript
        Delegate for listing users/groups with access to a report.
        Parameters: ReportId (string), WorkspaceId (string)
        Returns: Array of PSCustomObjects with PrincipalId, PrincipalType, AccessRight

    .PARAMETER RevokeReportAccessScript
        Delegate for revoking report access from a principal.
        Parameters: ReportId (string), WorkspaceId (string), PrincipalId (string)
        Returns: void or confirmation object

    .PARAMETER GetDatasetScript
        Delegate for retrieving dataset information.
        Parameters: DatasetId (string), WorkspaceId (string)
        Returns: PSCustomObject with Id, Name, ConfiguredBy properties

    .PARAMETER RefreshDatasetScript
        Delegate for triggering a dataset refresh.
        Parameters: DatasetId (string), WorkspaceId (string)
        Returns: void or refresh status object

    .PARAMETER ExportReportScript
        Delegate for exporting a report to PDF/PowerPoint/PNG.
        Parameters: ReportId, WorkspaceId, Format, OutputPath
        Returns: PSCustomObject with FilePath, Format properties

    .EXAMPLE
        Register-FinOpsPowerBIMcpProvider -GetReportScript {
            param($ReportName, $WorkspaceId)
            [PSCustomObject]@{
                Id = '22222222-2222-2222-2222-222222222222'
                Name = $ReportName
                WorkspaceId = $WorkspaceId
            }
        }
    #>
    [CmdletBinding()]
    param(
        [scriptblock]$GetReportScript,
        [scriptblock]$GetWorkspaceScript,
        [scriptblock]$GetWorkspacesScript,
        [scriptblock]$PublishReportScript,
        [scriptblock]$GrantReportAccessScript,
        [scriptblock]$GetReportUsersScript,
        [scriptblock]$RevokeReportAccessScript,
        [scriptblock]$GetDatasetScript,
        [scriptblock]$RefreshDatasetScript,
        [scriptblock]$ExportReportScript
    )

    if (-not $script:PowerBIMcpProvider) {
        $script:PowerBIMcpProvider = @{}
    }

    if ($GetReportScript) { $script:PowerBIMcpProvider['GetReport'] = $GetReportScript }
    if ($GetWorkspaceScript) { $script:PowerBIMcpProvider['GetWorkspace'] = $GetWorkspaceScript }
    if ($GetWorkspacesScript) { $script:PowerBIMcpProvider['GetWorkspaces'] = $GetWorkspacesScript }
    if ($PublishReportScript) { $script:PowerBIMcpProvider['PublishReport'] = $PublishReportScript }
    if ($GrantReportAccessScript) { $script:PowerBIMcpProvider['GrantReportAccess'] = $GrantReportAccessScript }
    if ($GetReportUsersScript) { $script:PowerBIMcpProvider['GetReportUsers'] = $GetReportUsersScript }
    if ($RevokeReportAccessScript) { $script:PowerBIMcpProvider['RevokeReportAccess'] = $RevokeReportAccessScript }
    if ($GetDatasetScript) { $script:PowerBIMcpProvider['GetDataset'] = $GetDatasetScript }
    if ($RefreshDatasetScript) { $script:PowerBIMcpProvider['RefreshDataset'] = $RefreshDatasetScript }
    if ($ExportReportScript) { $script:PowerBIMcpProvider['ExportReport'] = $ExportReportScript }

    Write-Verbose "Registered Power BI MCP delegates: $($script:PowerBIMcpProvider.Keys -join ', ')"
}
