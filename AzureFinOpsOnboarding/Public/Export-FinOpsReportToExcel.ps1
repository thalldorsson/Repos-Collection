function Export-FinOpsReportToExcel {
    <#
    .SYNOPSIS
        Exports FinOps onboarding results to a formatted Excel workbook.
    
    .DESCRIPTION
        Creates a multi-worksheet Excel workbook with formatted data, conditional formatting,
        and optional charts. Requires the ImportExcel module.
        
        Worksheets created:
        - Summary: High-level overview with pass/fail metrics
        - Validation: Detailed validation check results
        - Subscriptions: Subscription-level details
        - Errors: Failed checks with error details
        - Costs: Cost data (if available)
    
    .PARAMETER Path
        Output path for the Excel file (.xlsx).
    
    .PARAMETER OrchestratorObject
        The orchestrator result object from Invoke-FinOpsOnboarding or Start-FinOpsMultiSubscriptionOnboarding.
    
    .PARAMETER IncludeCharts
        Add charts and visualizations to the workbook.
    
    .PARAMETER AutoOpen
        Automatically open the Excel file after creation.
    
    .EXAMPLE
        $result = Invoke-FinOpsOnboarding -TenantId $tid -CustomerName "Contoso" -PassThru
        Export-FinOpsReportToExcel -Path "report.xlsx" -OrchestratorObject $result -IncludeCharts
    
    .EXAMPLE
        $result = Start-FinOpsMultiSubscriptionOnboarding -SubscriptionIds $subs -Token $token
        Export-FinOpsReportToExcel -Path "multi-sub-report.xlsx" -OrchestratorObject $result -AutoOpen
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        
        [Parameter(Mandatory)]
        [PSCustomObject]$OrchestratorObject,
        
        [switch]$IncludeCharts,
        [switch]$AutoOpen
    )
    
    # Check for ImportExcel module
    if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
        Write-Warning "ImportExcel module not found. Installing..."
        try {
            Install-Module -Name ImportExcel -Scope CurrentUser -Force -ErrorAction Stop
            Write-Host "ImportExcel module installed successfully" -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to install ImportExcel module: $_"
            return
        }
    }
    
    Import-Module ImportExcel -ErrorAction Stop
    
    # Remove existing file if it exists
    if (Test-Path $Path) {
        Remove-Item $Path -Force
        Write-Verbose "Removed existing file: $Path"
    }
    
    Write-Host "Creating Excel workbook: $Path" -ForegroundColor Cyan
    
    # ===== SUMMARY WORKSHEET =====
    Write-Verbose "Creating Summary worksheet..."
    
    $summaryData = @()
    
    # Basic information
    $summaryData += [PSCustomObject]@{
        Metric = "Customer Name"
        Value = if ($OrchestratorObject.CustomerName) { $OrchestratorObject.CustomerName } else { "N/A" }
    }
    
    $summaryData += [PSCustomObject]@{
        Metric = "Tenant ID"
        Value = if ($OrchestratorObject.TenantId) { $OrchestratorObject.TenantId } else { "N/A" }
    }
    
    $summaryData += [PSCustomObject]@{
        Metric = "Processing Mode"
        Value = if ($OrchestratorObject.ProcessingMode) { $OrchestratorObject.ProcessingMode } else { "Standard" }
    }
    
    $summaryData += [PSCustomObject]@{
        Metric = "PowerShell Version"
        Value = if ($OrchestratorObject.PowerShellVersion) { $OrchestratorObject.PowerShellVersion } else { $PSVersionTable.PSVersion.ToString() }
    }
    
    $summaryData += [PSCustomObject]@{
        Metric = "Report Generated"
        Value = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }
    
    # Add blank row
    $summaryData += [PSCustomObject]@{ Metric = ""; Value = "" }
    
    # Performance metrics
    if ($OrchestratorObject.SubscriptionCount) {
        $summaryData += [PSCustomObject]@{
            Metric = "Subscriptions Processed"
            Value = $OrchestratorObject.SubscriptionCount
        }
        
        $summaryData += [PSCustomObject]@{
            Metric = "Successful"
            Value = $OrchestratorObject.SuccessCount
        }
        
        $summaryData += [PSCustomObject]@{
            Metric = "Failed"
            Value = $OrchestratorObject.FailureCount
        }
        
        if ($OrchestratorObject.TotalDurationSeconds) {
            $summaryData += [PSCustomObject]@{
                Metric = "Total Duration (seconds)"
                Value = [math]::Round($OrchestratorObject.TotalDurationSeconds, 2)
            }
        }
        
        if ($OrchestratorObject.AvgSecondsPerSubscription) {
            $summaryData += [PSCustomObject]@{
                Metric = "Avg Time per Subscription (seconds)"
                Value = [math]::Round($OrchestratorObject.AvgSecondsPerSubscription, 2)
            }
        }
    }
    
    # Export Summary worksheet
    $summaryData | Export-Excel -Path $Path -WorksheetName "Summary" -AutoSize -TableName "SummaryTable" `
        -TableStyle Medium2 -FreezeTopRow -BoldTopRow
    
    # ===== VALIDATION WORKSHEET =====
    Write-Verbose "Creating Validation worksheet..."
    
    $validationData = @()
    
    if ($OrchestratorObject.Results) {
        foreach ($subResult in $OrchestratorObject.Results) {
            $subId = if ($subResult.SubscriptionId) { $subResult.SubscriptionId } else { "N/A" }
            
            # Costs check
            if ($subResult.Checks.Costs) {
                $validationData += [PSCustomObject]@{
                    SubscriptionId = $subId
                    CheckType = "Costs"
                    Status = if ($subResult.Checks.Costs.Success) { "Pass" } else { "Fail" }
                    ErrorDetail = $subResult.Checks.Costs.ErrorDetail
                }
            }
            
            # Emissions check
            if ($subResult.Checks.Emissions) {
                $validationData += [PSCustomObject]@{
                    SubscriptionId = $subId
                    CheckType = "Emissions"
                    Status = if ($subResult.Checks.Emissions.Success) { "Pass" } else { "Fail" }
                    ErrorDetail = $subResult.Checks.Emissions.ErrorDetail
                }
            }
            
            # Reservations check
            if ($subResult.Checks.Reservations) {
                $validationData += [PSCustomObject]@{
                    SubscriptionId = $subId
                    CheckType = "Reservations"
                    Status = if ($subResult.Checks.Reservations.Success) { "Pass" } else { "Fail" }
                    ErrorDetail = $subResult.Checks.Reservations.ErrorDetail
                }
            }
        }
    }
    elseif ($OrchestratorObject.CheckResults) {
        # Single subscription format
        foreach ($check in $OrchestratorObject.CheckResults) {
            $validationData += [PSCustomObject]@{
                SubscriptionId = "N/A"
                CheckType = $check.Name
                Status = if ($check.Success) { "Pass" } else { "Fail" }
                ErrorDetail = $check.ErrorDetail
            }
        }
    }
    
    if ($validationData.Count -gt 0) {
        $validationData | Export-Excel -Path $Path -WorksheetName "Validation" -AutoSize -TableName "ValidationTable" `
            -TableStyle Medium2 -FreezeTopRow -BoldTopRow `
            -ConditionalText $(
                New-ConditionalText -Text "Pass" -BackgroundColor LightGreen -ConditionalTextColor Black
                New-ConditionalText -Text "Fail" -BackgroundColor LightCoral -ConditionalTextColor Black
            )
    }
    
    # ===== SUBSCRIPTIONS WORKSHEET =====
    Write-Verbose "Creating Subscriptions worksheet..."
    
    $subscriptionData = @()
    
    if ($OrchestratorObject.Results) {
        foreach ($subResult in $OrchestratorObject.Results) {
            $subscriptionData += [PSCustomObject]@{
                SubscriptionId = $subResult.SubscriptionId
                OverallStatus = if ($subResult.Success) { "Success" } else { "Failed" }
                DurationSeconds = if ($subResult.DurationSeconds) { [math]::Round($subResult.DurationSeconds, 2) } else { 0 }
                ErrorCount = if ($subResult.Errors) { $subResult.Errors.Count } else { 0 }
            }
        }
    }
    
    if ($subscriptionData.Count -gt 0) {
        $subscriptionData | Export-Excel -Path $Path -WorksheetName "Subscriptions" -AutoSize -TableName "SubscriptionsTable" `
            -TableStyle Medium2 -FreezeTopRow -BoldTopRow `
            -ConditionalText $(
                New-ConditionalText -Text "Success" -BackgroundColor LightGreen -ConditionalTextColor Black
                New-ConditionalText -Text "Failed" -BackgroundColor LightCoral -ConditionalTextColor Black
            )
    }
    
    # ===== ERRORS WORKSHEET =====
    Write-Verbose "Creating Errors worksheet..."
    
    $errorData = @()
    
    if ($OrchestratorObject.Results) {
        foreach ($subResult in $OrchestratorObject.Results) {
            if ($subResult.Errors -and $subResult.Errors.Count -gt 0) {
                foreach ($error in $subResult.Errors) {
                    $errorData += [PSCustomObject]@{
                        SubscriptionId = $subResult.SubscriptionId
                        ErrorMessage = $error
                    }
                }
            }
        }
    }
    
    if ($errorData.Count -gt 0) {
        $errorData | Export-Excel -Path $Path -WorksheetName "Errors" -AutoSize -TableName "ErrorsTable" `
            -TableStyle Medium2 -FreezeTopRow -BoldTopRow
    }
    
    # ===== ADD CHARTS (if requested) =====
    if ($IncludeCharts -and $validationData.Count -gt 0) {
        Write-Verbose "Adding charts..."
        
        try {
            # Get Excel package for chart manipulation
            $excel = Open-ExcelPackage -Path $Path
            
            # Add chart to Summary worksheet
            $summaryWs = $excel.Workbook.Worksheets["Summary"]
            if ($summaryWs) {
                # Calculate pass/fail counts
                $passCount = ($validationData | Where-Object { $_.Status -eq "Pass" }).Count
                $failCount = ($validationData | Where-Object { $_.Status -eq "Fail" }).Count
                
                # Add data for chart
                $chartStartRow = $summaryData.Count + 3
                $summaryWs.Cells["A$chartStartRow"].Value = "Status"
                $summaryWs.Cells["B$chartStartRow"].Value = "Count"
                $summaryWs.Cells["A$($chartStartRow + 1)"].Value = "Pass"
                $summaryWs.Cells["B$($chartStartRow + 1)"].Value = $passCount
                $summaryWs.Cells["A$($chartStartRow + 2)"].Value = "Fail"
                $summaryWs.Cells["B$($chartStartRow + 2)"].Value = $failCount
                
                # Create pie chart
                $chart = $summaryWs.Drawings.AddChart("ValidationChart", [OfficeOpenXml.Drawing.Chart.eChartType]::Pie)
                $chart.Title.Text = "Validation Results"
                $chart.SetPosition($chartStartRow - 1, 0, 3, 0)
                $chart.SetSize(400, 300)
                
                $series = $chart.Series.Add("B$($chartStartRow + 1):B$($chartStartRow + 2)", "A$($chartStartRow + 1):A$($chartStartRow + 2)")
                $series.Header = "Results"
            }
            
            Close-ExcelPackage $excel -Show:$false
        }
        catch {
            Write-Warning "Failed to add charts: $_"
            # Continue without charts - report is still valid
        }
    }
    
    Write-Host "Excel workbook created successfully: $Path" -ForegroundColor Green
    
    # Auto-open if requested
    if ($AutoOpen) {
        Write-Host "Opening Excel workbook..." -ForegroundColor Cyan
        Start-Process $Path
    }
    
    return [PSCustomObject]@{
        Path = $Path
        WorksheetsCreated = @("Summary", "Validation", "Subscriptions", "Errors")
        TotalRows = $validationData.Count + $subscriptionData.Count + $errorData.Count
        Success = $true
    }
}
