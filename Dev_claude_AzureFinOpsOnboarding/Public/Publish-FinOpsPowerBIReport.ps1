function Publish-FinOpsPowerBIReport {
    <#
    .SYNOPSIS
        Publishes a Power BI report (.pbix file) to a workspace.

    .DESCRIPTION
        Uploads a .pbix file to a specified Power BI workspace. Supports both direct API
        calls and MCP delegate pattern for AI agent integration.

    .PARAMETER FilePath
        Path to the .pbix file to publish.

    .PARAMETER WorkspaceId
        GUID of the target workspace.

    .PARAMETER ReportName
        Optional display name for the report. Defaults to filename without extension.

    .PARAMETER UsePowerBIMcp
        Use registered MCP delegates instead of direct Power BI API calls.

    .PARAMETER PassThru
        Return the published report object.

    .EXAMPLE
        Publish-FinOpsPowerBIReport -FilePath "C:\Reports\FinOps.pbix" -WorkspaceId "11111111-1111-1111-1111-111111111111"

    .EXAMPLE
        Publish-FinOpsPowerBIReport -FilePath ".\Dashboard.pbix" -WorkspaceId "11111111-1111-1111-1111-111111111111" -UsePowerBIMcp
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$FilePath,
        
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string]$WorkspaceId,
        
        [string]$ReportName,
        [switch]$UsePowerBIMcp,
        [switch]$PassThru
    )

    try {
        $resolvedPath = Resolve-Path $FilePath
        if (-not $ReportName) {
            $ReportName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedPath)
        }

        if ($UsePowerBIMcp) {
            Write-Verbose "Publishing report via Power BI MCP"
            
            if ($PSCmdlet.ShouldProcess("$ReportName", "Publish to workspace $WorkspaceId")) {
                $result = Invoke-FinOpsPowerBIMcp -Operation PublishReport -Arguments @{
                    FilePath = $resolvedPath.Path
                    WorkspaceId = $WorkspaceId
                    ReportName = $ReportName
                }
                
                Write-Verbose "Report published: $($result.Name) (ID: $($result.ReportId))"
                if ($PassThru) { return $result }
                $result
            }
        } else {
            Write-Verbose "Publishing report via Power BI API"
            
            if (-not (Get-Module -ListAvailable -Name MicrosoftPowerBIMgmt)) {
                Install-Module -Name MicrosoftPowerBIMgmt -Scope CurrentUser -Force -ErrorAction Stop
            }
            Import-Module MicrosoftPowerBIMgmt -ErrorAction Stop

            $token = $null
            try { $token = Get-PowerBIAccessToken -AsString -ErrorAction Stop } catch {}
            if (-not $token) {
                Connect-PowerBIServiceAccount -ErrorAction Stop | Out-Null
            }

            if ($PSCmdlet.ShouldProcess("$ReportName", "Publish to workspace $WorkspaceId")) {
                $report = New-PowerBIReport -Path $resolvedPath.Path -WorkspaceId $WorkspaceId -Name $ReportName -ErrorAction Stop
                
                Write-Verbose "Report published: $($report.Name) (ID: $($report.Id))"
                if ($PassThru) { return $report }
                $report
            }
        }
    } catch {
        Write-Error "Failed to publish report: $_"
        return $null
    }
}
