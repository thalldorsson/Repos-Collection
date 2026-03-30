<#
.SYNOPSIS
    Generates and sends weekly WinRE health summary reports via email.

.DESCRIPTION
    Queries Log Analytics for WinRE health data, generates an HTML report with
    key metrics, trends, and recommendations, then sends it via email to
    specified recipients. Can be scheduled as a weekly task.

.PARAMETER WorkspaceId
    Log Analytics Workspace ID containing WinRE health data.

.PARAMETER To
    Email recipient(s). Can be a single address or comma-separated list.

.PARAMETER From
    Sender email address.

.PARAMETER Subject
    Email subject. Supports variables: {Date}, {VulnerableCount}, {TotalCount}

.PARAMETER SmtpServer
    SMTP server for sending email. Default: smtp.office365.com

.PARAMETER SmtpPort
    SMTP port. Default: 587

.PARAMETER UseSsl
    Use SSL for SMTP connection. Default: $true

.PARAMETER Credential
    PSCredential for SMTP authentication.

.PARAMETER DaysBack
    Number of days of data to include in report. Default: 7

.PARAMETER SendGrid
    Use SendGrid API instead of SMTP.

.PARAMETER SendGridApiKey
    SendGrid API key (required if -SendGrid is specified).

.PARAMETER OutputHtml
    Output HTML report to file instead of sending email.

.PARAMETER OutputPath
    Path for HTML output file (when using -OutputHtml).

.EXAMPLE
    .\Send-SummaryReport.ps1 -WorkspaceId "abc123" -To "it-team@company.com" `
        -From "winre-monitor@company.com" -Credential $cred
    Sends weekly report via SMTP.

.EXAMPLE
    .\Send-SummaryReport.ps1 -WorkspaceId "abc123" -SendGrid -SendGridApiKey "SG.xxx" `
        -To "admin@company.com" -From "noreply@company.com"
    Sends report using SendGrid API.

.EXAMPLE
    .\Send-SummaryReport.ps1 -WorkspaceId "abc123" -OutputHtml -OutputPath "C:\Reports\weekly.html"
    Generates HTML report without sending email.

.NOTES
    Author: WinRE Health Monitor Team
    Version: 1.4.0
    Purpose: Automated weekly reporting for stakeholders
#>

[CmdletBinding(DefaultParameterSetName = 'SMTP')]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceId,

    [Parameter(Mandatory = $true, ParameterSetName = 'SMTP')]
    [Parameter(Mandatory = $true, ParameterSetName = 'SendGrid')]
    [Parameter(Mandatory = $false, ParameterSetName = 'HTML')]
    [string]$To,

    [Parameter(Mandatory = $true, ParameterSetName = 'SMTP')]
    [Parameter(Mandatory = $true, ParameterSetName = 'SendGrid')]
    [Parameter(Mandatory = $false, ParameterSetName = 'HTML')]
    [string]$From,

    [Parameter(Mandatory = $false)]
    [string]$Subject = "WinRE Health Report - {VulnerableCount} Devices Need Attention - {Date}",

    [Parameter(Mandatory = $false, ParameterSetName = 'SMTP')]
    [string]$SmtpServer = "smtp.office365.com",

    [Parameter(Mandatory = $false, ParameterSetName = 'SMTP')]
    [int]$SmtpPort = 587,

    [Parameter(Mandatory = $false, ParameterSetName = 'SMTP')]
    [bool]$UseSsl = $true,

    [Parameter(Mandatory = $false, ParameterSetName = 'SMTP')]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 90)]
    [int]$DaysBack = 7,

    [Parameter(Mandatory = $true, ParameterSetName = 'SendGrid')]
    [switch]$SendGrid,

    [Parameter(Mandatory = $true, ParameterSetName = 'SendGrid')]
    [string]$SendGridApiKey,

    [Parameter(Mandatory = $true, ParameterSetName = 'HTML')]
    [switch]$OutputHtml,

    [Parameter(Mandatory = $true, ParameterSetName = 'HTML')]
    [string]$OutputPath
)

#Requires -Version 5.1
#Requires -Modules Az.OperationalInsights

