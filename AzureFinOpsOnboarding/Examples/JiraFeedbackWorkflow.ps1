#!/usr/bin/env powershell
<#
.SYNOPSIS
    Example: Complete Jira feedback workflow with AzureFinOpsOnboarding

.DESCRIPTION
    Demonstrates end-to-end onboarding workflow with automatic Jira issue updates.
    Shows both direct REST and MCP-delegated approaches.

.EXAMPLE
    .\JiraFeedbackWorkflow.ps1 -TenantId "your-tenant" -ApplicationId "your-app" -CustomerName "Contoso"
#>

param(
    [string]$TenantId,
    [string]$ApplicationId,
    [SecureString]$ClientSecret,
    [string]$CustomerName = "Contoso",
    [string]$PrimaryDomain = "contoso.com",
    [string]$JiraIssueKey = "TEST-123",
    [string]$JiraUsername,
    [SecureString]$JiraApiToken
)

# ============================================================================
# SCENARIO 1: Simple - Auto-publish with REST API
# ============================================================================
function Scenario1-SimpleAutoPublish {
    Write-Host "=== Scenario 1: Auto-publish to Jira (REST) ===" -ForegroundColor Cyan
    
    # Get credentials
    if (-not $JiraApiToken) {
        Write-Host "Enter Jira credentials (if prompted)..."
        $username = Read-Host "Jira username (email)"
        $token = Read-Host "Jira API token" -AsSecureString
    } else {
        $username = $JiraUsername
        $token = $JiraApiToken
    }
    
    # Run onboarding with automatic Jira feedback
    Write-Host "Starting onboarding for $CustomerName..." -ForegroundColor Green
    
    $result = Invoke-FinOpsOnboarding `
        -TenantId $TenantId `
        -ApplicationId $ApplicationId `
        -ClientSecret $ClientSecret `
        -CustomerName $CustomerName `
        -PrimaryDomain $PrimaryDomain `
        -PublishToJira `
        -JiraIssueKey $JiraIssueKey `
        -JiraUsername $username `
        -JiraApiToken $token `
        -PassThru
    
    if ($result) {
        Write-Host "✅ Onboarding complete" -ForegroundColor Green
        Write-Host "📝 Summary: $($result.Checks.Count) checks performed" -ForegroundColor Green
    }
}

# ============================================================================
# SCENARIO 2: Advanced - Manual control with status transition
# ============================================================================
function Scenario2-ManualControlWithTransition {
    Write-Host "=== Scenario 2: Manual control + Status transition ===" -ForegroundColor Cyan
    
    if (-not $JiraApiToken) {
        $username = Read-Host "Jira username (email)"
        $token = Read-Host "Jira API token" -AsSecureString
    } else {
        $username = $JiraUsername
        $token = $JiraApiToken
    }
    
    Write-Host "Step 1: Run onboarding (without auto-publish)..." -ForegroundColor Green
    $result = Invoke-FinOpsOnboarding `
        -TenantId $TenantId `
        -ApplicationId $ApplicationId `
        -ClientSecret $ClientSecret `
        -CustomerName $CustomerName `
        -PrimaryDomain $PrimaryDomain `
        -PassThru
    
    Write-Host "Step 2: Get available Jira transitions..." -ForegroundColor Green
    $transitions = Get-FinOpsJiraIssueTransitions `
        -IssueKey $JiraIssueKey `
        -Username $username `
        -ApiToken $token
    
    Write-Host "Available transitions:" -ForegroundColor Yellow
    $transitions | ForEach-Object { Write-Host "  - $($_.to.name) (id: $($_.id))" }
    
    Write-Host "Step 3: Post completion comment..." -ForegroundColor Green
    Add-FinOpsJiraComment `
        -IssueKey $JiraIssueKey `
        -Comment "Onboarding completed successfully. All validations passed." `
        -Username $username `
        -ApiToken $token | Out-Null
    
    Write-Host "Step 4: Transition issue to 'Done'..." -ForegroundColor Green
    Update-FinOpsJiraIssueStatus `
        -IssueKey $JiraIssueKey `
        -TargetStatus "Done" `
        -Comment "Transition: Onboarding complete" `
        -Username $username `
        -ApiToken $token
    
    Write-Host "✅ All steps complete!" -ForegroundColor Green
}

# ============================================================================
# SCENARIO 3: Batch - Process multiple issues
# ============================================================================
function Scenario3-BatchMultipleIssues {
    Write-Host "=== Scenario 3: Batch process multiple customers ===" -ForegroundColor Cyan
    
    if (-not $JiraApiToken) {
        $username = Read-Host "Jira username (email)"
        $token = Read-Host "Jira API token" -AsSecureString
    } else {
        $username = $JiraUsername
        $token = $JiraApiToken
    }
    
    $customers = @(
        @{ Name = "Contoso"; Domain = "contoso.com"; JiraKey = "CGGS-710" }
        @{ Name = "Fabrikam"; Domain = "fabrikam.com"; JiraKey = "CGGS-711" }
        @{ Name = "Northwind"; Domain = "northwind.com"; JiraKey = "CGGS-712" }
    )
    
    foreach ($customer in $customers) {
        Write-Host "Processing $($customer.Name)..." -ForegroundColor Green
        
        try {
            $result = Invoke-FinOpsOnboarding `
                -TenantId $TenantId `
                -ApplicationId $ApplicationId `
                -ClientSecret $ClientSecret `
                -CustomerName $customer.Name `
                -PrimaryDomain $customer.Domain `
                -JiraIssueKey $customer.JiraKey `
                -JiraUsername $username `
                -JiraApiToken $token `
                -PublishToJira `
                -PassThru
            
            Write-Host "  ✅ Completed" -ForegroundColor Green
        }
        catch {
            Write-Host "  ❌ Failed: $_" -ForegroundColor Red
        }
    }
    
    Write-Host "Batch processing complete!" -ForegroundColor Green
}

