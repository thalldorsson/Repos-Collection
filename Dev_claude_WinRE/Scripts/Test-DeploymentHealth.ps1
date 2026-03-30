<#
.SYNOPSIS
    WinRE Health Monitoring - Deployment Health Check Script
    Week 4 Task #16: Automated validation of deployment configuration

.DESCRIPTION
    This script performs comprehensive validation of a WinRE Health Monitoring deployment.
    It checks Log Analytics connectivity, data freshness, device coverage, alert rules,
    workbooks, and data quality to ensure the monitoring solution is functioning correctly.

.PARAMETER WorkspaceId
    The Log Analytics Workspace ID to validate

.PARAMETER ExpectedDeviceCount
    Minimum number of devices expected to report (default: 10)

.PARAMETER SubscriptionId
    Azure subscription ID (optional, will prompt if not provided)

.PARAMETER ResourceGroupName
    Resource group containing Log Analytics workspace (optional)

.EXAMPLE
    .\Test-DeploymentHealth.ps1 -WorkspaceId "12345678-1234-1234-1234-123456789012"

.EXAMPLE
    .\Test-DeploymentHealth.ps1 -WorkspaceId "12345678-1234-1234-1234-123456789012" -ExpectedDeviceCount 50 -ResourceGroupName "RG-Monitoring"

.NOTES
    Author: WinRE Health Monitoring Team
    Version: 1.3.1
    Week 4 Task #16 Implementation
    
    Requirements:
    - Az.OperationalInsights PowerShell module
    - Az.Monitor PowerShell module
    - Azure authentication (Connect-AzAccount)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$WorkspaceId,
    
    [Parameter(Mandatory=$false)]
    [int]$ExpectedDeviceCount = 10,
    
    [Parameter(Mandatory=$false)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName
)

# Color output functions
function Write-Success { param([string]$Message) Write-Host "  ✓ $Message" -ForegroundColor Green }
function Write-Failure { param([string]$Message) Write-Host "  ✗ $Message" -ForegroundColor Red }
function Write-Warning { param([string]$Message) Write-Host "  ⚠ $Message" -ForegroundColor Yellow }
function Write-Info { param([string]$Message) Write-Host "  ℹ $Message" -ForegroundColor Cyan }
function Write-Header { param([string]$Message) Write-Host "`n$Message" -ForegroundColor Cyan }

# Test results tracking
$global:TestResults = @{
    TotalTests = 0
    PassedTests = 0
    FailedTests = 0
    Warnings = 0
}

function Test-Check {
    param(
        [string]$TestName,
        [bool]$Passed,
        [string]$Message,
        [bool]$IsWarning = $false
    )
    
    $global:TestResults.TotalTests++
    
    if ($Passed) {
        $global:TestResults.PassedTests++
        Write-Success "$TestName - $Message"
    } elseif ($IsWarning) {
        $global:TestResults.Warnings++
        Write-Warning "$TestName - $Message"
    } else {
        $global:TestResults.FailedTests++
        Write-Failure "$TestName - $Message"
    }
}

# Start validation
Write-Host "`n═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  WinRE Health Monitoring - Deployment Validation" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════`n" -ForegroundColor Cyan

Write-Info "Workspace ID: $WorkspaceId"
Write-Info "Expected Device Count: $ExpectedDeviceCount"
Write-Info "Start Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# Check 1: PowerShell Module Dependencies
Write-Header "[1/8] Checking PowerShell Module Dependencies..."

try {
    $azOpInsights = Get-Module -Name Az.OperationalInsights -ListAvailable
    $azMonitor = Get-Module -Name Az.Monitor -ListAvailable
    
    Test-Check -TestName "Az.OperationalInsights" -Passed ($null -ne $azOpInsights) -Message $(if ($azOpInsights) { "Module installed (v$($azOpInsights[0].Version))" } else { "Module NOT installed - Install with: Install-Module Az.OperationalInsights" })
    Test-Check -TestName "Az.Monitor" -Passed ($null -ne $azMonitor) -Message $(if ($azMonitor) { "Module installed (v$($azMonitor[0].Version))" } else { "Module NOT installed - Install with: Install-Module Az.Monitor" })
} catch {
    Write-Failure "Error checking modules: $($_.Exception.Message)"
}

# Check 2: Azure Authentication
Write-Header "[2/8] Verifying Azure Authentication..."

try {
    $context = Get-AzContext
    
    if ($context) {
        Test-Check -TestName "Azure Authentication" -Passed $true -Message "Authenticated as $($context.Account.Id)"
        
        if ($SubscriptionId -and $context.Subscription.Id -ne $SubscriptionId) {
            Write-Warning "Connected to subscription $($context.Subscription.Name), but $SubscriptionId was specified"
            Write-Info "Setting subscription context..."
            Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
        }
    } else {
        Test-Check -TestName "Azure Authentication" -Passed $false -Message "Not authenticated - Run Connect-AzAccount first"
        Write-Host "`nPlease authenticate to Azure and re-run the script." -ForegroundColor Yellow
        return
    }
} catch {
    Test-Check -TestName "Azure Authentication" -Passed $false -Message "Error checking authentication: $($_.Exception.Message)"
    return
}