#region Data Collection Functions
function Get-WinREHealthSummary {
    param(
        [string]$WorkspaceId,
        [int]$DaysBack
    )
    
    $query = @"
WinREHealth_CL
| where TimeGenerated > ago($($DaysBack)d)
| summarize arg_max(TimeGenerated, *) by ComputerName_s
| summarize
    TotalDevices = count(),
    VulnerableDevices = countif(KB5034441Vulnerable_b == true),
    HealthyDevices = countif(KB5034441Vulnerable_b == false),
    CriticalDevices = countif(Severity_s == "Critical"),
    HighSeverity = countif(Severity_s == "High"),
    MediumSeverity = countif(Severity_s == "Medium"),
    RemediationReady = countif(RemediationReady_b == true),
    WinREDisabled = countif(WinREEnabled_b == false),
    AvgPartitionSizeMB = avg(PartitionSizeMB_d),
    AvgFreeSpaceMB = avg(PartitionFreeMB_d)
"@
    
    try {
        $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $query -ErrorAction Stop
        return $result.Results[0]
    }
    catch {
        Write-Warning "Failed to query health summary: $_"
        return $null
    }
}

function Get-TrendComparison {
    param(
        [string]$WorkspaceId,
        [int]$DaysBack
    )
    
    $query = @"
let CurrentPeriod = 
    WinREHealth_CL
    | where TimeGenerated > ago($($DaysBack)d)
    | summarize arg_max(TimeGenerated, *) by ComputerName_s
    | summarize 
        CurrentVulnerable = countif(KB5034441Vulnerable_b == true),
        CurrentTotal = count();

let PreviousPeriod = 
    WinREHealth_CL
    | where TimeGenerated between (ago($($DaysBack * 2)d) .. ago($($DaysBack)d))
    | summarize arg_max(TimeGenerated, *) by ComputerName_s
    | summarize 
        PreviousVulnerable = countif(KB5034441Vulnerable_b == true),
        PreviousTotal = count();

CurrentPeriod
| extend PreviousVulnerable = toscalar(PreviousPeriod | project PreviousVulnerable)
| extend PreviousTotal = toscalar(PreviousPeriod | project PreviousTotal)
| extend 
    VulnerableChange = CurrentVulnerable - PreviousVulnerable,
    TotalChange = CurrentTotal - PreviousTotal,
    TrendDirection = case(
        CurrentVulnerable > PreviousVulnerable, "Increasing",
        CurrentVulnerable < PreviousVulnerable, "Decreasing",
        "Stable"
    )
"@
    
    try {
        $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $query -ErrorAction Stop
        return $result.Results[0]
    }
    catch {
        Write-Warning "Failed to query trend data: $_"
        return $null
    }
}

function Get-TopVulnerableDevices {
    param(
        [string]$WorkspaceId,
        [int]$DaysBack,
        [int]$TopN = 10
    )
    
    $query = @"
WinREHealth_CL
| where TimeGenerated > ago($($DaysBack)d)
| where KB5034441Vulnerable_b == true
| summarize arg_max(TimeGenerated, *) by ComputerName_s
| extend DaysUntilCritical = todouble(DaysUntilSpaceCritical_d)
| project 
    ComputerName = ComputerName_s,
    Severity = Severity_s,
    Criticality = DeviceCriticality_s,
    PartitionFreeMB = round(PartitionFreeMB_d, 0),
    DaysUntilCritical = iff(DaysUntilCritical > 999, "N/A", tostring(round(DaysUntilCritical, 0))),
    Manufacturer = Manufacturer_s,
    Model = Model_s,
    LastSeen = TimeGenerated
| order by Severity asc, PartitionFreeMB asc
| take $TopN
"@
    
    try {
        $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $query -ErrorAction Stop
        return $result.Results
    }
    catch {
        Write-Warning "Failed to query top vulnerable devices: $_"
        return @()
    }
}

