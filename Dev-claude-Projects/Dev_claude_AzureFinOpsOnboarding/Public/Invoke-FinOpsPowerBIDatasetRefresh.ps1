function Invoke-FinOpsPowerBIDatasetRefresh {
    <#
    .SYNOPSIS
        Triggers a refresh for a Power BI dataset.

    .DESCRIPTION
        Initiates a dataset refresh operation. Supports both direct API calls and
        MCP delegate pattern for AI agent integration.

    .PARAMETER DatasetId
        GUID of the dataset to refresh.

    .PARAMETER WorkspaceId
        GUID of the workspace containing the dataset.

    .PARAMETER Wait
        Wait for the refresh to complete (polls status).

    .PARAMETER UsePowerBIMcp
        Use registered MCP delegates instead of direct Power BI API calls.

    .EXAMPLE
        Invoke-FinOpsPowerBIDatasetRefresh -DatasetId "33333333-3333-3333-3333-333333333333" -WorkspaceId "11111111-1111-1111-1111-111111111111"

    .EXAMPLE
        Invoke-FinOpsPowerBIDatasetRefresh -DatasetId "33333333-3333-3333-3333-333333333333" -WorkspaceId "11111111-1111-1111-1111-111111111111" -UsePowerBIMcp -Wait
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string]$DatasetId,
        
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string]$WorkspaceId,
        
        [switch]$Wait,
        [switch]$UsePowerBIMcp
    )

    try {
        if ($UsePowerBIMcp) {
            Write-Verbose "Triggering dataset refresh via Power BI MCP"
            
            if ($PSCmdlet.ShouldProcess("Dataset $DatasetId", "Refresh")) {
                $result = Invoke-FinOpsPowerBIMcp -Operation RefreshDataset -Arguments @{
                    DatasetId = $DatasetId
                    WorkspaceId = $WorkspaceId
                }
                
                Write-Verbose "Dataset refresh initiated"
                if ($Wait) {
                    Write-Warning "Wait functionality requires additional MCP delegate implementation"
                }
                $result
            }
        } else {
            Write-Verbose "Triggering dataset refresh via Power BI API"
            
            if (-not (Get-Module -ListAvailable -Name MicrosoftPowerBIMgmt)) {
                Install-Module -Name MicrosoftPowerBIMgmt -Scope CurrentUser -Force -ErrorAction Stop
            }
            Import-Module MicrosoftPowerBIMgmt -ErrorAction Stop

            $token = $null
            try { $token = Get-PowerBIAccessToken -AsString -ErrorAction Stop } catch {}
            if (-not $token) {
                Connect-PowerBIServiceAccount -ErrorAction Stop | Out-Null
            }

            if ($PSCmdlet.ShouldProcess("Dataset $DatasetId", "Refresh")) {
                $url = "groups/$WorkspaceId/datasets/$DatasetId/refreshes"
                Invoke-PowerBIRestMethod -Url $url -Method Post -ErrorAction Stop | Out-Null
                
                Write-Verbose "Dataset refresh initiated"
                
                if ($Wait) {
                    Write-Verbose "Waiting for refresh to complete..."
                    $timeout = 300
                    $elapsed = 0
                    $interval = 5
                    
                    while ($elapsed -lt $timeout) {
                        Start-Sleep -Seconds $interval
                        $elapsed += $interval
                        
                        $refreshUrl = "groups/$WorkspaceId/datasets/$DatasetId/refreshes?`$top=1"
                        $refreshStatus = Invoke-PowerBIRestMethod -Url $refreshUrl -Method Get -ErrorAction Stop | ConvertFrom-Json
                        
                        if ($refreshStatus.value -and $refreshStatus.value[0].status -ne 'Unknown') {
                            $status = $refreshStatus.value[0].status
                            Write-Verbose "Refresh status: $status"
                            
                            if ($status -eq 'Completed') {
                                Write-Host "Dataset refresh completed successfully"
                                return $refreshStatus.value[0]
                            } elseif ($status -eq 'Failed') {
                                throw "Dataset refresh failed"
                            }
                        }
                    }
                    Write-Warning "Refresh status check timed out after $timeout seconds"
                }
                
                [PSCustomObject]@{
                    DatasetId = $DatasetId
                    WorkspaceId = $WorkspaceId
                    Status = 'Initiated'
                }
            }
        }
    } catch {
        Write-Error "Failed to refresh dataset: $_"
        return $null
    }
}