# ============================================================================
# SCENARIO 4: MCP Delegation - Use Atlassian Rovo MCP Server
# ============================================================================
function Scenario4-MCPDelegation {
    Write-Host "=== Scenario 4: Use Atlassian Rovo MCP Server ===" -ForegroundColor Cyan
    
    Write-Host "Step 1: Register MCP delegates..." -ForegroundColor Green
    Register-FinOpsAtlassianMcpProvider `
        -AddCommentScript { param($IssueKey, $Comment) 
            Write-Host "  [MCP] Adding comment to $IssueKey" -ForegroundColor DarkCyan
            # Your MCP implementation here
            # The actual MCP call would be made by your AI tool/IDE
        } `
        -GetTransitionsScript { param($IssueKey)
            Write-Host "  [MCP] Getting transitions for $IssueKey" -ForegroundColor DarkCyan
            # Return mocked transitions
            @(
                @{ id = "31"; name = "Done"; to = @{ name = "Done" } }
            )
        } `
        -TransitionIssueScript { param($IssueKey, $TargetStatus, $Comment)
            Write-Host "  [MCP] Transitioning $IssueKey to $TargetStatus" -ForegroundColor DarkCyan
        }
    
    Write-Host "Step 2: Run onboarding with MCP delegates..." -ForegroundColor Green
    $result = Invoke-FinOpsOnboarding `
        -TenantId $TenantId `
        -ApplicationId $ApplicationId `
        -ClientSecret $ClientSecret `
        -CustomerName $CustomerName `
        -PrimaryDomain $PrimaryDomain `
        -JiraIssueKey $JiraIssueKey `
        -PublishToJira `
        -UseJiraMcp `
        -PassThru
    
    Write-Host "✅ MCP-delegated onboarding complete!" -ForegroundColor Green
    Write-Host "  All Jira operations were handled by Atlassian Rovo MCP Server" -ForegroundColor DarkCyan
}

# ============================================================================
# SCENARIO 5: Manual Jira Updates - Without orchestrator integration
# ============================================================================
function Scenario5-ManualJiraUpdates {
    Write-Host "=== Scenario 5: Manual Jira operations (independent) ===" -ForegroundColor Cyan
    
    if (-not $JiraApiToken) {
        $username = Read-Host "Jira username (email)"
        $token = Read-Host "Jira API token" -AsSecureString
    } else {
        $username = $JiraUsername
        $token = $JiraApiToken
    }
    
    Write-Host "Example 1: Add a comment" -ForegroundColor Green
    Add-FinOpsJiraComment `
        -IssueKey $JiraIssueKey `
        -Comment "System check passed. Environment ready for deployment." `
        -Username $username `
        -ApiToken $token
    
    Write-Host "Example 2: Update custom field" -ForegroundColor Green
    Update-FinOpsJiraIssueField `
        -IssueKey $JiraIssueKey `
        -Fields @{
            labels = @('finops', 'automated', 'v1.7.0')
        } `
        -Username $username `
        -ApiToken $token
    
    Write-Host "Example 3: Transition to specific status" -ForegroundColor Green
    Update-FinOpsJiraIssueStatus `
        -IssueKey $JiraIssueKey `
        -TargetStatus "In Review" `
        -Comment "Ready for manual review" `
        -Username $username `
        -ApiToken $token
    
    Write-Host "✅ All manual Jira operations complete!" -ForegroundColor Green
}

# ============================================================================
# Main menu
# ============================================================================
function Show-Menu {
    Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  AzureFinOpsOnboarding v1.7.0 - Jira Feedback Examples      ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1. Simple Auto-Publish (REST API)" -ForegroundColor Green
    Write-Host "   └─ Run onboarding + auto-update Jira with single command"
    Write-Host ""
    Write-Host "2. Manual Control + Status Transition" -ForegroundColor Green
    Write-Host "   └─ Step-by-step onboarding with explicit Jira operations"
    Write-Host ""
    Write-Host "3. Batch Process Multiple Customers" -ForegroundColor Green
    Write-Host "   └─ Onboard multiple customers, update all Jira issues"
    Write-Host ""
    Write-Host "4. MCP Delegation (Atlassian Rovo)" -ForegroundColor Green
    Write-Host "   └─ Delegate Jira operations to MCP Server"
    Write-Host ""
    Write-Host "5. Manual Jira Operations (Independent)" -ForegroundColor Green
    Write-Host "   └─ Direct Jira API calls without orchestrator"
    Write-Host ""
    Write-Host "Q. Quit" -ForegroundColor Yellow
    Write-Host ""
}

# Main execution
if ($PSBoundParameters.Count -eq 0) {
    # Interactive mode
    while ($true) {
        Show-Menu
        $choice = Read-Host "Select scenario (1-5, Q to quit)"
        
        switch ($choice.ToUpper()) {
            "1" { Scenario1-SimpleAutoPublish; break }
            "2" { Scenario2-ManualControlWithTransition; break }
            "3" { Scenario3-BatchMultipleIssues; break }
            "4" { Scenario4-MCPDelegation; break }
            "5" { Scenario5-ManualJiraUpdates; break }
            "Q" { Write-Host "Goodbye!"; exit 0 }
            default { Write-Host "Invalid selection. Try again." -ForegroundColor Red }
        }
        
        Read-Host "`nPress Enter to continue"
    }
} else {
    # Scripted mode - run Scenario 1 by default
    Write-Host "Running in script mode with provided parameters..." -ForegroundColor Yellow
    Scenario1-SimpleAutoPublish
}
