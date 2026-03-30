<#
.SYNOPSIS
    Sends WinRE health summary reports to Microsoft Teams via webhook.

.DESCRIPTION
    Queries Log Analytics for WinRE health data and posts formatted Adaptive Card
    to Microsoft Teams channel. Alternative to email-based reporting that bypasses
    SMTP/transport rule requirements.

.PARAMETER WorkspaceId
    Log Analytics Workspace ID.

.PARAMETER WebhookUrl
    Microsoft Teams Incoming Webhook URL.
    Get from: Teams Channel > Connectors > Incoming Webhook

.PARAMETER QueryAuthMethod
    Authentication method for querying Log Analytics:
    - 'AppRegistration': Azure AD App with client secret (recommended)
    - 'WorkspaceKey': Workspace key (may have limitations)
    Default: AppRegistration

.PARAMETER TenantId
    Azure AD Tenant ID (required for AppRegistration auth).

.PARAMETER ClientId
    Azure AD App (client) ID (required for AppRegistration auth).

.PARAMETER ClientSecret
    Azure AD App client secret (required for AppRegistration auth).

.PARAMETER WorkspaceKey
    Workspace Key (alternative auth for queries, not recommended).

.PARAMETER DaysBack
    Number of days of data to include in report. Default: 7

.PARAMETER Title
    Report title. Default: "WinRE Health Weekly Report"

.PARAMETER IncludeTopDevices
    Include top vulnerable devices in report. Default: $true

.PARAMETER TopDeviceCount
    Number of top vulnerable devices to include. Default: 5

.EXAMPLE
    # Using App Registration authentication (recommended)
    .\Send-TeamsReport.ps1 -WorkspaceId "abc-123" `
        -WebhookUrl "https://outlook.office.com/webhook/..." `
        -TenantId "tenant-id" -ClientId "client-id" -ClientSecret "secret"

.EXAMPLE
    # Custom title and device count
    .\Send-TeamsReport.ps1 -WorkspaceId "abc-123" -WebhookUrl "https://..." `
        -TenantId "..." -ClientId "..." -ClientSecret "..." `
        -Title "Monthly WinRE Status" -TopDeviceCount 10

.NOTES
    Author: WinRE Health Monitoring Team
    Version: 1.0.0
    Purpose: SMTP/Email alternative for automated reporting
    Requires: Invoke-LogAnalyticsQuery module (in this repo)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceId,

    [Parameter(Mandatory = $true)]
    [string]$WebhookUrl,

    [Parameter(Mandatory = $false)]
    [ValidateSet('AppRegistration', 'WorkspaceKey')]
    [string]$QueryAuthMethod = 'AppRegistration',

    [Parameter(Mandatory = $false)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [string]$ClientId,

    [Parameter(Mandatory = $false)]
    [string]$ClientSecret,

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceKey,

    [Parameter(Mandatory = $false)]
    [int]$DaysBack = 7,

    [Parameter(Mandatory = $false)]
    [string]$Title = "WinRE Health Weekly Report",

    [Parameter(Mandatory = $false)]
    [bool]$IncludeTopDevices = $true,

    [Parameter(Mandatory = $false)]
    [int]$TopDeviceCount = 5
)

#Requires -Version 5.1

# Import Invoke-LogAnalyticsQuery module
$modulePath = Join-Path $PSScriptRoot "..\Modules\Invoke-LogAnalyticsQuery.psm1"
if (-not (Test-Path $modulePath)) {
    Write-Error "Required module not found: $modulePath"
    exit 1
}
Import-Module $modulePath -Force

Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  WinRE Health Report → Microsoft Teams" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

#region Validate Parameters
Write-Host "▶ Validating parameters..." -ForegroundColor Yellow

if ($QueryAuthMethod -eq 'AppRegistration') {
    if ([string]::IsNullOrWhiteSpace($TenantId) -or [string]::IsNullOrWhiteSpace($ClientId) -or [string]::IsNullOrWhiteSpace($ClientSecret)) {
        Write-Error "AppRegistration auth requires -TenantId, -ClientId, and -ClientSecret"
        exit 1
    }
} elseif ($QueryAuthMethod -eq 'WorkspaceKey') {
    if ([string]::IsNullOrWhiteSpace($WorkspaceKey)) {
        Write-Error "WorkspaceKey auth requires -WorkspaceKey parameter"
        exit 1
    }
}

