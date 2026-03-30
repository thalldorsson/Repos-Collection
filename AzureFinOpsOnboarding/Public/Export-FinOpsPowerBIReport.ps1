function Export-FinOpsPowerBIReport {
    <#
    .SYNOPSIS
    Exports a Power BI report to a file (PDF/PPTX/PNG) using REST API or MCP delegate.

    .DESCRIPTION
    Supports asynchronous export job pattern. When using direct API:
      1. POST ExportTo endpoint
      2. Poll job status until Succeeded/Failed
      3. Download resourceLocation to OutputPath

    When -UsePowerBIMcp is specified, invokes registered ExportReport delegate instead.

    .PARAMETER ReportName
    Name of the report to export. Required unless ReportId is provided.

    .PARAMETER ReportId
    GUID of the report. If provided takes precedence over ReportName lookup.

    .PARAMETER WorkspaceId
    GUID of workspace containing the report. If omitted and ReportName used, will be discovered via admin API.

    .PARAMETER Format
    Export format. Supported: PDF, PPTX, PNG.

    .PARAMETER OutputPath
    Target file path. Defaults to ./<ReportName>.<lowercase format>

    .PARAMETER Pages
    Optional list of page names to export (only those pages). If omitted, all visible pages exported.

    .PARAMETER IncludeHiddenPages
    Include hidden pages in export (ignored if Pages specified).

    .PARAMETER ReportFilter
    Single report-level filter expression (DAX style) applied during export.

    .PARAMETER Locale
    Locale to apply (e.g. en-US) for export rendering.

    .PARAMETER Wait
    Wait for asynchronous export job to complete. When not specified returns immediately after job submission.

    .PARAMETER TimeoutSeconds
    Maximum time to wait when -Wait is used. Defaults to 300 seconds.

    .PARAMETER UsePowerBIMcp
    Use MCP delegate (ExportReport) instead of REST API.

    .PARAMETER PassThru
    Return result object to pipeline.

    .OUTPUTS
    PSCustomObject: ReportName, WorkspaceName, WorkspaceId, ReportId, Format, FilePath, Status
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position=0)][string]$ReportName,
        [Parameter()][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$ReportId,
        [Parameter()][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$WorkspaceId,
        [Parameter()][ValidateSet('PDF','PPTX','PNG')][string]$Format = 'PDF',
        [Parameter()][string]$OutputPath,
        [string[]]$Pages,
        [switch]$IncludeHiddenPages,
        [string]$ReportFilter,
        [string]$Locale,
        [switch]$Wait,
        [int]$TimeoutSeconds = 300,
        [switch]$UsePowerBIMcp,
        [switch]$PassThru
    )

    try {
        if ($UsePowerBIMcp) {
            if (-not $ReportId -and -not $ReportName) { throw 'Provide ReportName or ReportId for MCP export.' }
            Write-Verbose 'Using Power BI MCP ExportReport delegate'
            $args = @{ ReportId = $ReportId; WorkspaceId = $WorkspaceId; Format = $Format }
            if ($ReportName) { $args.ReportName = $ReportName }
            if ($OutputPath) { $args.OutputPath = $OutputPath }
            $delegateResult = Invoke-FinOpsPowerBIMcp -Operation ExportReport -Arguments $args
            if (-not $delegateResult) { throw 'ExportReport delegate returned no result.' }
            $result = [PSCustomObject]@{
                ReportName    = $delegateResult.ReportName
                WorkspaceId   = $delegateResult.WorkspaceId
                WorkspaceName = $delegateResult.WorkspaceName
                ReportId      = $delegateResult.ReportId
                Format        = $Format
                FilePath      = $delegateResult.FilePath
                Status        = $delegateResult.Status
            }
            if (-not $result.ReportName) { $result.ReportName = $ReportName }
            if (-not $result.WorkspaceId) { $result.WorkspaceId = $WorkspaceId }
            if (-not $result.WorkspaceName) { $result.WorkspaceName = 'Unknown' }
            if (-not $result.ReportId) { $result.ReportId = $ReportId }
            if (-not $result.FilePath) { $result.FilePath = $OutputPath }
            if (-not $result.Status) { $result.Status = 'Completed' }
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

        # Discover report if needed
        if (-not $ReportId) {
            if (-not $ReportName) { throw 'Provide ReportName or ReportId.' }
            Write-Verbose "Searching for report named '$ReportName'"
            $reports = Get-PowerBIReport -Name $ReportName -Scope Organization -ErrorAction Stop
            if (-not $reports) { throw "Report not found: $ReportName" }
            if ($reports.Count -gt 1) { throw "Multiple reports named '$ReportName'. Provide -ReportId." }
            $ReportId = $reports.Id
        }

        # Discover workspace via admin API if not provided
        if (-not $WorkspaceId) {
            Write-Verbose 'Discovering workspace ID via admin groups expansion'
            $workspacesResponse = Invoke-PowerBIRestMethod -Url "admin/groups?`$expand=reports" -Method Get -ErrorAction Stop | ConvertFrom-Json
            foreach ($workspace in $workspacesResponse.value) {
                if ($workspace.reports | Where-Object { $_.id -eq $ReportId }) { $WorkspaceId = $workspace.id; break }
            }
            if (-not $WorkspaceId) { throw "Workspace for report $ReportId not found (admin permission required)." }
        }

        # Set default output path
        if (-not $OutputPath) {
            $baseName = $ReportName
            if (-not $baseName) { $baseName = $ReportId }
            $ext = $Format.ToLower()
            $OutputPath = Join-Path -Path (Get-Location) -ChildPath "$baseName.$ext"
        }

        # Build export body with optional configuration
        $exportRequest = @{ format = $Format }
        $configNeeded = $false
        $reportConfig = @{}
        if ($Pages) {
            $configNeeded = $true
            $reportConfig.pages = @()
            foreach ($p in $Pages) { $reportConfig.pages += @{ pageName = $p } }
        }
        if ($ReportFilter) {
            $configNeeded = $true
            $reportConfig.reportLevelFilters = @(@{ filter = $ReportFilter })
        }
        $settings = @{}
        if ($IncludeHiddenPages) { $configNeeded = $true; $settings.includeHiddenPages = $true }
        if ($Locale) { $configNeeded = $true; $settings.locale = $Locale }
        if ($settings.Count -gt 0) { $reportConfig.settings = $settings }
        if ($configNeeded) { $exportRequest.powerBIReportConfiguration = $reportConfig }
        $body = $exportRequest | ConvertTo-Json -Depth 6
        $url = "groups/$WorkspaceId/reports/$ReportId/ExportTo"
        if ($PSCmdlet.ShouldProcess("Report $ReportId", "Export to $Format")) {
            Write-Verbose "Submitting export job: $url"
            $job = Invoke-PowerBIRestMethod -Url $url -Method Post -Body $body -ContentType 'application/json' -ErrorAction Stop | ConvertFrom-Json
            $jobId = $job.id
            Write-Verbose "Export job id: $jobId"
        } else {
            return
        }

        $status = 'Submitted'
        $resourceLocation = $null
        if ($Wait) {
            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 3
                $statusUrl = "groups/$WorkspaceId/reports/$ReportId/exports/$jobId"
                $jobStatus = Invoke-PowerBIRestMethod -Url $statusUrl -Method Get -ErrorAction Stop | ConvertFrom-Json
                $status = $jobStatus.status
                Write-Verbose "Job status: $status ($($jobStatus.percentComplete)%)"
                if ($status -eq 'Succeeded') { $resourceLocation = $jobStatus.resourceLocation; break }
                if ($status -eq 'Failed') { throw "Export job failed." }
            }
            if (-not $resourceLocation) { throw "Export timed out after $TimeoutSeconds seconds." }
            Write-Verbose "Downloading exported file from $resourceLocation"
            Invoke-WebRequest -Uri $resourceLocation -OutFile $OutputPath -UseBasicParsing -ErrorAction Stop
            $status = 'Completed'
        }

        $result = [PSCustomObject]@{
            ReportName   = $ReportName
            WorkspaceId  = $WorkspaceId
            WorkspaceName= $null
            ReportId     = $ReportId
            Format       = $Format
            FilePath     = if (Test-Path $OutputPath) { (Resolve-Path $OutputPath).Path } else { $OutputPath }
            Status       = $status
        }
        if ($PassThru) { return $result } else { $result | Out-String | Write-Verbose }
        $result
    } catch {
        Write-Error "Failed to export report: $_"
        return $null
    }
}
