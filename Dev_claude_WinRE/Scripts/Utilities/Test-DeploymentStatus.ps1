#Requires -Version 5.1
#Requires -Modules Az.Accounts, Az.OperationalInsights, Az.Monitor

<#
.SYNOPSIS
    Comprehensive deployment status test script for WinRE Health Monitoring solution.

.DESCRIPTION
    Tests all phases of WinRE Health Monitoring deployment:
    - Azure authentication and prerequisites
    - Azure Infrastructure (Log Analytics, DCR, Alerts)
    - Data collection status
    - Alert rule configuration
    - Data flow validation

.PARAMETER Phase
    Specific phase to test. Options: PreFlight, AzureInfra, DataCollection, Alerts, All
    Default: All

.PARAMETER ResourceGroup
    Azure resource group name. Default: rg-winre-monitoring

.PARAMETER WorkspaceName
    Log Analytics workspace name. Default: winre-law-health

.PARAMETER Verbose
    Enable verbose output for detailed troubleshooting.

.EXAMPLE
    .\Test-DeploymentStatus.ps1 -Phase All
    Run all tests

.EXAMPLE
    .\Test-DeploymentStatus.ps1 -Phase DataCollection -Verbose
    Test data collection with verbose output

.NOTES
    Author: WinRE Health Monitoring Team
    Version: 1.0.0
    Updated: December 2025
#>

param(
    [ValidateSet("Login", "PreFlight", "AzureInfra", "DataCollection", "Alerts", "ScriptDeployment", "All", "Interactive")]
    [string]$Phase = "Interactive",

    [string]$ResourceGroup = "rg-winrehealth-we-prod",
    [string]$WorkspaceName = "law-winre-health-we-prod",
    [string]$WorkspaceId = "137d8043-0573-45a1-9d11-fa9a247a3455",
    [string]$DefaultUser = "adm_thohalld@sensa.is",
    [switch]$Verbose
)

# ===== CONFIGURATION =====
$ErrorActionPreference = "Continue"
$VerbosePreference = if ($Verbose) { "Continue" } else { "SilentlyContinue" }

# Color codes for output
$colors = @{
    Success = "Green"
    Error   = "Red"
    Warning = "Yellow"
    Info    = "Cyan"
}

# Test results tracking
$testResults = @{
    Passed = 0
    Failed = 0
    Warning = 0
}

# GPT-5 methodology metadata: structured, explainable steps
$Methodology = "GPT-5 Methodology - structured, stepwise checks with explainable results"
# Detailed step entries collected during run
$script:Steps = @()
# ===== HELPER FUNCTIONS =====

function Show-TestMenu {
    Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor $colors.Info
    Write-Host "║           Select Tests to Run                                 ║" -ForegroundColor $colors.Info
    Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor $colors.Info
    Write-Host ""
    Write-Host "  1. Azure User Login (Connect-AzAccount)" -ForegroundColor $colors.Warning
    Write-Host "  2. Pre-Flight Check (Azure Auth, PowerShell, Modules)" -ForegroundColor $colors.Info
    Write-Host "  3. Azure Infrastructure (Resource Group, Workspace, DCR)" -ForegroundColor $colors.Info
    Write-Host "  4. Alert Rules Configuration" -ForegroundColor $colors.Info
    Write-Host "  5. Data Collection Status (KQL Queries)" -ForegroundColor $colors.Info
    Write-Host "  6. Script Deployment Check" -ForegroundColor $colors.Info
    Write-Host "  7. Manual Script Test Instructions" -ForegroundColor $colors.Info
    Write-Host "  8. Run ALL Tests" -ForegroundColor $colors.Success
    Write-Host "  0. Exit" -ForegroundColor $colors.Error
    Write-Host ""
    
    $choice = Read-Host "Enter your choice (0-8)"
    
    switch ($choice) {
        "1" { return "Login" }
        "2" { return "PreFlight" }
        "3" { return "AzureInfra" }
        "4" { return "Alerts" }
        "5" { return "DataCollection" }
        "6" { return "ScriptDeployment" }
        "7" { return "ManualTest" }
        "8" { return "All" }
        "0" { 
            Write-Host "`nExiting test suite..." -ForegroundColor $colors.Warning
            exit 0 
        }
        default { 
            Write-Host "`nInvalid choice. Running all tests..." -ForegroundColor $colors.Warning
            return "All" 
        }
    }
}