Write-Host "✅ Parameters validated" -ForegroundColor Green
Write-Host ""
#endregion

#region Query Health Summary
Write-Host "▶ Querying health summary from Log Analytics..." -ForegroundColor Yellow

$summaryQuery = @"
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
    WinREDisabled = countif(WinREEnabled_b == false),
    AvgPartitionFreeMB = round(avg(PartitionFreeMB_d), 0)
"@

try {
    $queryParams = @{
        WorkspaceId = $WorkspaceId
        Query = $summaryQuery
    }

    if ($QueryAuthMethod -eq 'AppRegistration') {
        $queryParams['TenantId'] = $TenantId
        $queryParams['ClientId'] = $ClientId
        $queryParams['ClientSecret'] = $ClientSecret
    } else {
        $queryParams['WorkspaceKey'] = $WorkspaceKey
    }

    $summaryResult = Invoke-LogAnalyticsQuery @queryParams
    $summary = $summaryResult.Results[0]

    Write-Host "✅ Summary retrieved" -ForegroundColor Green
    Write-Host "   Total Devices: $($summary.TotalDevices)" -ForegroundColor Gray
    Write-Host "   Vulnerable: $($summary.VulnerableDevices)" -ForegroundColor Gray
    Write-Host ""
} catch {
    Write-Error "Failed to query health summary: $($_.Exception.Message)"
    exit 1
}
#endregion

#region Query Top Vulnerable Devices
$topDevices = @()

if ($IncludeTopDevices) {
    Write-Host "▶ Querying top $TopDeviceCount vulnerable devices..." -ForegroundColor Yellow

    $topDevicesQuery = @"
WinREHealth_CL
| where TimeGenerated > ago($($DaysBack)d)
| where KB5034441Vulnerable_b == true
| summarize arg_max(TimeGenerated, *) by ComputerName_s
| project 
    ComputerName = ComputerName_s,
    Severity = Severity_s,
    PartitionFreeMB = round(PartitionFreeMB_d, 0),
    Manufacturer = Manufacturer_s,
    Model = Model_s
| order by Severity asc, PartitionFreeMB asc
| take $TopDeviceCount
"@

    try {
        $queryParams['Query'] = $topDevicesQuery
        $topDevicesResult = Invoke-LogAnalyticsQuery @queryParams
        $topDevices = $topDevicesResult.Results

        Write-Host "✅ Top devices retrieved: $($topDevices.Count)" -ForegroundColor Green
        Write-Host ""
    } catch {
        Write-Warning "Failed to query top devices: $($_.Exception.Message)"
    }
}
#endregion

#region Build Adaptive Card
Write-Host "▶ Building Teams Adaptive Card..." -ForegroundColor Yellow

# Calculate percentages
$vulnerablePercent = if ($summary.TotalDevices -gt 0) {
    [math]::Round(($summary.VulnerableDevices / $summary.TotalDevices) * 100, 1)
} else { 0 }

$healthyPercent = 100 - $vulnerablePercent

# Determine health color
$healthColor = if ($vulnerablePercent -gt 20) {
    "attention"  # Red
} elseif ($vulnerablePercent -gt 10) {
    "warning"    # Yellow
} else {
    "good"       # Green
}

