function Write-FinOpsHtmlReport {
    <#
    .SYNOPSIS
        Generates an HTML format report from orchestrator object.
    
    .DESCRIPTION
        Creates a styled HTML report with customer information, check results, and metrics.
        The HTML report is more visually appealing than the Markdown format and better suited
        for email distribution or web viewing.
    
    .PARAMETER Path
        Path where the HTML report file will be saved.
    
    .PARAMETER OrchestratorObject
        The orchestrator result object containing customer info, checks, and metrics.
    
    .EXAMPLE
        $result = Invoke-FinOpsOnboarding -TenantId $tid -ApplicationId $aid -ClientSecret $secret `
            -CustomerName "Contoso" -PrimaryDomain "contoso.com" -PassThru
        Write-FinOpsHtmlReport -Path "./Reports/report.html" -OrchestratorObject $result
    
    .OUTPUTS
        String - Path to the generated HTML file
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        
        [Parameter(Mandatory)]
        $OrchestratorObject
    )
    
    $o = $OrchestratorObject
    $checks = $o.Checks
    
    # Helper function to get status badge
    function Get-StatusBadge {
        param([bool]$Success)
        if ($Success) {
            return '<span class="badge success">✅ Success</span>'
        } else {
            return '<span class="badge failure">❌ Failed</span>'
        }
    }
    
    # Build HTML
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Azure FinOps Onboarding Report - $($o.Customer.Name)</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            line-height: 1.6;
            color: #333;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            padding: 20px;
        }
        
        .container {
            max-width: 1200px;
            margin: 0 auto;
            background: white;
            border-radius: 10px;
            box-shadow: 0 10px 40px rgba(0,0,0,0.2);
            overflow: hidden;
        }
        
        .header {
            background: linear-gradient(135deg, #0078d4 0%, #00bcf2 100%);
            color: white;
            padding: 30px;
        }
        
        .header h1 {
            margin-bottom: 10px;
            font-size: 2em;
        }
        
        .header .meta {
            opacity: 0.9;
            font-size: 0.9em;
        }
        
        .content {
            padding: 30px;
        }
        
        .section {
            margin-bottom: 30px;
        }
        
        .section h2 {
            color: #0078d4;
            border-bottom: 2px solid #0078d4;
            padding-bottom: 10px;
            margin-bottom: 20px;
        }
        
        .info-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 15px;
            margin-bottom: 20px;
        }
        
        .info-item {
            background: #f5f5f5;
            padding: 15px;
            border-radius: 5px;
            border-left: 4px solid #0078d4;
        }
        
        .info-item .label {
            font-weight: bold;
            color: #666;
            font-size: 0.85em;
            margin-bottom: 5px;
        }
        
        .info-item .value {
            font-size: 1.1em;
            color: #333;
        }
        
        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 15px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        }
        
        th {
            background: #0078d4;
            color: white;
            padding: 12px;
            text-align: left;
            font-weight: 600;
        }
        
        td {
            padding: 12px;
            border-bottom: 1px solid #e0e0e0;
        }
        
        tr:hover {
            background-color: #f5f5f5;
        }
        
        .badge {
            display: inline-block;
            padding: 5px 12px;
            border-radius: 20px;
            font-size: 0.85em;
            font-weight: 600;
        }
        
        .badge.success {
            background: #d4edda;
            color: #155724;
        }
        
        .badge.failure {
            background: #f8d7da;
            color: #721c24;
        }
        
        .metrics {
            font-size: 0.9em;
            color: #666;
        }
        
        .alert {
            background: #fff3cd;
            border-left: 4px solid #ffc107;
            padding: 15px;
            margin: 15px 0;
            border-radius: 5px;
        }
        
        .alert.error {
            background: #f8d7da;
            border-left-color: #dc3545;
        }
        
        .alert h3 {
            margin-bottom: 10px;
            color: #721c24;
        }
        
        .footer {
            background: #f5f5f5;
            padding: 20px;
            text-align: center;
            color: #666;
            font-size: 0.9em;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>Azure FinOps Onboarding Report</h1>
            <div class="meta">
                Generated: $($o.GeneratedAt) | Tool Version: $($o.ToolVersion)
            </div>
        </div>
        
        <div class="content">
            <div class="section">
                <h2>Customer Information</h2>
                <div class="info-grid">
                    <div class="info-item">
                        <div class="label">Customer Name</div>
                        <div class="value">$($o.Customer.Name)</div>
                    </div>
                    <div class="info-item">
                        <div class="label">Primary Domain</div>
                        <div class="value">$($o.Customer.PrimaryDomain)</div>
                    </div>
                    <div class="info-item">
                        <div class="label">Tenant ID</div>
                        <div class="value">$($o.Customer.TenantId)</div>
                    </div>
                    <div class="info-item">
                        <div class="label">Application ID</div>
                        <div class="value">$($o.Customer.ApplicationId)</div>
                    </div>
                    <div class="info-item">
                        <div class="label">Enterprise Agreement</div>
                        <div class="value">$($o.Customer.IsEA)</div>
                    </div>
"@
    
    # Add optional fields
    if ($o.Customer.CompanyName) {
        $html += @"

                    <div class="info-item">
                        <div class="label">Company Name</div>
                        <div class="value">$($o.Customer.CompanyName)</div>
                    </div>
"@
    }
    
    if ($o.Customer.Country) {
        $html += @"

                    <div class="info-item">
                        <div class="label">Country</div>
                        <div class="value">$($o.Customer.Country)</div>
                    </div>
"@
    }
    
    if ($o.Customer.TenantName) {
        $html += @"

                    <div class="info-item">
                        <div class="label">Tenant Name</div>
                        <div class="value">$($o.Customer.TenantName)</div>
                    </div>
"@
    }
    
    $html += @"

                </div>
            </div>
            
            <div class="section">
                <h2>Identifiers</h2>
                <div class="info-grid">
                    <div class="info-item">
                        <div class="label">Enrollment ID</div>
                        <div class="value">$($o.Identifiers.EnrollmentId)</div>
                    </div>
                    <div class="info-item">
                        <div class="label">MCA Billing ID</div>
                        <div class="value">$($o.Identifiers.MCABillingId)</div>
                    </div>
                    <div class="info-item">
                        <div class="label">Secret Name</div>
                        <div class="value">$($o.Identifiers.SecretName)</div>
                    </div>
                    <div class="info-item">
                        <div class="label">Secret Expiry</div>
                        <div class="value">$($o.Identifiers.SecretExpiry)</div>
                    </div>
                </div>
            </div>
            
            <div class="section">
                <h2>Check Results</h2>
                <table>
                    <thead>
                        <tr>
                            <th>Check Name</th>
                            <th>Status</th>
                            <th>Metrics</th>
                        </tr>
                    </thead>
                    <tbody>
"@
    
    # Add check rows
    foreach ($c in $checks) {
        $statusBadge = Get-StatusBadge -Success $c.Success
        $metricStr = if ($c.Metrics) {
            ($c.Metrics.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" }) -join ', '
        } else {
            'N/A'
        }
        
        $html += @"

                        <tr>
                            <td><strong>$($c.Name)</strong></td>
                            <td>$statusBadge</td>
                            <td class="metrics">$metricStr</td>
                        </tr>
"@
    }
    
    $html += @"

                    </tbody>
                </table>
            </div>
"@
    
    # Add failed checks section if any
    $failed = $checks | Where-Object { -not $_.Success }
    if ($failed) {
        $html += @"

            <div class="section">
                <h2>Failed Check Details</h2>
"@
        
        foreach ($f in $failed) {
            $html += @"

                <div class="alert error">
                    <h3>$($f.Name)</h3>
                    <p><strong>Error:</strong> $($f.Error)</p>
                </div>
"@
        }
        
        $html += @"

            </div>
"@
    }
    
    $html += @"

        </div>
        
        <div class="footer">
            Azure FinOps Onboarding Module v$($o.ToolVersion) © Crayon
        </div>
    </div>
</body>
</html>
"@
    
    # Write to file
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    
    $html | Out-File -FilePath $Path -Encoding utf8
    Write-Verbose "HTML report written: $Path"
    
    return $Path
}
