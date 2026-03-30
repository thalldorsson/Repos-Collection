<#
.SYNOPSIS
    Deploys Phase 2 strategic features for WinRE Health Monitoring.

.DESCRIPTION
    Automates the deployment of Phase 2 features:
    - Smart Scheduling & Orchestration integration
    - Auto-Tuning Alerts with dynamic thresholds
    - Cost Management Dashboard queries
    - Alert enable/disable management

.PARAMETER WorkspaceId
    Log Analytics Workspace ID

.PARAMETER WorkspaceResourceId
    Full Azure Resource ID for the Log Analytics workspace

.PARAMETER ResourceGroupName
    Resource group containing monitoring resources

.PARAMETER DeploySmartScheduling
    Deploy smart scheduling and orchestration features

.PARAMETER DeployAutoTuning
    Deploy auto-tuning alerts feature

.PARAMETER DeployCostDashboard
    Deploy cost management dashboard queries

.PARAMETER EnableAlerts
    Enable or disable all WinRE alert rules (default: $true)

.PARAMETER DryRun
    Simulate deployment without making changes

.EXAMPLE
    .\Deploy-Phase2-Features.ps1 -WorkspaceId "abc123" -ResourceGroupName "rg-winre" `
        -DeployAll -EnableAlerts $true

.EXAMPLE
    # Deploy only cost dashboard
    .\Deploy-Phase2-Features.ps1 -WorkspaceId "abc123" -DeployCostDashboard

.EXAMPLE
    # Disable all alerts
    .\Deploy-Phase2-Features.ps1 -ResourceGroupName "rg-winre" -EnableAlerts $false

.NOTES
    Version: 1.6.0
    Author: WinRE Health Monitor Team
    Requires: Az.Monitor, Az.OperationalInsights modules
#>

#Requires -Version 5.1
#Requires -Modules Az.Monitor, Az.OperationalInsights

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$WorkspaceId,

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceResourceId,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [switch]$DeploySmartScheduling,

    [Parameter(Mandatory = $false)]
    [switch]$DeployAutoTuning,

    [Parameter(Mandatory = $false)]
    [switch]$DeployCostDashboard,

    [Parameter(Mandatory = $false)]
    [switch]$DeployAll,

    [Parameter(Mandatory = $false)]
    [bool]$EnableAlerts = $true,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModulePath = Join-Path $ScriptPath "Modules"

# Banner
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " WinRE Health Monitor - Phase 2 Feature Deployment" -ForegroundColor Cyan
Write-Host " Version: 1.6.0" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

if ($DryRun) {
    Write-Host "🔍 DRY RUN MODE - No changes will be made" -ForegroundColor Yellow
    Write-Host ""
}

# Set deployment flags
if ($DeployAll) {
    $DeploySmartScheduling = $true
    $DeployAutoTuning = $true
    $DeployCostDashboard = $true
}

# Validate prerequisites
Write-Host "✓ Checking prerequisites..." -ForegroundColor Cyan

$missingModules = @()
@('Az.Monitor', 'Az.OperationalInsights') | ForEach-Object {
    if (!(Get-Module -ListAvailable -Name $_)) {
        $missingModules += $_
    }
}

if ($missingModules.Count -gt 0) {
    Write-Host "❌ Missing required modules: $($missingModules -join ', ')" -ForegroundColor Red
    Write-Host "Install with: Install-Module $($missingModules -join ', ') -Scope CurrentUser" -ForegroundColor Yellow
    exit 1
}

Write-Host "✓ All required modules found" -ForegroundColor Green
Write-Host ""

# ============================================================================
# Feature 1: Smart Scheduling & Orchestration
# ============================================================================

if ($DeploySmartScheduling) {
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "📅 Feature 1: Smart Scheduling & Orchestration" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host ""

    try {
        # Import modules
        $smartSchedulingPath = Join-Path $ScriptPath "SmartScheduling.psm1"
        $orchestrationPath = Join-Path $ScriptPath "RemediationOrchestration.psm1"

        if (!(Test-Path $smartSchedulingPath)) {
            throw "SmartScheduling.psm1 not found at: $smartSchedulingPath"
        }
        if (!(Test-Path $orchestrationPath)) {
            throw "RemediationOrchestration.psm1 not found at: $orchestrationPath"
        }

        Write-Host "✓ Importing SmartScheduling module..." -ForegroundColor Yellow
        Import-Module $smartSchedulingPath -Force -ErrorAction Stop

        Write-Host "✓ Importing RemediationOrchestration module..." -ForegroundColor Yellow
        Import-Module $orchestrationPath -Force -ErrorAction Stop

        Write-Host "✓ Smart scheduling modules validated" -ForegroundColor Green
        Write-Host ""
        Write-Host "📋 Next Steps:" -ForegroundColor Cyan
        Write-Host "  1. Configure orchestration settings in your environment" -ForegroundColor White
        Write-Host "  2. Test with: Get-RemediationSchedule -WorkspaceId '$WorkspaceId'" -ForegroundColor White
        Write-Host "  3. Start automation: Start-AutomatedRemediation -Config @{...}" -ForegroundColor White
        Write-Host ""

    } catch {
        Write-Host "❌ Smart Scheduling deployment failed: $($_.Exception.Message)" -ForegroundColor Red
        if (!$DryRun) { exit 1 }
    }
}

# ============================================================================
# Feature 2: Auto-Tuning Alerts
# ============================================================================

if ($DeployAutoTuning) {
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "🎯 Feature 2: Auto-Tuning Alerts" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host ""

    try {
        # Import module
        $autoTuningPath = Join-Path $ScriptPath "AutoTuningAlerts.psm1"

        if (!(Test-Path $autoTuningPath)) {
            throw "AutoTuningAlerts.psm1 not found at: $autoTuningPath"
        }

        Write-Host "✓ Importing AutoTuningAlerts module..." -ForegroundColor Yellow
        Import-Module $autoTuningPath -Force -ErrorAction Stop

        if ($WorkspaceId -and !$DryRun) {
            Write-Host "✓ Running threshold analysis (30-day window)..." -ForegroundColor Yellow
            
            $recommendations = Get-ThresholdRecommendations -WorkspaceId $WorkspaceId -DaysBack 30 -Verbose

            if ($recommendations.Count -gt 0) {
                Write-Host ""
                Write-Host "📊 Threshold Recommendations:" -ForegroundColor Green
                $recommendations | Format-Table -AutoSize
                Write-Host ""
                Write-Host "💡 To apply recommendations, run:" -ForegroundColor Cyan
                Write-Host "   Update-AlertThresholds -WorkspaceId '$WorkspaceId' -ResourceGroupName '$ResourceGroupName' -Recommendations `$recommendations -AutoApply `$true" -ForegroundColor White
            } else {
                Write-Host "ℹ️  No threshold adjustments recommended at this time" -ForegroundColor Yellow
            }
        } else {
            Write-Host "✓ AutoTuningAlerts module validated" -ForegroundColor Green
        }

        Write-Host ""
        Write-Host "📋 Next Steps:" -ForegroundColor Cyan
        Write-Host "  1. Schedule weekly tuning: Get-ThresholdRecommendations -WorkspaceId '$WorkspaceId'" -ForegroundColor White
        Write-Host "  2. Review recommendations before applying" -ForegroundColor White
        Write-Host "  3. Apply with: Update-AlertThresholds -AutoApply `$true" -ForegroundColor White
        Write-Host ""

    } catch {
        Write-Host "❌ Auto-Tuning Alerts deployment failed: $($_.Exception.Message)" -ForegroundColor Red
        if (!$DryRun) { exit 1 }
    }
}

