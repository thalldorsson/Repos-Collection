function Revoke-FinOpsPowerBIReportAccess {
    <#
    .SYNOPSIS
    Revokes access for an Entra ID group (or principal ID) from a Power BI report.

    .DESCRIPTION
    Uses Power BI REST API DELETE groups/{workspaceId}/reports/{reportId}/users/{principalId} or MCP
    delegate (RevokeReportAccess) when -UsePowerBIMcp specified. Mirrors grant function structure.

    .PARAMETER ReportName
    Name of the report to revoke access from (unless ReportId provided).

    .PARAMETER ReportId
    Report GUID. If provided, skips name lookup.

    .PARAMETER EntraGroup
    Display name of Entra ID group whose access will be revoked.

    .PARAMETER EntraGroupId
    ObjectId of group/user principal. If provided takes precedence over EntraGroup.

    .PARAMETER UsePowerBIMcp
    Use registered MCP delegates instead of REST API calls.

    .PARAMETER PassThru
    Return result object to pipeline.

    .OUTPUTS
    PSCustomObject with ReportName, WorkspaceId, ReportId, RevokedFrom, RevokedFromId, Status
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ReportName,
        [Parameter()][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$ReportId,
        [Parameter()][string]$EntraGroup,
        [Parameter()][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$EntraGroupId,
        [switch]$UsePowerBIMcp,
        [switch]$PassThru
    )

    try {
        if ($UsePowerBIMcp) {
            Write-Verbose 'Using Power BI MCP RevokeReportAccess delegate'
            $report = Invoke-FinOpsPowerBIMcp -Operation GetReport -Arguments @{ ReportName = $ReportName }
            if (-not $report) { throw "Report not found via MCP: $ReportName" }
            $workspaceId = $report.WorkspaceId
            if (-not $workspaceId) { throw 'MCP GetReport delegate did not return WorkspaceId.' }

            $principalId = $null
            $principalName = $null
            if ($EntraGroupId) { $principalId = $EntraGroupId; $principalName = $EntraGroupId }
            elseif ($EntraGroup) { $principalId = "resolved-$EntraGroup"; $principalName = $EntraGroup } # delegate may handle resolution itself
            else { throw 'Provide -EntraGroup or -EntraGroupId.' }

            if ($PSCmdlet.ShouldProcess("Report $($report.Id)", "Revoke access for $principalId")) {
                Invoke-FinOpsPowerBIMcp -Operation RevokeReportAccess -Arguments @{ ReportId = $report.Id; WorkspaceId = $workspaceId; PrincipalId = $principalId }
            }
            $result = [PSCustomObject]@{
                ReportName    = $report.Name
                WorkspaceId   = $workspaceId
                ReportId      = $report.Id
                RevokedFrom   = $principalName
                RevokedFromId = $principalId
                Status        = 'Revoked'
            }
            if ($PassThru) { return $result } else { $result | Out-String | Write-Verbose }
            return $result
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
            $reports = Get-PowerBIReport -Name $ReportName -Scope Organization -ErrorAction Stop
            if (-not $reports) { throw "Report not found: $ReportName" }
            if ($reports.Count -gt 1) { throw "Multiple reports named '$ReportName'. Provide -ReportId." }
            $ReportId = $reports.Id
        }

        # Workspace discovery
        $workspaceId = $null
        $workspacesResponse = Invoke-PowerBIRestMethod -Url "admin/groups?`$expand=reports" -Method Get -ErrorAction Stop | ConvertFrom-Json
        foreach ($workspace in $workspacesResponse.value) {
            if ($workspace.reports | Where-Object { $_.id -eq $ReportId }) { $workspaceId = $workspace.id; break }
        }
        if (-not $workspaceId) { throw "Workspace for report $ReportId not found (admin permission required)." }

        # Resolve principal id
        $principalId = $null
        $principalName = $null
        if ($EntraGroupId) { $principalId = $EntraGroupId; $principalName = $EntraGroupId }
        elseif ($EntraGroup) {
            if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Groups)) {
                Install-Module -Name Microsoft.Graph.Groups -Scope CurrentUser -Force -ErrorAction Stop
            }
            Import-Module Microsoft.Graph.Groups -ErrorAction Stop
            $ctx = $null; try { $ctx = Get-MgContext -ErrorAction SilentlyContinue } catch {}
            if (-not $ctx) { Connect-MgGraph -Scopes Group.Read.All -NoWelcome -ErrorAction Stop | Out-Null }
            $safeName = $EntraGroup.Replace("'","''")
            $mgGroup = Get-MgGroup -Filter "displayName eq '$safeName'" -ConsistencyLevel eventual -ErrorAction Stop
            if (-not $mgGroup) { throw "Entra group not found: $EntraGroup" }
            if ($mgGroup -is [array] -and $mgGroup.Count -gt 1) { throw "Multiple groups found named '$EntraGroup'. Use -EntraGroupId." }
            $principalId = $mgGroup.Id; $principalName = $EntraGroup
        } else { throw 'Provide -EntraGroup or -EntraGroupId.' }

        $url = "groups/$workspaceId/reports/$ReportId/users/$principalId"
        if ($PSCmdlet.ShouldProcess("Report $ReportId", "Revoke access for $principalId")) {
            Write-Verbose "Revoking access: $url"
            Invoke-PowerBIRestMethod -Url $url -Method Delete -ErrorAction Stop | Out-Null
        }

        $result = [PSCustomObject]@{
            ReportName    = $ReportName
            WorkspaceId   = $workspaceId
            ReportId      = $ReportId
            RevokedFrom   = $principalName
            RevokedFromId = $principalId
            Status        = 'Revoked'
        }
        if ($PassThru) { return $result } else { $result | Out-String | Write-Verbose }
        $result
    } catch {
        Write-Error "Failed to revoke report access: $_"
        return $null
    }
}