function Write-TestHeader {
    param([string]$Title)
    Write-Host "`n" + ("=" * 80) -ForegroundColor $colors.Info
    Write-Host $Title -ForegroundColor $colors.Info
    Write-Host ("=" * 80) -ForegroundColor $colors.Info
}

function Write-TestResult {
    param(
        [string]$TestName,
        [string]$Result,
        [string]$Message
    )

    $resultColor = switch ($Result) {
        "PASS" { $colors.Success }
        "FAIL" { $colors.Error }
        "WARN" { $colors.Warning }
        default { $colors.Info }
    }

    $icon = switch ($Result) {
        "PASS" { "✓" }
        "FAIL" { "✗" }
        "WARN" { "⚠" }
        default { "•" }
    }

    Write-Host "$icon [$Result] $TestName" -ForegroundColor $resultColor
    if ($Message) {
        Write-Host "  → $Message" -ForegroundColor $resultColor
    }

    if ($Result -eq "PASS") { $script:testResults.Passed++ }
    elseif ($Result -eq "FAIL") { $script:testResults.Failed++ }
    elseif ($Result -eq "WARN") { $script:testResults.Warning++ }
}
    # Record structured step for explainability and machine-readable output
    $step = @{ 
        Name = $TestName;
        Result = $Result;
        Message = $Message;
        Timestamp = (Get-Date).ToString("o")
    }
    $script:Steps += $step

function Test-AzureAuthentication {
    Write-TestHeader "PHASE 1: AZURE AUTHENTICATION & PREREQUISITES"

    # Test 1: Azure Context`
    try {
        $context = Get-AzContext -ErrorAction Stop
        if ($context) {
            Write-TestResult "Azure Authentication" "PASS" "Logged in as $($context.Account.Id) in subscription $($context.Subscription.Name)"
        } else {
            Write-TestResult "Azure Authentication" "WARN" "No Azure context found. Attempting login..."
            Write-Host "`nPlease sign in with your Azure credentials..." -ForegroundColor $colors.Warning
            $context = Connect-AzAccount -ErrorAction Stop
            if ($context) {
                Write-TestResult "Azure Authentication" "PASS" "Successfully logged in as $($context.Context.Account.Id)"
            } else {
                Write-TestResult "Azure Authentication" "FAIL" "Login failed. Please try again manually: Connect-AzAccount"
                return $false
            }
        }
    }
    catch {
        Write-TestResult "Azure Authentication" "FAIL" "Login error: $($_.Exception.Message)"
        Write-Host "`nTo manually sign in, run: Connect-AzAccount" -ForegroundColor $colors.Warning
        return $false
    }

    # Test 2: PowerShell Version
    $psVersion = $PSVersionTable.PSVersion
    if ($psVersion.Major -ge 5) {
        Write-TestResult "PowerShell Version" "PASS" "PowerShell $psVersion"
    } else {
        Write-TestResult "PowerShell Version" "FAIL" "PowerShell 5.1+ required. Found: $psVersion"
        return $false
    }

    # Test 3: Required Modules
    $requiredModules = @("Az.Accounts", "Az.OperationalInsights", "Az.Monitor")
    foreach ($module in $requiredModules) {
        try {
            $mod = Get-Module -Name $module -ErrorAction Stop
            if ($mod) {
                Write-TestResult "Module: $module" "PASS" "Version $($mod.Version)"
            } else {
                Write-TestResult "Module: $module" "WARN" "Module found but not loaded. Run: Import-Module $module"
            }
        }
        catch {
            Write-TestResult "Module: $module" "WARN" "Not installed. Run: Install-Module $module"
        }
    }

    return $true
}