function Get-VendorBreakdown {
    param(
        [string]$WorkspaceId,
        [int]$DaysBack
    )
    
    $query = @"
WinREHealth_CL
| where TimeGenerated > ago($($DaysBack)d)
| summarize arg_max(TimeGenerated, *) by ComputerName_s
| summarize
    TotalDevices = count(),
    VulnerableDevices = countif(KB5034441Vulnerable_b == true)
    by Manufacturer_s
| extend VulnerabilityRate = round(VulnerableDevices * 100.0 / TotalDevices, 1)
| project
    Manufacturer = Manufacturer_s,
    TotalDevices,
    VulnerableDevices,
    VulnerabilityRate
| order by VulnerableDevices desc
"@
    
    try {
        $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $query -ErrorAction Stop
        return $result.Results
    }
    catch {
        Write-Warning "Failed to query vendor breakdown: $_"
        return @()
    }
}

function Get-RemediationStats {
    param(
        [string]$WorkspaceId,
        [int]$DaysBack
    )
    
    $query = @"
WinRERemediation_CL
| where TimeGenerated > ago($($DaysBack)d)
| summarize
    TotalAttempts = count(),
    Successful = countif(Success_b == true),
    Failed = countif(Success_b == false)
| extend SuccessRate = round(Successful * 100.0 / TotalAttempts, 1)
"@
    
    try {
        $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $query -ErrorAction Stop
        return $result.Results[0]
    }
    catch {
        # Remediation table may not exist yet
        return @{
            TotalAttempts = 0
            Successful    = 0
            Failed        = 0
            SuccessRate   = "N/A"
        }
    }
}
#endregion