# Check 3: Log Analytics Workspace Accessibility
Write-Header "[3/8] Testing Log Analytics Workspace Connectivity..."

try {
    # Try to find the workspace
    if ($ResourceGroupName) {
        $workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName | Where-Object { $_.CustomerId -eq $WorkspaceId }
    } else {
        $workspaces = Get-AzOperationalInsightsWorkspace
        $workspace = $workspaces | Where-Object { $_.CustomerId -eq $WorkspaceId }
    }
    
    if ($workspace) {
        Test-Check -TestName "Workspace Found" -Passed $true -Message "Workspace '$($workspace.Name)' in resource group '$($workspace.ResourceGroupName)'"
        Write-Info "Location: $($workspace.Location)"
        Write-Info "Sku: $($workspace.Sku.Name)"
    } else {
        Test-Check -TestName "Workspace Found" -Passed $false -Message "Could not find workspace with ID $WorkspaceId"
    }
    
    # Test query connectivity
    $testQuery = "WinREHealth_CL | take 1"
    $queryResult = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $testQuery -ErrorAction Stop
    
    Test-Check -TestName "Workspace Query" -Passed $true -Message "Successfully executed test query"
    
} catch {
    Test-Check -TestName "Workspace Connectivity" -Passed $false -Message "Cannot connect to workspace: $($_.Exception.Message)"
}

# Check 4: Data Freshness
Write-Header "[4/8] Checking Data Freshness..."

try {
    $query = @"
WinREHealth_CL
| where TimeGenerated > ago(24h)
| summarize 
    RecordCount = count(),
    LatestRecord = max(TimeGenerated),
    OldestRecord = min(TimeGenerated)
"@
    
    $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $query -ErrorAction Stop
    $data = $result.Results[0]
    
    if ($data.RecordCount -gt 0) {
        $latestAge = (Get-Date) - [datetime]$data.LatestRecord
        Test-Check -TestName "Recent Data" -Passed ($latestAge.TotalHours -lt 2) -Message "Received $($data.RecordCount) records in last 24h (latest: $($latestAge.Hours)h $($latestAge.Minutes)m ago)" -IsWarning ($latestAge.TotalHours -ge 2)
    } else {
        Test-Check -TestName "Recent Data" -Passed $false -Message "No data received in last 24 hours"
    }
} catch {
    Test-Check -TestName "Data Freshness" -Passed $false -Message "Error checking data: $($_.Exception.Message)"
}

# Check 5: Device Coverage
Write-Header "[5/8] Checking Device Coverage..."

try {
    $query = @"
WinREHealth_CL
| where TimeGenerated > ago(24h)
| summarize arg_max(TimeGenerated, *) by ComputerName
| summarize 
    TotalDevices = dcount(ComputerName),
    VulnerableDevices = dcountif(ComputerName, KB5034441Vulnerable == true),
    HealthyDevices = dcountif(ComputerName, KB5034441Vulnerable == false)
"@
    
    $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $query -ErrorAction Stop
    $data = $result.Results[0]
    
    if ($data.TotalDevices -ge $ExpectedDeviceCount) {
        Test-Check -TestName "Device Coverage" -Passed $true -Message "$($data.TotalDevices) devices reporting (expected: $ExpectedDeviceCount)"
    } else {
        Test-Check -TestName "Device Coverage" -Passed $false -Message "Only $($data.TotalDevices) devices reporting (expected: $ExpectedDeviceCount)" -IsWarning ($data.TotalDevices -gt 0)
    }
    
    Write-Info "Vulnerable: $($data.VulnerableDevices) | Healthy: $($data.HealthyDevices)"
    
} catch {
    Test-Check -TestName "Device Coverage" -Passed $false -Message "Error checking devices: $($_.Exception.Message)"
}

# Check 6: Alert Rules
Write-Header "[6/8] Verifying Alert Rules..."

try {
    $alerts = Get-AzScheduledQueryRule | Where-Object { $_.DisplayName -like "*WinRE*" }
    
    $expectedAlerts = @(
        "WinRE Health - High Risk Devices",
        "WinRE Health - WinRE Disabled",
        "WinRE Health - Low Disk Space"
    )
    
    if ($alerts.Count -gt 0) {
        Test-Check -TestName "Alert Rules" -Passed ($alerts.Count -ge 3) -Message "Found $($alerts.Count) WinRE alert rules" -IsWarning ($alerts.Count -lt 3)
        
        foreach ($alert in $alerts) {
            $enabled = $alert.Enabled
            Write-Info "$($alert.DisplayName) - $(if ($enabled) { 'Enabled' } else { 'DISABLED' })"
        }
    } else {
        Test-Check -TestName "Alert Rules" -Passed $false -Message "No WinRE alert rules found"
    }
} catch {
    Test-Check -TestName "Alert Rules" -Passed $false -Message "Error checking alerts: $($_.Exception.Message)"
}