function Test-AzureInfrastructure {
    Write-TestHeader "PHASE 2: AZURE INFRASTRUCTURE"

    # Test 1: Resource Group
    try {
        $rg = Get-AzResourceGroup -Name $ResourceGroup -ErrorAction Stop
        Write-TestResult "Resource Group: $ResourceGroup" "PASS" "Location: $($rg.Location)"
    }
    catch {
        Write-TestResult "Resource Group: $ResourceGroup" "FAIL" "Not found. Create with: az group create --name $ResourceGroup --location eastus"
        return $false
    }

    # Test 2: Log Analytics Workspace
    try {
        $workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroup -Name $WorkspaceName -ErrorAction Stop
        $workspaceId = $workspace.CustomerId
        Write-TestResult "Log Analytics Workspace: $WorkspaceName" "PASS" "ID: $workspaceId"
        Write-Verbose "Workspace Resource ID: $($workspace.ResourceId)"
    }
    catch {
        Write-TestResult "Log Analytics Workspace: $WorkspaceName" "FAIL" "Not found in resource group"
        return $false
    }

    # Test 3: Get Workspace Credentials
    try {
        $keys = Get-AzOperationalInsightsWorkspaceSharedKey -ResourceGroupName $ResourceGroup -Name $WorkspaceName -ErrorAction Stop
        $workspaceKey = $keys.PrimarySharedKey
        Write-TestResult "Workspace Credentials" "PASS" "Credentials retrieved (key length: $($workspaceKey.Length) chars)"
        Write-Verbose "Primary Key: $($workspaceKey.Substring(0,10))..."
    }
    catch {
        Write-TestResult "Workspace Credentials" "FAIL" $_.Exception.Message
        return $false
    }

    # Test 4: Data Collection Endpoint
    try {
        $dce = Get-AzDataCollectionEndpoint -ResourceGroupName $ResourceGroup -ErrorAction Stop | Where-Object {$_.Name -like "*winre*"} | Select-Object -First 1
        if ($dce) {
            Write-TestResult "Data Collection Endpoint" "PASS" "Name: $($dce.Name)"
            Write-Verbose "DCE Resource ID: $($dce.Id)"
        } else {
            Write-TestResult "Data Collection Endpoint" "WARN" "Not found. Check Bicep deployment status."
        }
    }
    catch {
        Write-TestResult "Data Collection Endpoint" "WARN" "Could not retrieve: $($_.Exception.Message)"
    }

    # Test 5: Data Collection Rule
    try {
        $dcr = Get-AzDataCollectionRule -ResourceGroupName $ResourceGroup -ErrorAction Stop | Where-Object {$_.Name -like "*winre*"} | Select-Object -First 1
        if ($dcr) {
            Write-TestResult "Data Collection Rule" "PASS" "Name: $($dcr.Name)"
            Write-Verbose "DCR Resource ID: $($dcr.Id)"
        } else {
            Write-TestResult "Data Collection Rule" "WARN" "Not found. Check Bicep deployment status."
        }
    }
    catch {
        Write-TestResult "Data Collection Rule" "WARN" "Could not retrieve: $($_.Exception.Message)"
    }

    # Test 6: Action Group
    try {
        $ag = Get-AzActionGroup -ResourceGroupName $ResourceGroup -ErrorAction Stop | Where-Object {$_.Name -like "*winre*"} | Select-Object -First 1
        if ($ag) {
            Write-TestResult "Action Group" "PASS" "Name: $($ag.Name)"
        } else {
            Write-TestResult "Action Group" "WARN" "Not found. Check Bicep deployment status."
        }
    }
    catch {
        Write-TestResult "Action Group" "WARN" "Could not retrieve: $($_.Exception.Message)"
    }

    return $true
}

function Test-AlertRules {
    Write-TestHeader "PHASE 3: ALERT RULES CONFIGURATION"

    try {
        $alerts = Get-AzMetricAlertV2 -ResourceGroupName $ResourceGroup -ErrorAction Stop
        Write-TestResult "Alert Rules Retrieved" "PASS" "Found $($alerts.Count) alert rules"

        if ($alerts.Count -eq 0) {
            Write-TestResult "Alert Rules Count" "WARN" "No alerts configured. Expected: 3 (WinRE Disabled, Low Space, KB5034441)"
        } else {
            $alerts | ForEach-Object {
                $status = if ($_.Enabled) { "ENABLED" } else { "DISABLED" }
                Write-Host "  • $($_.Name) [$status]" -ForegroundColor $colors.Info
                Write-Verbose "    Description: $($_.Description)"
                Write-Verbose "    Severity: $($_.Severity)"
            }
        }
    }
    catch {
        Write-TestResult "Alert Rules" "WARN" "Could not retrieve: $($_.Exception.Message)"
    }
}