#region HTML Generation
function New-HtmlReport {
    param(
        [object]$Summary,
        [object]$Trend,
        [array]$TopVulnerable,
        [array]$VendorBreakdown,
        [object]$RemediationStats,
        [int]$DaysBack
    )
    
    $reportDate = Get-Date -Format "yyyy-MM-dd"
    $periodStart = (Get-Date).AddDays(-$DaysBack).ToString("yyyy-MM-dd")
    
    # Calculate percentages
    $compliancePercent = if ($Summary.TotalDevices -gt 0) {
        [Math]::Round(($Summary.HealthyDevices / $Summary.TotalDevices) * 100, 1)
    } else { 0 }
    
    # Trend indicator
    $trendIcon = switch ($Trend.TrendDirection) {
        "Increasing" { "📈 ⚠️" }
        "Decreasing" { "📉 ✅" }
        default { "➡️" }
    }
    
    $trendColor = switch ($Trend.TrendDirection) {
        "Increasing" { "#dc3545" }  # Red
        "Decreasing" { "#28a745" }  # Green
        default { "#6c757d" }       # Gray
    }
    
    # Build device table rows
    $deviceRows = ""
    foreach ($device in $TopVulnerable) {
        $severityColor = switch ($device.Severity) {
            "Critical" { "#dc3545" }
            "High" { "#fd7e14" }
            "Medium" { "#ffc107" }
            default { "#6c757d" }
        }
        $deviceRows += @"
        <tr>
            <td>$($device.ComputerName)</td>
            <td style="color: $severityColor; font-weight: bold;">$($device.Severity)</td>
            <td>$($device.Criticality)</td>
            <td>$($device.PartitionFreeMB) MB</td>
            <td>$($device.DaysUntilCritical)</td>
            <td>$($device.Manufacturer)</td>
        </tr>
"@
    }
    
    # Build vendor table rows
    $vendorRows = ""
    foreach ($vendor in $VendorBreakdown) {
        $vendorRows += @"
        <tr>
            <td>$($vendor.Manufacturer)</td>
            <td>$($vendor.TotalDevices)</td>
            <td>$($vendor.VulnerableDevices)</td>
            <td>$($vendor.VulnerabilityRate)%</td>
        </tr>
"@
    }
    
    return @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>WinRE Health Report - $reportDate</title>
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background-color: #f5f5f5;
            margin: 0;
            padding: 20px;
            color: #333;
        }
        .container {
            max-width: 900px;
            margin: 0 auto;
            background: white;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            overflow: hidden;
        }
        .header {
            background: linear-gradient(135deg, #0078D4, #005a9e);
            color: white;
            padding: 30px;
            text-align: center;
        }
        .header h1 {
            margin: 0 0 10px 0;
            font-size: 28px;
        }
        .header p {
            margin: 0;
            opacity: 0.9;
        }
        .metrics {
            display: flex;
            flex-wrap: wrap;
            padding: 20px;
            background: #f8f9fa;
            gap: 15px;
        }
        .metric {
            flex: 1;
            min-width: 150px;
            background: white;
            padding: 20px;
            border-radius: 8px;
            text-align: center;
            box-shadow: 0 1px 3px rgba(0,0,0,0.1);
        }
        .metric-value {
            font-size: 36px;
            font-weight: bold;
            margin-bottom: 5px;
        }
        .metric-label {
            color: #666;
            font-size: 14px;
        }
        .healthy { color: #28a745; }
        .warning { color: #ffc107; }
        .danger { color: #dc3545; }
        .neutral { color: #6c757d; }
        .section {
            padding: 20px 30px;
            border-bottom: 1px solid #eee;
        }
        .section:last-child {
            border-bottom: none;
        }
        .section h2 {
            color: #0078D4;
            margin-top: 0;
            font-size: 20px;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 15px;
        }
        th, td {
            padding: 12px;
            text-align: left;
            border-bottom: 1px solid #ddd;
        }
        th {
            background: #0078D4;
            color: white;
            font-weight: 500;
        }
        tr:nth-child(even) {
            background: #f8f9fa;
        }
        tr:hover {
            background: #e9ecef;
        }
        .trend-box {
            display: inline-flex;
            align-items: center;
            padding: 10px 20px;
            border-radius: 8px;
            background: #f8f9fa;
            margin-top: 10px;
        }
        .trend-icon {
            font-size: 24px;
            margin-right: 10px;
        }
        .recommendations {
            background: #fff3cd;
            border: 1px solid #ffc107;
            border-radius: 8px;
            padding: 15px;
            margin-top: 15px;
        }
        .recommendations h3 {
            margin-top: 0;
            color: #856404;
        }
        .recommendations ul {
            margin-bottom: 0;
        }
        .footer {
            background: #f8f9fa;
            padding: 20px 30px;
            text-align: center;
            color: #666;
            font-size: 12px;
        }
        .progress-bar {
            background: #e9ecef;
            border-radius: 10px;
            height: 20px;
            overflow: hidden;
            margin-top: 10px;
        }
        .progress-fill {
            height: 100%;
            background: linear-gradient(90deg, #28a745, #85c53a);
            transition: width 0.5s;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🛡️ WinRE Health Report</h1>
            <p>Period: $periodStart to $reportDate ($DaysBack days)</p>
        </div>
        
        <div class="metrics">
            <div class="metric">
                <div class="metric-value neutral">$($Summary.TotalDevices)</div>
                <div class="metric-label">Total Devices</div>
            </div>
            <div class="metric">
                <div class="metric-value healthy">$($Summary.HealthyDevices)</div>
                <div class="metric-label">Healthy</div>
            </div>
            <div class="metric">
                <div class="metric-value danger">$($Summary.VulnerableDevices)</div>
                <div class="metric-label">Vulnerable</div>
            </div>
            <div class="metric">
                <div class="metric-value warning">$($Summary.CriticalDevices)</div>
                <div class="metric-label">Critical Severity</div>
            </div>
        </div>
        
        <div class="section">
            <h2>📊 Compliance Status</h2>
            <p>Overall compliance: <strong>$compliancePercent%</strong> of devices are healthy</p>
            <div class="progress-bar">
                <div class="progress-fill" style="width: $compliancePercent%;"></div>
            </div>
            <div class="trend-box">
                <span class="trend-icon">$trendIcon</span>
                <span style="color: $trendColor;">
                    Vulnerability trend: <strong>$($Trend.TrendDirection)</strong>
                    (Change: $($Trend.VulnerableChange) devices vs previous period)
                </span>
            </div>
        </div>
        
        <div class="section">
            <h2>⚠️ Top Vulnerable Devices</h2>
            <p>Devices requiring immediate attention:</p>
            <table>
                <tr>
                    <th>Computer Name</th>
                    <th>Severity</th>
                    <th>Criticality</th>
                    <th>Free Space</th>
                    <th>Days Until Critical</th>
                    <th>Manufacturer</th>
                </tr>
                $deviceRows
            </table>
        </div>
        
        <div class="section">
            <h2>🏭 Vendor Breakdown</h2>
            <p>Vulnerability distribution by manufacturer:</p>
            <table>
                <tr>
                    <th>Manufacturer</th>
                    <th>Total Devices</th>
                    <th>Vulnerable</th>
                    <th>Vulnerability Rate</th>
                </tr>
                $vendorRows
            </table>
        </div>
        
        <div class="section">
            <h2>🔧 Remediation Summary</h2>
            <p>
                Total attempts: <strong>$($RemediationStats.TotalAttempts)</strong> |
                Successful: <strong class="healthy">$($RemediationStats.Successful)</strong> |
                Failed: <strong class="danger">$($RemediationStats.Failed)</strong> |
                Success Rate: <strong>$($RemediationStats.SuccessRate)%</strong>
            </p>
            <p>Devices ready for remediation: <strong>$($Summary.RemediationReady)</strong></p>
        </div>
        
        <div class="section">
            <h2>💡 Recommendations</h2>
            <div class="recommendations">
                <h3>Action Items</h3>
                <ul>
                    $(if ($Summary.CriticalDevices -gt 0) { "<li><strong>HIGH PRIORITY:</strong> $($Summary.CriticalDevices) critical device(s) require immediate attention</li>" })
                    $(if ($Summary.WinREDisabled -gt 0) { "<li><strong>WARNING:</strong> $($Summary.WinREDisabled) device(s) have WinRE disabled</li>" })
                    $(if ($Summary.RemediationReady -gt 0) { "<li>$($Summary.RemediationReady) device(s) are ready for automated remediation</li>" })
                    $(if ($Trend.TrendDirection -eq "Increasing") { "<li>Vulnerability count is increasing - review recent deployments or system changes</li>" })
                    <li>Review and prioritize remediation for devices with lowest free space</li>
                    <li>Schedule remediation during maintenance windows for critical devices</li>
                </ul>
            </div>
        </div>
        
        <div class="footer">
            <p>
                Generated by WinRE Health Monitor v1.4.0<br>
                Report Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')<br>
                Questions? Contact your IT Operations team
            </p>
            <p>
                <a href="https://portal.azure.com/#blade/Microsoft_Azure_Monitoring/AzureMonitoringBrowseBlade/workbooks">View Dashboard in Azure</a>
            </p>
        </div>
    </div>
</body>
</html>
"@
}
#endregion

#region Email Functions
function Send-EmailSMTP {
    param(
        [string]$To,
        [string]$From,
        [string]$Subject,
        [string]$Body,
        [string]$SmtpServer,
        [int]$SmtpPort,
        [bool]$UseSsl,
        [PSCredential]$Credential
    )
    
    $mailParams = @{
        To         = $To -split ','
        From       = $From
        Subject    = $Subject
        Body       = $Body
        BodyAsHtml = $true
        SmtpServer = $SmtpServer
        Port       = $SmtpPort
    }
    
    if ($UseSsl) {
        $mailParams['UseSsl'] = $true
    }
    
    if ($Credential) {
        $mailParams['Credential'] = $Credential
    }
    
    Send-MailMessage @mailParams
}

function Send-EmailSendGrid {
    param(
        [string]$To,
        [string]$From,
        [string]$Subject,
        [string]$Body,
        [string]$ApiKey
    )
    
    $recipients = $To -split ',' | ForEach-Object { @{ email = $_.Trim() } }
    
    $sendGridBody = @{
        personalizations = @(
            @{
                to = $recipients
            }
        )
        from    = @{ email = $From }
        subject = $Subject
        content = @(
            @{
                type  = "text/html"
                value = $Body
            }
        )
    } | ConvertTo-Json -Depth 10
    
    $headers = @{
        "Authorization" = "Bearer $ApiKey"
        "Content-Type"  = "application/json"
    }
    
    $response = Invoke-RestMethod -Uri "https://api.sendgrid.com/v3/mail/send" `
        -Method Post -Headers $headers -Body $sendGridBody
    
    return $response
}
#endregion

#region Main Logic
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " WinRE Health - Summary Report Generator" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

try {
    # Collect data
    Write-Host "Collecting data from Log Analytics..." -ForegroundColor Yellow
    
    Write-Host "  Querying health summary..." -ForegroundColor Gray
    $summary = Get-WinREHealthSummary -WorkspaceId $WorkspaceId -DaysBack $DaysBack
    
    if (-not $summary) {
        throw "Failed to retrieve health summary data"
    }
    
    Write-Host "  Querying trend data..." -ForegroundColor Gray
    $trend = Get-TrendComparison -WorkspaceId $WorkspaceId -DaysBack $DaysBack
    
    Write-Host "  Querying top vulnerable devices..." -ForegroundColor Gray
    $topVulnerable = Get-TopVulnerableDevices -WorkspaceId $WorkspaceId -DaysBack $DaysBack
    
    Write-Host "  Querying vendor breakdown..." -ForegroundColor Gray
    $vendorBreakdown = Get-VendorBreakdown -WorkspaceId $WorkspaceId -DaysBack $DaysBack
    
    Write-Host "  Querying remediation stats..." -ForegroundColor Gray
    $remediationStats = Get-RemediationStats -WorkspaceId $WorkspaceId -DaysBack $DaysBack
    
    Write-Host ""
    Write-Host "Generating HTML report..." -ForegroundColor Yellow
    
    $htmlReport = New-HtmlReport -Summary $summary -Trend $trend -TopVulnerable $topVulnerable `
        -VendorBreakdown $vendorBreakdown -RemediationStats $remediationStats -DaysBack $DaysBack
    
    # Format subject
    $formattedSubject = $Subject `
        -replace '\{Date\}', (Get-Date -Format 'yyyy-MM-dd') `
        -replace '\{VulnerableCount\}', $summary.VulnerableDevices `
        -replace '\{TotalCount\}', $summary.TotalDevices
    
    if ($OutputHtml) {
        # Save to file
        Write-Host "Saving report to file..." -ForegroundColor Yellow
        
        $outputDir = Split-Path -Parent $OutputPath
        if ($outputDir -and -not (Test-Path $outputDir)) {
            New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
        }
        
        $htmlReport | Out-File -FilePath $OutputPath -Encoding UTF8
        
        Write-Host ""
        Write-Host "✓ Report saved to: $OutputPath" -ForegroundColor Green
    }
    else {
        # Send email
        Write-Host "Sending email..." -ForegroundColor Yellow
        
        if ($SendGrid) {
            Send-EmailSendGrid -To $To -From $From -Subject $formattedSubject `
                -Body $htmlReport -ApiKey $SendGridApiKey
            Write-Host "✓ Email sent via SendGrid to: $To" -ForegroundColor Green
        }
        else {
            Send-EmailSMTP -To $To -From $From -Subject $formattedSubject `
                -Body $htmlReport -SmtpServer $SmtpServer -SmtpPort $SmtpPort `
                -UseSsl $UseSsl -Credential $Credential
            Write-Host "✓ Email sent via SMTP to: $To" -ForegroundColor Green
        }
    }
    
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " Report Summary" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Total Devices:      $($summary.TotalDevices)" -ForegroundColor White
    Write-Host "  Vulnerable:         $($summary.VulnerableDevices)" -ForegroundColor $(if ($summary.VulnerableDevices -gt 0) { "Yellow" } else { "Green" })
    Write-Host "  Healthy:            $($summary.HealthyDevices)" -ForegroundColor Green
    Write-Host "  Critical Severity:  $($summary.CriticalDevices)" -ForegroundColor $(if ($summary.CriticalDevices -gt 0) { "Red" } else { "Gray" })
    Write-Host "  Trend:              $($trend.TrendDirection) ($($trend.VulnerableChange) change)" -ForegroundColor Gray
    Write-Host ""
    
    return @{
        Success           = $true
        TotalDevices      = $summary.TotalDevices
        VulnerableDevices = $summary.VulnerableDevices
        HealthyDevices    = $summary.HealthyDevices
        CriticalDevices   = $summary.CriticalDevices
        Trend             = $trend.TrendDirection
        DeliveryMethod    = if ($OutputHtml) { "File" } elseif ($SendGrid) { "SendGrid" } else { "SMTP" }
    }
}
catch {
    Write-Error "Failed to generate/send report: $_"
    throw
}
#endregion
