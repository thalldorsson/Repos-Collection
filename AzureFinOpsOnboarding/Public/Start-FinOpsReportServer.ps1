function Start-FinOpsReportServer {
    <#
    .SYNOPSIS
    Starts a local web server to display FinOps onboarding reports in a browser.

    .DESCRIPTION
    Launches a lightweight web server (using Pode module) that serves an interactive HTML dashboard
    for viewing FinOps onboarding results. Supports live refresh, multiple report history, and
    export functionality.

    .PARAMETER OrchestratorObject
    The result object from Invoke-FinOpsOnboarding (obtained with -PassThru).

    .PARAMETER Port
    TCP port for the web server. Defaults to 8080.

    .PARAMETER AutoOpen
    Automatically open the dashboard in the default web browser.

    .PARAMETER KeepAlive
    Keep the server running indefinitely. Press Ctrl+C to stop.
    If not specified, server runs until manually stopped.

    .PARAMETER ReportHistoryPath
    Path to directory where historical reports are stored. If provided, displays
    a list of past reports with timestamps.

    .EXAMPLE
    $result = Invoke-FinOpsOnboarding -CustomerName "Contoso" -PassThru
    Start-FinOpsReportServer -OrchestratorObject $result -AutoOpen

    .EXAMPLE
    # View historical reports
    Start-FinOpsReportServer -ReportHistoryPath ".\Reports" -AutoOpen -Port 9090

    .OUTPUTS
    Server instance object with Stop() method
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]
        [PSCustomObject]$OrchestratorObject,

        [Parameter()]
        [ValidateRange(1024, 65535)]
        [int]$Port = 8080,

        [Parameter()]
        [switch]$AutoOpen,

        [Parameter()]
        [switch]$KeepAlive,

        [Parameter()]
        [string]$ReportHistoryPath
    )

    begin {
        # Check if Pode module is available
        $podeModule = Get-Module -ListAvailable -Name Pode | Select-Object -First 1
        if (-not $podeModule) {
            Write-Warning "Pode module not found. Installing Pode..."
            try {
                Install-Module -Name Pode -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
                Write-Verbose "Pode module installed successfully"
            } catch {
                Write-Error "Failed to install Pode module: $_. Please install manually: Install-Module -Name Pode"
                return
            }
        }

        Import-Module Pode -ErrorAction Stop
        Write-Verbose "Pode module loaded"
    }

    process {
        # Store report data in script scope for access by routes
        $script:CurrentReport = $OrchestratorObject
        $script:ReportHistory = @()

        # Load historical reports if path provided
        if ($ReportHistoryPath -and (Test-Path $ReportHistoryPath)) {
            Write-Verbose "Loading report history from: $ReportHistoryPath"
            $reportFiles = Get-ChildItem -Path $ReportHistoryPath -Filter "*.json" -File | Sort-Object LastWriteTime -Descending
            foreach ($file in $reportFiles) {
                try {
                    $historyItem = Get-Content $file.FullName -Raw | ConvertFrom-Json
                    $script:ReportHistory += @{
                        Timestamp = $file.LastWriteTime
                        Path = $file.FullName
                        CustomerName = $historyItem.Customer.Name
                        Data = $historyItem
                    }
                } catch {
                    Write-Warning "Failed to load report: $($file.Name)"
                }
            }
            Write-Verbose "Loaded $($script:ReportHistory.Count) historical reports"
        }

        # Start Pode server
        $server = Start-PodeServer -ScriptBlock {
            # Add HTTP listener
            Add-PodeEndpoint -Address localhost -Port $using:Port -Protocol Http

            # Serve static CSS/JS if needed (embedded inline for simplicity)
            $css = @"
body {
    font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
    margin: 0;
    padding: 20px;
    background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
    color: #333;
}
.container {
    max-width: 1200px;
    margin: 0 auto;
    background: white;
    padding: 30px;
    border-radius: 12px;
    box-shadow: 0 8px 32px rgba(0,0,0,0.1);
}
h1 {
    color: #667eea;
    border-bottom: 3px solid #667eea;
    padding-bottom: 10px;
}
.info-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
    gap: 20px;
    margin: 20px 0;
}
.info-card {
    background: #f8f9fa;
    padding: 15px;
    border-radius: 8px;
    border-left: 4px solid #667eea;
}
.info-card label {
    font-weight: bold;
    color: #666;
    display: block;
    margin-bottom: 5px;
}
.status-badge {
    display: inline-block;
    padding: 5px 12px;
    border-radius: 4px;
    font-weight: bold;
    font-size: 14px;
}
.status-success {
    background: #d4edda;
    color: #155724;
}
.status-failed {
    background: #f8d7da;
    color: #721c24;
}
.checks-table {
    width: 100%;
    border-collapse: collapse;
    margin-top: 20px;
}
.checks-table th {
    background: #667eea;
    color: white;
    padding: 12px;
    text-align: left;
}
.checks-table td {
    padding: 10px;
    border-bottom: 1px solid #ddd;
}
.checks-table tr:hover {
    background: #f8f9fa;
}
.refresh-btn {
    background: #667eea;
    color: white;
    border: none;
    padding: 10px 20px;
    border-radius: 6px;
    cursor: pointer;
    font-size: 16px;
    margin: 10px 5px;
}
.refresh-btn:hover {
    background: #5568d3;
}
.export-btn {
    background: #28a745;
    color: white;
    border: none;
    padding: 10px 20px;
    border-radius: 6px;
    cursor: pointer;
    font-size: 16px;
    margin: 10px 5px;
}
.export-btn:hover {
    background: #218838;
}
"@

            # Main dashboard route
            Add-PodeRoute -Method Get -Path '/' -ScriptBlock {
                $report = $using:CurrentReport
                
                if (-not $report) {
                    Write-PodeHtmlResponse -Value @"
<!DOCTYPE html>
<html>
<head>
    <title>FinOps Report Server</title>
    <style>$using:css</style>
</head>
<body>
    <div class="container">
        <h1>FinOps Report Server</h1>
        <p>No report data loaded. Please provide an OrchestratorObject to Start-FinOpsReportServer.</p>
    </div>
</body>
</html>
"@
                    return
                }

                # Generate check results HTML
                $checksHtml = ""
                if ($report.Checks) {
                    foreach ($check in $report.Checks) {
                        $statusBadge = if ($check.Success) {
                            '<span class="status-badge status-success">✓ Success</span>'
                        } else {
                            '<span class="status-badge status-failed">✗ Failed</span>'
                        }
                        
                        $errorInfo = ""
                        if (-not $check.Success -and $check.ErrorMessage) {
                            $errorInfo = "<br><small style='color: #721c24;'>Error: $($check.ErrorMessage)</small>"
                        }
                        
                        $checksHtml += "<tr><td>$($check.Name)</td><td>$statusBadge $errorInfo</td></tr>"
                    }
                }

                $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>FinOps Report - $($report.Customer.Name)</title>
    <style>$using:css</style>
    <meta http-equiv="refresh" content="30">
</head>
<body>
    <div class="container">
        <h1>FinOps Onboarding Report</h1>
        <p><em>Auto-refreshes every 30 seconds</em></p>
        
        <div style="margin: 20px 0;">
            <button class="refresh-btn" onclick="location.reload()">🔄 Refresh Now</button>
            <button class="export-btn" onclick="window.location.href='/export/json'">📥 Export JSON</button>
            <button class="export-btn" onclick="window.location.href='/export/html'">📥 Export HTML</button>
        </div>

        <h2>Customer Information</h2>
        <div class="info-grid">
            <div class="info-card">
                <label>Customer Name</label>
                <div>$($report.Customer.Name)</div>
            </div>
            <div class="info-card">
                <label>Primary Domain</label>
                <div>$($report.Customer.PrimaryDomain)</div>
            </div>
            <div class="info-card">
                <label>Tenant ID</label>
                <div>$($report.Identifiers.TenantId)</div>
            </div>
            <div class="info-card">
                <label>Subscription Count</label>
                <div>$($report.Identifiers.SubscriptionCount)</div>
            </div>
        </div>

        <h2>Check Results</h2>
        <table class="checks-table">
            <thead>
                <tr>
                    <th>Check Name</th>
                    <th>Status</th>
                </tr>
            </thead>
            <tbody>
                $checksHtml
            </tbody>
        </table>

        <footer style="margin-top: 40px; text-align: center; color: #666;">
            <p>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
            <p>Module Version: $($report.ModuleVersion)</p>
        </footer>
    </div>
</body>
</html>
"@

                Write-PodeHtmlResponse -Value $html
            }

            # JSON export route
            Add-PodeRoute -Method Get -Path '/export/json' -ScriptBlock {
                $report = $using:CurrentReport
                if ($report) {
                    $json = $report | ConvertTo-Json -Depth 10
                    Write-PodeJsonResponse -Value $json -ContentType 'application/json' -StatusCode 200
                    Set-PodeHeader -Name 'Content-Disposition' -Value 'attachment; filename="finops-report.json"'
                } else {
                    Write-PodeJsonResponse -Value @{ error = "No report data" } -StatusCode 404
                }
            }

            # HTML export route
            Add-PodeRoute -Method Get -Path '/export/html' -ScriptBlock {
                $report = $using:CurrentReport
                if ($report) {
                    # Generate static HTML (same as dashboard but without auto-refresh)
                    $checksHtml = ""
                    if ($report.Checks) {
                        foreach ($check in $report.Checks) {
                            $statusBadge = if ($check.Success) {
                                '<span class="status-badge status-success">✓ Success</span>'
                            } else {
                                '<span class="status-badge status-failed">✗ Failed</span>'
                            }
                            $errorInfo = ""
                            if (-not $check.Success -and $check.ErrorMessage) {
                                $errorInfo = "<br><small style='color: #721c24;'>Error: $($check.ErrorMessage)</small>"
                            }
                            $checksHtml += "<tr><td>$($check.Name)</td><td>$statusBadge $errorInfo</td></tr>"
                        }
                    }

                    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>FinOps Report - $($report.Customer.Name)</title>
    <style>$using:css</style>
</head>
<body>
    <div class="container">
        <h1>FinOps Onboarding Report</h1>
        <h2>Customer Information</h2>
        <div class="info-grid">
            <div class="info-card"><label>Customer Name</label><div>$($report.Customer.Name)</div></div>
            <div class="info-card"><label>Primary Domain</label><div>$($report.Customer.PrimaryDomain)</div></div>
            <div class="info-card"><label>Tenant ID</label><div>$($report.Identifiers.TenantId)</div></div>
            <div class="info-card"><label>Subscription Count</label><div>$($report.Identifiers.SubscriptionCount)</div></div>
        </div>
        <h2>Check Results</h2>
        <table class="checks-table">
            <thead><tr><th>Check Name</th><th>Status</th></tr></thead>
            <tbody>$checksHtml</tbody>
        </table>
        <footer style="margin-top: 40px; text-align: center; color: #666;">
            <p>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
            <p>Module Version: $($report.ModuleVersion)</p>
        </footer>
    </div>
</body>
</html>
"@
                    Write-PodeHtmlResponse -Value $html
                    Set-PodeHeader -Name 'Content-Disposition' -Value 'attachment; filename="finops-report.html"'
                } else {
                    Write-PodeHtmlResponse -Value "<html><body><h1>No report data</h1></body></html>" -StatusCode 404
                }
            }

            # Health check route
            Add-PodeRoute -Method Get -Path '/health' -ScriptBlock {
                Write-PodeJsonResponse -Value @{ status = "healthy"; timestamp = (Get-Date -Format o) }
            }
        }

        $url = "http://localhost:$Port"
        Write-Host "FinOps Report Server started at: $url" -ForegroundColor Green
        Write-Host "Press Ctrl+C to stop the server" -ForegroundColor Yellow

        if ($AutoOpen) {
            Write-Verbose "Opening browser..."
            Start-Process $url
        }

        # Return server instance
        return [PSCustomObject]@{
            Url = $url
            Port = $Port
            Stop = { Stop-PodeServer }
        }
    }
}