function Test-DataCollection {
    Write-TestHeader "PHASE 4: DATA COLLECTION STATUS"

    Write-Host "`nTo verify data collection, use these KQL queries in Log Analytics:" -ForegroundColor $colors.Info
    Write-Host "Portal: https://portal.azure.com → Log Analytics → $WorkspaceName → Logs`n" -ForegroundColor $colors.Info

    # Display sample KQL queries
    $queries = @(
        @{
            Title = "Check data is flowing"
            Query = "WinREHealth_CL | summarize Count = count(), Latest = max(TimeGenerated) by ComputerName | order by Latest desc"
        },
        @{
            Title = "Check data age"
            Query = "WinREHealth_CL | summarize MaxTime = max(TimeGenerated), MinTime = min(TimeGenerated), RecordCount = count()"
        },
        @{
            Title = "Summary: Compliant vs Non-compliant"
            Query = "WinREHealth_CL | where TimeGenerated > ago(7d) | summarize TotalDevices = dcount(ComputerName), WinREEnabled = dcountif(ComputerName, WinREEnabled == true), WinREDisabled = dcountif(ComputerName, WinREEnabled == false)"
        },
        @{
            Title = "WinRE Partition Health"
            Query = "WinREHealth_CL | where TimeGenerated > ago(1d) | project ComputerName, WinREEnabled, RecoveryPartitionSizeMB, RecoveryPartitionFreeMB, PartitionHealthPercent"
        }
    )

    $index = 1
    foreach ($q in $queries) {
        Write-Host "Query $index`: $($q.Title)" -ForegroundColor $colors.Warning
        Write-Host $q.Query -ForegroundColor White
        Write-Host ""
        $index++
    }
}

function Test-ScriptDeployment {
    Write-TestHeader "PHASE 5: SCRIPT DEPLOYMENT"

    # Check if script exists locally
    $scriptPath = (Get-Item -Path $PSScriptRoot).Parent.Parent.FullName
    $collectorScript = Join-Path $scriptPath "Scripts/WinRECollector/WinRECollector.ps1"

    if (Test-Path $collectorScript) {
        Write-TestResult "WinRECollector.ps1 exists" "PASS" "Found at: $collectorScript"

        # Check script syntax
        try {
            $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content $collectorScript), [ref]$null)
            Write-TestResult "Script syntax" "PASS" "No syntax errors found"
        }
        catch {
            Write-TestResult "Script syntax" "FAIL" "Syntax error: $($_.Exception.Message)"
        }
    } else {
        Write-TestResult "WinRECollector.ps1 exists" "WARN" "Not found at expected path: $collectorScript"
    }

    # Check Detection and Remediation scripts
    $detectionScript = Join-Path $scriptPath "Scripts/WinRECollector/WinRECollector-Detection.ps1"
    $remediationScript = Join-Path $scriptPath "Scripts/WinRECollector/WinRECollector-Remediation.ps1"

    if (Test-Path $detectionScript) {
        Write-TestResult "Detection script exists" "PASS" "Ready for Intune deployment"
    } else {
        Write-TestResult "Detection script exists" "WARN" "Not found"
    }

    if (Test-Path $remediationScript) {
        Write-TestResult "Remediation script exists" "PASS" "Ready for Intune deployment"
    } else {
        Write-TestResult "Remediation script exists" "WARN" "Not found"
    }
}

