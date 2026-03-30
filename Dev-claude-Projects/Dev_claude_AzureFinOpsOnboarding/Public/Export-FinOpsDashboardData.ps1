function Export-FinOpsDashboardData {
    <#
    .SYNOPSIS
        Exports FinOps onboarding data in a format suitable for dashboard integration.
    
    .DESCRIPTION
        Transforms onboarding orchestrator data into formats compatible with
        Power BI, Azure Dashboard, or other visualization tools.
        Supports multiple output formats including CSV, JSON, and Excel-ready format.
    
    .PARAMETER OrchestratorObject
        The orchestrator result object from Invoke-FinOpsOnboarding.
    
    .PARAMETER Path
        Path where the dashboard data file will be saved.
    
    .PARAMETER Format
        Output format: 'CSV', 'Json', or 'PowerBI'. Default is 'Json'.
    
    .EXAMPLE
        $result = Invoke-FinOpsOnboarding -TenantId $tid -ApplicationId $aid -ClientSecret $secret `
            -CustomerName "Contoso" -PrimaryDomain "contoso.com" -PassThru
        Export-FinOpsDashboardData -OrchestratorObject $result -Path "./dashboard-data.json" -Format Json
    
    .EXAMPLE
        # Export as CSV for Excel
        Export-FinOpsDashboardData -OrchestratorObject $result -Path "./dashboard-data.csv" -Format CSV
    
    .OUTPUTS
        String - Path to the generated file
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $OrchestratorObject,
        
        [Parameter(Mandatory)]
        [string]$Path,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('CSV', 'Json', 'PowerBI')]
        [string]$Format = 'Json'
    )
    
    Write-Verbose "Exporting dashboard data in $Format format"
    
    $o = $OrchestratorObject
    
    # Create flattened data structure suitable for visualization
    $dashboardData = @()
    
    # Add check results as rows
    foreach ($check in $o.Checks) {
        $row = [PSCustomObject]@{
            CustomerName = $o.Customer.Name
            TenantId = $o.Customer.TenantId
            PrimaryDomain = $o.Customer.PrimaryDomain
            IsEA = $o.Customer.IsEA
            CheckName = $check.Name
            CheckSuccess = $check.Success
            CheckError = if ($check.Error) { $check.Error } else { '' }
            Timestamp = $o.GeneratedAt
            ToolVersion = $o.ToolVersion
        }
        
        # Add metrics as separate columns
        if ($check.Metrics) {
            foreach ($metric in $check.Metrics.GetEnumerator()) {
                $row | Add-Member -NotePropertyName "Metric_$($metric.Key)" -NotePropertyValue $metric.Value -Force
            }
        }
        
        $dashboardData += $row
    }
    
    # Add summary row
    $summaryRow = [PSCustomObject]@{
        CustomerName = $o.Customer.Name
        TenantId = $o.Customer.TenantId
        PrimaryDomain = $o.Customer.PrimaryDomain
        IsEA = $o.Customer.IsEA
        CheckName = 'SUMMARY'
        CheckSuccess = ($o.Checks | Where-Object { -not $_.Success }).Count -eq 0
        CheckError = ''
        Timestamp = $o.GeneratedAt
        ToolVersion = $o.ToolVersion
        Metric_TotalChecks = $o.Checks.Count
        Metric_PassedChecks = ($o.Checks | Where-Object { $_.Success }).Count
        Metric_FailedChecks = ($o.Checks | Where-Object { -not $_.Success }).Count
    }
    
    $dashboardData += $summaryRow
    
    # Export based on format
    try {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        
        switch ($Format) {
            'CSV' {
                Write-Verbose "Exporting as CSV format"
                $dashboardData | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
            }
            'Json' {
                Write-Verbose "Exporting as JSON format"
                $exportData = @{
                    SchemaVersion = '1.0'
                    ExportedAt = (Get-Date).ToUniversalTime().ToString('o')
                    DataType = 'FinOpsDashboard'
                    Customer = $o.Customer
                    Identifiers = $o.Identifiers
                    Checks = $dashboardData
                }
                $exportData | ConvertTo-Json -Depth 10 | Out-File -FilePath $Path -Encoding UTF8
            }
            'PowerBI' {
                Write-Verbose "Exporting as PowerBI-optimized JSON format"
                # PowerBI format with specific structure
                $powerBIData = @{
                    rows = @($dashboardData)
                }
                $powerBIData | ConvertTo-Json -Depth 10 | Out-File -FilePath $Path -Encoding UTF8
            }
        }
        
        Write-Verbose "Dashboard data exported successfully to: $Path"
        Write-Verbose "Total rows: $($dashboardData.Count)"
        
        return $Path
        
    } catch {
        Write-Error "Failed to export dashboard data: $_"
        return $null
    }
}
