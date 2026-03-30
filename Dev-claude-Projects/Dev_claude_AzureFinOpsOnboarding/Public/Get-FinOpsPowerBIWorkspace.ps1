function Get-FinOpsPowerBIWorkspace {
    <#
    .SYNOPSIS
        Retrieves Power BI workspace information.

    .DESCRIPTION
        Gets workspace details by ID or lists all accessible workspaces. Supports both
        direct API calls and MCP delegate pattern for AI agent integration.

    .PARAMETER WorkspaceId
        GUID of the workspace to retrieve. If omitted, lists all accessible workspaces.

    .PARAMETER Filter
        Optional filter string for workspace names (when listing all).

    .PARAMETER UsePowerBIMcp
        Use registered MCP delegates instead of direct Power BI API calls.

    .EXAMPLE
        Get-FinOpsPowerBIWorkspace -WorkspaceId "11111111-1111-1111-1111-111111111111"

    .EXAMPLE
        Get-FinOpsPowerBIWorkspace -Filter "FinOps"

    .EXAMPLE
        Get-FinOpsPowerBIWorkspace -UsePowerBIMcp
    #>
    [CmdletBinding()]
    param(
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string]$WorkspaceId,
        
        [string]$Filter,
        [switch]$UsePowerBIMcp
    )

    try {
        if ($UsePowerBIMcp) {
            Write-Verbose "Retrieving workspace via Power BI MCP"
            
            if ($WorkspaceId) {
                Invoke-FinOpsPowerBIMcp -Operation GetWorkspace -Arguments @{
                    WorkspaceId = $WorkspaceId
                }
            } else {
                $args = @{}
                if ($Filter) { $args.Filter = $Filter }
                Invoke-FinOpsPowerBIMcp -Operation GetWorkspaces -Arguments $args
            }
        } else {
            Write-Verbose "Retrieving workspace via Power BI API"
            
            if (-not (Get-Module -ListAvailable -Name MicrosoftPowerBIMgmt)) {
                Install-Module -Name MicrosoftPowerBIMgmt -Scope CurrentUser -Force -ErrorAction Stop
            }
            Import-Module MicrosoftPowerBIMgmt -ErrorAction Stop

            $token = $null
            try { $token = Get-PowerBIAccessToken -AsString -ErrorAction Stop } catch {}
            if (-not $token) {
                Connect-PowerBIServiceAccount -ErrorAction Stop | Out-Null
            }

            if ($WorkspaceId) {
                Get-PowerBIWorkspace -Id $WorkspaceId -Scope Organization -ErrorAction Stop
            } else {
                $workspaces = Get-PowerBIWorkspace -Scope Organization -ErrorAction Stop
                if ($Filter) {
                    $workspaces | Where-Object { $_.Name -like "*$Filter*" }
                } else {
                    $workspaces
                }
            }
        }
    } catch {
        Write-Error "Failed to retrieve workspace: $_"
        return $null
    }
}