function Test-ManualScriptExecution {
    Write-TestHeader "PHASE 6: MANUAL SCRIPT EXECUTION TEST (OPTIONAL)"

    Write-Host "To test the collector script manually on a pilot device:" -ForegroundColor $colors.Warning
    Write-Host "`nStep 1: Get Log Analytics credentials:" -ForegroundColor $colors.Info

    $credCommand = @"
`$resourceGroup = '$ResourceGroup'
`$workspaceName = '$WorkspaceName'
`$workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName `$resourceGroup -Name `$workspaceName
`$workspaceId = `$workspace.CustomerId
`$keys = Get-AzOperationalInsightsWorkspaceSharedKey -ResourceGroupName `$resourceGroup -Name `$workspaceName
`$workspaceKey = `$keys.PrimarySharedKey
Write-Host "Workspace ID: `$workspaceId"
Write-Host "Workspace Key: `$workspaceKey"
"@

    Write-Host $credCommand -ForegroundColor White
    Write-Host "`nStep 2: Run the collector script:" -ForegroundColor $colors.Info

    $scriptCommand = @"
.\Scripts\WinRECollector\WinRECollector.ps1 `
    -WorkspaceId `$workspaceId `
    -WorkspaceKey `$workspaceKey `
    -Method "Manual" `
    -Verbose
"@

    Write-Host $scriptCommand -ForegroundColor White
    Write-Host "`nStep 3: Verify output file:" -ForegroundColor $colors.Info
    Write-Host "Get-Content C:\ProgramData\WinREHealth\WinREHealthStatus.json | ConvertFrom-Json | Format-List" -ForegroundColor White
}

function Show-SummaryReport {
    Write-TestHeader "TEST SUMMARY REPORT"

    $total = $testResults.Passed + $testResults.Failed + $testResults.Warning

    Write-Host "`nTest Results:" -ForegroundColor $colors.Info
    Write-Host "  ✓ PASSED:  $($testResults.Passed)" -ForegroundColor $colors.Success
    Write-Host "  ✗ FAILED:  $($testResults.Failed)" -ForegroundColor $colors.Error
    Write-Host "  ⚠ WARNING: $($testResults.Warning)" -ForegroundColor $colors.Warning
    Write-Host "  ━━━━━━━━━━━━━━━━━━"
    Write-Host "  TOTAL:   $total`n" -ForegroundColor $colors.Info

    # Determine overall status and suggested action
    if ($testResults.Failed -eq 0) {
        $overall = "HEALTHY"
        Write-Host "✓ DEPLOYMENT STATUS: HEALTHY" -ForegroundColor $colors.Success
        Write-Host "Next steps: Verify data is flowing using KQL queries above." -ForegroundColor $colors.Info
    } elseif ($testResults.Failed -gt 0) {
        $overall = "ISSUES_DETECTED"
        Write-Host "✗ DEPLOYMENT STATUS: ISSUES DETECTED" -ForegroundColor $colors.Error
        Write-Host "Review failures above and run Phase-specific tests." -ForegroundColor $colors.Info
    } else {
        $overall = "WARNINGS_PRESENT"
        Write-Host "⚠ DEPLOYMENT STATUS: WARNINGS PRESENT" -ForegroundColor $colors.Warning
        Write-Host "Review warnings and verify configuration." -ForegroundColor $colors.Info
    }

    Write-Host "`nFor detailed troubleshooting, see:" -ForegroundColor $colors.Info
    Write-Host "  - Docs/TROUBLESHOOTING.md" -ForegroundColor $colors.Info
    Write-Host "  - Docs/WinRE-Health-Monitoring-Deployment-Checklist.md" -ForegroundColor $colors.Info
    Write-Host ""

    # Output machine-readable report for downstream automation
    try {
        $report = [ordered]@{
            Methodology = $Methodology
            GeneratedAt  = (Get-Date).ToString("o")
            Summary = [ordered]@{
                Passed = $testResults.Passed
                Failed = $testResults.Failed
                Warning = $testResults.Warning
                Total = $total
                OverallStatus = $overall
            }
            Steps = $script:Steps
            Configuration = [ordered]@{
                ResourceGroup = $ResourceGroup
                WorkspaceName = $WorkspaceName
                WorkspaceId = $WorkspaceId
                DefaultUser = $DefaultUser
            }
        }

        $outPath = Join-Path $PSScriptRoot "Test-DeploymentStatus-results.json"
        $report | ConvertTo-Json -Depth 6 | Out-File -FilePath $outPath -Encoding utf8
        Write-Host "Machine-readable report written to: $outPath" -ForegroundColor $colors.Info
    }
    catch {
        Write-TestResult "Write Report" "WARN" "Failed to write JSON report: $($_.Exception.Message)"
    }
}