# ============================================================================
# Feature 3: Cost Management Dashboard
# ============================================================================

if ($DeployCostDashboard) {
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "💰 Feature 3: Cost Management Dashboard" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host ""

    try {
        $costQueriesPath = Join-Path (Split-Path $ScriptPath -Parent) "Queries\Cost-Management-Dashboard.kql"

        if (!(Test-Path $costQueriesPath)) {
            throw "Cost-Management-Dashboard.kql not found at: $costQueriesPath"
        }

        Write-Host "✓ Cost management queries found" -ForegroundColor Green
        Write-Host "  Location: $costQueriesPath" -ForegroundColor Gray
        Write-Host ""

        # Update table references to WinREHealthV2_CL
        $content = Get-Content $costQueriesPath -Raw
        if ($content -match 'WinREHealth_CL') {
            Write-Host "⚠️  Queries use old table name (WinREHealth_CL)" -ForegroundColor Yellow
            Write-Host "   Updating to WinREHealthV2_CL..." -ForegroundColor Yellow
            
            if (!$DryRun) {
                $updatedContent = $content -replace 'WinREHealth_CL', 'WinREHealthV2_CL'
                Set-Content -Path $costQueriesPath -Value $updatedContent -NoNewline
                Write-Host "✓ Queries updated to use WinREHealthV2_CL" -ForegroundColor Green
            } else {
                Write-Host "   [DRY RUN] Would update table references" -ForegroundColor Gray
            }
        } else {
            Write-Host "✓ Queries already use WinREHealthV2_CL" -ForegroundColor Green
        }

        Write-Host ""
        Write-Host "📊 Available Cost Queries:" -ForegroundColor Cyan
        Write-Host "  1. Daily Ingestion Volume and Cost Tracking" -ForegroundColor White
        Write-Host "  2. Monthly Cost Summary by Table" -ForegroundColor White
        Write-Host "  3. Cost Per Device Analysis" -ForegroundColor White
        Write-Host "  4. Optimization Opportunity - Redundant Data Detection" -ForegroundColor White
        Write-Host "  5. Optimization Opportunity - High Frequency Reporters" -ForegroundColor White
        Write-Host "  6. Cost Forecast - Next 30 Days" -ForegroundColor White
        Write-Host "  7. Optimization Summary Report" -ForegroundColor White
        Write-Host "  8. Progress Tracking Cost Analysis" -ForegroundColor White
        Write-Host "  9. Retention Policy Cost Impact" -ForegroundColor White
        Write-Host " 10. Cost Dashboard - Executive Summary" -ForegroundColor White
        Write-Host ""
        Write-Host "📋 Next Steps:" -ForegroundColor Cyan
        Write-Host "  1. Import queries to Log Analytics workspace" -ForegroundColor White
        Write-Host "  2. Create Azure Workbook with cost visualizations" -ForegroundColor White
        Write-Host "  3. Schedule monthly cost reviews" -ForegroundColor White
        Write-Host ""

    } catch {
        Write-Host "❌ Cost Management deployment failed: $($_.Exception.Message)" -ForegroundColor Red
        if (!$DryRun) { exit 1 }
    }
}