# Build card body sections
$cardBody = @(
    @{
        type = "TextBlock"
        size = "Large"
        weight = "Bolder"
        text = $Title
    },
    @{
        type = "TextBlock"
        text = "Report Period: Last $DaysBack days"
        isSubtle = $true
        spacing = "None"
    },
    @{
        type = "TextBlock"
        text = "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        isSubtle = $true
        spacing = "None"
    },
    @{
        type = "Container"
        separator = $true
        items = @(
            @{
                type = "ColumnSet"
                columns = @(
                    @{
                        type = "Column"
                        width = "stretch"
                        items = @(
                            @{
                                type = "TextBlock"
                                text = "📊 **Fleet Summary**"
                                weight = "Bolder"
                            }
                        )
                    }
                )
            },
            @{
                type = "FactSet"
                facts = @(
                    @{ title = "Total Devices"; value = "$($summary.TotalDevices)" },
                    @{ title = "✅ Healthy"; value = "$($summary.HealthyDevices) ($healthyPercent%)" },
                    @{ title = "⚠️  Vulnerable (KB5034441)"; value = "$($summary.VulnerableDevices) ($vulnerablePercent%)" },
                    @{ title = "🔴 Critical Severity"; value = "$($summary.CriticalDevices)" },
                    @{ title = "🟠 High Severity"; value = "$($summary.HighSeverity)" },
                    @{ title = "🟡 Medium Severity"; value = "$($summary.MediumSeverity)" },
                    @{ title = "❌ WinRE Disabled"; value = "$($summary.WinREDisabled)" },
                    @{ title = "💾 Avg Free Space"; value = "$($summary.AvgPartitionFreeMB) MB" }
                )
            }
        )
    }
)

# Add top devices section if available
if ($topDevices.Count -gt 0) {
    $deviceFacts = $topDevices | ForEach-Object {
        @{
            title = "$($_.ComputerName) [$($_.Severity)]"
            value = "$($_.PartitionFreeMB) MB free | $($_.Manufacturer) $($_.Model)"
        }
    }

    $cardBody += @{
        type = "Container"
        separator = $true
        items = @(
            @{
                type = "TextBlock"
                text = "🚨 **Top $TopDeviceCount Vulnerable Devices**"
                weight = "Bolder"
            },
            @{
                type = "FactSet"
                facts = $deviceFacts
            }
        )
    }
}

# Add action buttons
$cardBody += @{
    type = "ActionSet"
    actions = @(
        @{
            type = "Action.OpenUrl"
            title = "View in Log Analytics"
            url = "https://portal.azure.com/#blade/Microsoft_Azure_Monitoring_Logs/LogsBlade/workspaceId/$WorkspaceId"
        }
    )
}

# Complete Adaptive Card
$adaptiveCard = @{
    type = "message"
    attachments = @(
        @{
            contentType = "application/vnd.microsoft.card.adaptive"
            content = @{
                type = "AdaptiveCard"
                '$schema' = "http://adaptivecards.io/schemas/adaptive-card.json"
                version = "1.4"
                body = $cardBody
                msteams = @{
                    width = "Full"
                }
            }
        }
    )
}

Write-Host "✅ Adaptive Card created" -ForegroundColor Green
Write-Host ""
#endregion

#region Send to Teams
Write-Host "▶ Sending to Microsoft Teams..." -ForegroundColor Yellow

try {
    $cardJson = $adaptiveCard | ConvertTo-Json -Depth 20 -Compress

    $response = Invoke-RestMethod -Method Post -Uri $WebhookUrl `
        -Body $cardJson -ContentType 'application/json' -TimeoutSec 30

    Write-Host "✅ Report sent successfully to Teams" -ForegroundColor Green
    Write-Host "   Response: $response" -ForegroundColor Gray
    Write-Host ""
} catch {
    Write-Error "Failed to send to Teams: $($_.Exception.Message)"
    Write-Host ""
    Write-Host "Troubleshooting:" -ForegroundColor Yellow
    Write-Host "  1. Verify webhook URL is correct and active" -ForegroundColor Yellow
    Write-Host "  2. Check if webhook was deleted/disabled in Teams channel" -ForegroundColor Yellow
    Write-Host "  3. Ensure network allows HTTPS to outlook.office.com" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}
#endregion

Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  ✅ TEAMS REPORT SENT SUCCESSFULLY" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "Summary:" -ForegroundColor Cyan
Write-Host "  - Fleet Size: $($summary.TotalDevices) devices" -ForegroundColor White
Write-Host "  - Vulnerable: $($summary.VulnerableDevices) ($vulnerablePercent%)" -ForegroundColor White
Write-Host "  - Critical: $($summary.CriticalDevices)" -ForegroundColor White
Write-Host "  - Report Period: Last $DaysBack days" -ForegroundColor White
Write-Host ""

exit 0