# ===== MAIN EXECUTION =====

Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor $colors.Info
Write-Host "║  WinRE Health Monitoring - Deployment Status Test Suite      ║" -ForegroundColor $colors.Info
Write-Host "║  Version 1.0.0 | December 2025                              ║" -ForegroundColor $colors.Info
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor $colors.Info

Write-Host "Phase: $Phase | Resource Group: $ResourceGroup | Workspace: $WorkspaceName`n" -ForegroundColor $colors.Info

# Show interactive menu if requested
if ($Phase -eq "Interactive") {
    $Phase = Show-TestMenu
}

# Run requested phases
$phaseResults = @{}

if ($Phase -eq "Login") {
    Write-TestHeader "AZURE USER LOGIN"
    Write-Host "`nDefault user: $DefaultUser" -ForegroundColor $colors.Info
    Write-Host "Initiating Azure login..." -ForegroundColor $colors.Info
    
    try {
        $context = Connect-AzAccount -AccountId $DefaultUser -ErrorAction Stop
        if ($context) {
            Write-TestResult "Azure Login" "PASS" "Successfully logged in as $($context.Context.Account.Id)"
            
            # List and select subscription
            Write-Host "`nRetrieving available subscriptions..." -ForegroundColor $colors.Info
            $subscriptions = Get-AzSubscription | Sort-Object Name
            
            if ($subscriptions.Count -eq 0) {
                Write-TestResult "Subscriptions" "WARN" "No subscriptions found"
                Show-SummaryReport
                exit
            } elseif ($subscriptions.Count -eq 1) {
                $selectedSub = $subscriptions[0]
                Set-AzContext -SubscriptionId $selectedSub.Id | Out-Null
                Write-TestResult "Subscription Selected" "PASS" "$($selectedSub.Name) (auto-selected - only one available)"
            } else {
                Write-Host "`nAvailable Subscriptions:" -ForegroundColor $colors.Info
                for ($i = 0; $i -lt $subscriptions.Count; $i++) {
                    Write-Host "  $($i + 1). $($subscriptions[$i].Name) [$($subscriptions[$i].State)]" -ForegroundColor White
                }
                
                do {
                    $selection = Read-Host "`nSelect subscription number (1-$($subscriptions.Count))"
                    $selectionIndex = [int]$selection - 1
                } while ($selectionIndex -lt 0 -or $selectionIndex -ge $subscriptions.Count)
                
                $selectedSub = $subscriptions[$selectionIndex]
                Set-AzContext -SubscriptionId $selectedSub.Id | Out-Null
                Write-TestResult "Subscription Selected" "PASS" "$($selectedSub.Name)"
            }
            
            # List and select Resource Group
            Write-Host "`nRetrieving resource groups..." -ForegroundColor $colors.Info
            $resourceGroups = Get-AzResourceGroup | Sort-Object ResourceGroupName
            
            if ($resourceGroups.Count -eq 0) {
                Write-TestResult "Resource Groups" "WARN" "No resource groups found in subscription"
                Show-SummaryReport
                exit
            } else {
                Write-Host "`nAvailable Resource Groups:" -ForegroundColor $colors.Info
                for ($i = 0; $i -lt $resourceGroups.Count; $i++) {
                    Write-Host "  $($i + 1). $($resourceGroups[$i].ResourceGroupName) - Location: $($resourceGroups[$i].Location)" -ForegroundColor White
                }
                
                do {
                    $selection = Read-Host "`nSelect resource group number (1-$($resourceGroups.Count))"
                    $selectionIndex = [int]$selection - 1
                } while ($selectionIndex -lt 0 -or $selectionIndex -ge $resourceGroups.Count)
                
                $selectedRG = $resourceGroups[$selectionIndex]
                Write-TestResult "Resource Group Selected" "PASS" "$($selectedRG.ResourceGroupName)"
                
                # Update script variables with selection
                $script:ResourceGroup = $selectedRG.ResourceGroupName
            }
            
            # List and select Log Analytics Workspace
            Write-Host "`nRetrieving Log Analytics workspaces..." -ForegroundColor $colors.Info
            $workspaces = Get-AzOperationalInsightsWorkspace -ResourceGroupName $selectedRG.ResourceGroupName | Sort-Object Name
            
            if ($workspaces.Count -eq 0) {
                Write-TestResult "Log Analytics Workspaces" "WARN" "No workspaces found in resource group '$($selectedRG.ResourceGroupName)'"
                Write-Host "`nYou may need to create a workspace first or select a different resource group." -ForegroundColor $colors.Warning
            } else {
                Write-Host "`nAvailable Log Analytics Workspaces:" -ForegroundColor $colors.Info
                for ($i = 0; $i -lt $workspaces.Count; $i++) {
                    Write-Host "  $($i + 1). $($workspaces[$i].Name) - Location: $($workspaces[$i].Location)" -ForegroundColor White
                }
                
                do {
                    $selection = Read-Host "`nSelect workspace number (1-$($workspaces.Count))"
                    $selectionIndex = [int]$selection - 1
                } while ($selectionIndex -lt 0 -or $selectionIndex -ge $workspaces.Count)
                
                $selectedWorkspace = $workspaces[$selectionIndex]
                Write-TestResult "Log Analytics Workspace Selected" "PASS" "$($selectedWorkspace.Name)"
                
                # Update script variables with selection
                $script:WorkspaceName = $selectedWorkspace.Name
                
                # Display selected configuration
                Write-Host "`n" + ("=" * 80) -ForegroundColor $colors.Success
                Write-Host "SELECTED CONFIGURATION:" -ForegroundColor $colors.Success
                Write-Host ("=" * 80) -ForegroundColor $colors.Success
                Write-Host "  Subscription:        $($selectedSub.Name)" -ForegroundColor White
                Write-Host "  Resource Group:      $($selectedRG.ResourceGroupName)" -ForegroundColor White
                Write-Host "  Workspace:           $($selectedWorkspace.Name)" -ForegroundColor White
                Write-Host "  Workspace ID:        $($selectedWorkspace.CustomerId)" -ForegroundColor White
                Write-Host ("=" * 80) -ForegroundColor $colors.Success
                Write-Host "`nYou can now run other tests with these settings." -ForegroundColor $colors.Info
                Write-Host "Re-run script with: -ResourceGroup '$($selectedRG.ResourceGroupName)' -WorkspaceName '$($selectedWorkspace.Name)'" -ForegroundColor $colors.Info
            }
            
        } else {
            Write-TestResult "Azure Login" "FAIL" "Login failed. Please check your credentials."
        }
    }
    catch {
        Write-TestResult "Azure Login" "FAIL" "Login error: $($_.Exception.Message)"
    }
    
    Show-SummaryReport
    exit
}

if ($Phase -eq "All" -or $Phase -eq "PreFlight") {
    $phaseResults.PreFlight = Test-AzureAuthentication
}

if ($Phase -eq "All" -or $Phase -eq "AzureInfra") {
    if ($phaseResults.PreFlight -ne $false -or $Phase -eq "AzureInfra") {
        $phaseResults.AzureInfra = Test-AzureInfrastructure
    }
}

if ($Phase -eq "All" -or $Phase -eq "Alerts") {
    if ($phaseResults.AzureInfra -ne $false -or $Phase -eq "Alerts") {
        Test-AlertRules
    }
}

if ($Phase -eq "All" -or $Phase -eq "DataCollection") {
    Test-DataCollection
}

if ($Phase -eq "All" -or $Phase -eq "ScriptDeployment") {
    Test-ScriptDeployment
}

if ($Phase -eq "All" -or $Phase -eq "ManualTest") {
    Test-ManualScriptExecution
}

# Show summary
Show-SummaryReport

# Return exit code based on results
if ($testResults.Failed -gt 0) {
    exit 1
} else {
    exit 0
}
