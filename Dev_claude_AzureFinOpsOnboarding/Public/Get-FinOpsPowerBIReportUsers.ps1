function Get-FinOpsPowerBIReportUsers {
    <#
    .SYNOPSIS
    Lists users and groups with access to a Power BI report via REST API or MCP delegate.

    .DESCRIPTION
    When -UsePowerBIMcp is specified, invokes GetReportUsers delegate. Otherwise uses
    Power BI REST endpoint GET groups/{workspaceId}/reports/{reportId}/users.

    .PARAMETER ReportName
    Name of the report. Required unless ReportId is provided.

    .PARAMETER ReportId
    GUID of the report. If provided, skips name lookup.

    .PARAMETER WorkspaceId
    Workspace (group) GUID. If omitted, discovered via admin groups expansion when ReportName used.

    .PARAMETER UsePowerBIMcp
    Use registered MCP delegate instead of direct REST API.

    .PARAMETER PassThru
    Return collection to pipeline (otherwise writes verbose summary).

    .OUTPUTS
    Array of PSCustomObject with PrincipalId, PrincipalType, AccessRight
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position=0)][string]$ReportName,
        [Parameter()][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$ReportId,
        [Parameter()][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$WorkspaceId,
        [switch]$UsePowerBIMcp,
        [switch]$PassThru
    )

    try {
        if ($UsePowerBIMcp) {
            if (-not $ReportId -and -not $ReportName) { throw 'Provide ReportName or ReportId for MCP users lookup.' }
            Write-Verbose 'Using Power BI MCP GetReportUsers delegate'
            $args = @{ ReportId = $ReportId; WorkspaceId = $WorkspaceId }
            if ($ReportName) { $args.ReportName = $ReportName }
            $users = Invoke-FinOpsPowerBIMcp -Operation GetReportUsers -Arguments $args
            if (-not $users) { return @() }
            if ($PassThru) { return $users } else { ($users | Out-String) | Write-Verbose }
            return $users
        }

        # Direct API path
        if (-not (Get-Module -ListAvailable -Name MicrosoftPowerBIMgmt.Profile)) {
            Install-Module -Name MicrosoftPowerBIMgmt.Profile -Scope CurrentUser -Force -ErrorAction Stop
        }
        if (-not (Get-Module -ListAvailable -Name MicrosoftPowerBIMgmt)) {
            Install-Module -Name MicrosoftPowerBIMgmt -Scope CurrentUser -Force -ErrorAction Stop
        }
        Import-Module MicrosoftPowerBIMgmt -ErrorAction Stop

        $token = $null
        try { $token = Get-PowerBIAccessToken -AsString -ErrorAction Stop } catch {}
        if (-not $token) { Connect-PowerBIServiceAccount -ErrorAction Stop | Out-Null }

        if (-not $ReportId) {
            if (-not $ReportName) { throw 'Provide ReportName or ReportId.' }
            $reports = Get-PowerBIReport -Name $ReportName -Scope Organization -ErrorAction Stop
            if (-not $reports) { throw "Report not found: $ReportName" }
            if ($reports.Count -gt 1) { throw "Multiple reports named '$ReportName'. Provide -ReportId." }
            $ReportId = $reports.Id
        }

        if (-not $WorkspaceId) {
            $workspacesResponse = Invoke-PowerBIRestMethod -Url "admin/groups?`$expand=reports" -Method Get -ErrorAction Stop | ConvertFrom-Json
            foreach ($workspace in $workspacesResponse.value) {
                if ($workspace.reports | Where-Object { $_.id -eq $ReportId }) { $WorkspaceId = $workspace.id; break }
            }
            if (-not $WorkspaceId) { throw "Workspace for report $ReportId not found (admin permission required)." }
        }

        $url = "groups/$WorkspaceId/reports/$ReportId/users"
        Write-Verbose "Querying report users: $url"
        $response = Invoke-PowerBIRestMethod -Url $url -Method Get -ErrorAction Stop | ConvertFrom-Json
        $items = @()
        foreach ($u in $response.value) {
            $items += [PSCustomObject]@{
                PrincipalId   = $u.identifier
                PrincipalType = $u.principalType
                AccessRight   = $u.accessRight
            }
        }
        if ($PassThru) { return $items } else { ($items | Out-String) | Write-Verbose }
        $items
    } catch {
        Write-Error "Failed to list report users: $_"
        return @()
    }
}