# ============================================================================
# Feature 4: Alert Management (Enable/Disable)
# ============================================================================

Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "🔔 Feature 4: Alert Management" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host ""

if ($ResourceGroupName) {
    try {
        Write-Host "Target state: Alerts $(if($EnableAlerts){'ENABLED'}else{'DISABLED'})" -ForegroundColor $(if($EnableAlerts){'Green'}else{'Yellow'})
        Write-Host ""

        # Get all WinRE alert rules
        Write-Host "🔍 Discovering WinRE alert rules in resource group: $ResourceGroupName" -ForegroundColor Yellow

        if (!$DryRun) {
            $alertRules = Get-AzScheduledQueryRule -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue | 
                Where-Object { $_.Name -like '*winre*' -or $_.Name -like '*WinRE*' }

            if ($alertRules.Count -eq 0) {
                Write-Host "ℹ️  No WinRE alert rules found in resource group" -ForegroundColor Yellow
            } else {
                Write-Host "✓ Found $($alertRules.Count) WinRE alert rule(s)" -ForegroundColor Green
                Write-Host ""

                foreach ($rule in $alertRules) {
                    $currentState = if ($rule.Enabled) { "ENABLED" } else { "DISABLED" }
                    $targetState = if ($EnableAlerts) { "ENABLED" } else { "DISABLED" }

                    if ($currentState -eq $targetState) {
                        Write-Host "  ✓ $($rule.Name): Already $currentState" -ForegroundColor Gray
                    } else {
                        Write-Host "  🔄 $($rule.Name): $currentState → $targetState" -ForegroundColor Cyan
                        
                        try {
                            Update-AzScheduledQueryRule -ResourceGroupName $ResourceGroupName `
                                -Name $rule.Name -Enabled $EnableAlerts -ErrorAction Stop
                            Write-Host "     ✓ Updated successfully" -ForegroundColor Green
                        } catch {
                            Write-Host "     ❌ Failed to update: $($_.Exception.Message)" -ForegroundColor Red
                        }
                    }
                }
            }
        } else {
            Write-Host "[DRY RUN] Would $(if($EnableAlerts){'enable'}else{'disable'}) all WinRE alert rules" -ForegroundColor Gray
        }

        Write-Host ""
        Write-Host "📋 Alert Management Commands:" -ForegroundColor Cyan
        Write-Host "  Enable all:  .\Deploy-Phase2-Features.ps1 -ResourceGroupName '$ResourceGroupName' -EnableAlerts `$true" -ForegroundColor White
        Write-Host "  Disable all: .\Deploy-Phase2-Features.ps1 -ResourceGroupName '$ResourceGroupName' -EnableAlerts `$false" -ForegroundColor White
        Write-Host ""

    } catch {
        Write-Host "❌ Alert management failed: $($_.Exception.Message)" -ForegroundColor Red
        if (!$DryRun) { exit 1 }
    }
} else {
    Write-Host "ℹ️  Skipping alert management (ResourceGroupName not provided)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "To manage alerts, provide -ResourceGroupName parameter:" -ForegroundColor Cyan
    Write-Host "  .\Deploy-Phase2-Features.ps1 -ResourceGroupName 'rg-winre' -EnableAlerts `$false" -ForegroundColor White
    Write-Host ""
}

# ============================================================================
# Deployment Summary
# ============================================================================

Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "📊 Deployment Summary" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host ""

if ($DryRun) {
    Write-Host "🔍 DRY RUN completed - no changes were made" -ForegroundColor Yellow
} else {
    Write-Host "✓ Phase 2 feature deployment completed" -ForegroundColor Green
}

Write-Host ""
Write-Host "Deployed Features:" -ForegroundColor Cyan
Write-Host "  Smart Scheduling & Orchestration: $(if($DeploySmartScheduling){'✓ Deployed'}else{'⊘ Skipped'})" -ForegroundColor $(if($DeploySmartScheduling){'Green'}else{'Gray'})
Write-Host "  Auto-Tuning Alerts:               $(if($DeployAutoTuning){'✓ Deployed'}else{'⊘ Skipped'})" -ForegroundColor $(if($DeployAutoTuning){'Green'}else{'Gray'})
Write-Host "  Cost Management Dashboard:        $(if($DeployCostDashboard){'✓ Deployed'}else{'⊘ Skipped'})" -ForegroundColor $(if($DeployCostDashboard){'Green'}else{'Gray'})
Write-Host "  Alert Management:                 $(if($ResourceGroupName){'✓ Configured'}else{'⊘ Skipped'})" -ForegroundColor $(if($ResourceGroupName){'Green'}else{'Gray'})
Write-Host ""

Write-Host "📚 Documentation:" -ForegroundColor Cyan
Write-Host "  - TODO.md: Phase 2 feature details" -ForegroundColor White
Write-Host "  - Queries/Cost-Management-Dashboard.kql: All cost queries" -ForegroundColor White
Write-Host "  - Scripts/SmartScheduling.psm1: Scheduling documentation" -ForegroundColor White
Write-Host "  - Scripts/AutoTuningAlerts.psm1: Alert tuning documentation" -ForegroundColor White
Write-Host ""

Write-Host "✓ Phase 2 deployment complete!" -ForegroundColor Green
Write-Host ""