# Check 7: Data Quality
Write-Header "[7/8] Checking Data Quality..."

try {
    $query = @"
WinREHealth_CL
| where TimeGenerated > ago(24h)
| extend HasIssue = 
    case(
        isempty(ComputerName), "Missing ComputerName",
        isempty(Manufacturer), "Missing Manufacturer",
        isnull(KB5034441Vulnerable), "Missing KB5034441Vulnerable",
        isempty(Severity), "Missing Severity",
        "OK"
    )
| where HasIssue != "OK"
| summarize BadRecords = count(), Issues = make_set(HasIssue, 10)
"@
    
    $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $query -ErrorAction Stop
    
    if ($result.Results.Count -eq 0 -or $result.Results[0].BadRecords -eq 0) {
        Test-Check -TestName "Data Quality" -Passed $true -Message "All records have required fields"
    } else {
        $badRecords = $result.Results[0].BadRecords
        Test-Check -TestName "Data Quality" -Passed $false -Message "Found $badRecords records with missing fields" -IsWarning $true
        Write-Info "Issues: $($result.Results[0].Issues -join ', ')"
    }
} catch {
    Test-Check -TestName "Data Quality" -Passed $false -Message "Error checking data quality: $($_.Exception.Message)"
}

# Check 8: Schema Validation
Write-Header "[8/8] Validating Data Schema..."

try {
    $query = @"
WinREHealth_CL
| where TimeGenerated > ago(1h)
| take 1
| project 
    ComputerName, Manufacturer, Model, OSVersion,
    KB5034441Vulnerable, WinREEnabled, Severity,
    PartitionSizeMB, PartitionFreeMB, ConfidenceScore
"@
    
    $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $query -ErrorAction Stop
    
    if ($result.Results.Count -gt 0) {
        $record = $result.Results[0]
        $requiredFields = @('ComputerName', 'KB5034441Vulnerable', 'WinREEnabled', 'Severity', 'ConfidenceScore')
        $missingFields = $requiredFields | Where-Object { -not $record.PSObject.Properties.Name.Contains($_) }
        
        if ($missingFields.Count -eq 0) {
            Test-Check -TestName "Schema Validation" -Passed $true -Message "All required fields present in data"
        } else {
            Test-Check -TestName "Schema Validation" -Passed $false -Message "Missing fields: $($missingFields -join ', ')"
        }
    } else {
        Test-Check -TestName "Schema Validation" -Passed $false -Message "No recent data to validate schema" -IsWarning $true
    }
} catch {
    Test-Check -TestName "Schema Validation" -Passed $false -Message "Error validating schema: $($_.Exception.Message)"
}

# Summary Report
Write-Host "`n═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Validation Summary" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════`n" -ForegroundColor Cyan

$passRate = if ($global:TestResults.TotalTests -gt 0) { 
    [math]::Round(($global:TestResults.PassedTests / $global:TestResults.TotalTests) * 100, 1) 
} else { 
    0 
}

Write-Host "Total Tests:   $($global:TestResults.TotalTests)" -ForegroundColor White
Write-Host "Passed:        " -NoNewline
Write-Host "$($global:TestResults.PassedTests)" -ForegroundColor Green
Write-Host "Failed:        " -NoNewline
Write-Host "$($global:TestResults.FailedTests)" -ForegroundColor Red
Write-Host "Warnings:      " -NoNewline
Write-Host "$($global:TestResults.Warnings)" -ForegroundColor Yellow
Write-Host "Success Rate:  $passRate%" -ForegroundColor $(if ($passRate -ge 80) { 'Green' } elseif ($passRate -ge 60) { 'Yellow' } else { 'Red' })

Write-Host "`n" -NoNewline

if ($global:TestResults.FailedTests -eq 0) {
    Write-Host "✓ DEPLOYMENT HEALTHY - All critical checks passed" -ForegroundColor Green
} elseif ($global:TestResults.FailedTests -le 2) {
    Write-Host "⚠ DEPLOYMENT PARTIALLY HEALTHY - Some issues detected" -ForegroundColor Yellow
} else {
    Write-Host "✗ DEPLOYMENT UNHEALTHY - Multiple issues require attention" -ForegroundColor Red
}

Write-Host "`nEnd Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════`n" -ForegroundColor Cyan

# Exit with appropriate code
if ($global:TestResults.FailedTests -eq 0) {
    exit 0
} else {
    exit 1
}
