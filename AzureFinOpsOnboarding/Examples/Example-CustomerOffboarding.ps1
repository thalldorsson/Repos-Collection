# Example: Customer Offboarding Workflow
# This script demonstrates how to use Undo-FinOpsOnboarding to remove a customer from FinOps
# Updated for v1.8.1: Manual database deletion now required

<#
.SYNOPSIS
Example script for offboarding a customer from Azure FinOps.

.DESCRIPTION
Demonstrates the complete offboarding workflow (v1.8.1):
1. Run Undo-FinOpsOnboarding to clean webhooks, Power BI access, Jira comments
2. Manually delete SQL database (required as of v1.8.1)
3. Manually delete storage accounts and other resources
4. Capture and log the results

.NOTES
Prerequisites:
- AzureFinOpsOnboarding module installed and imported (v1.8.1+)
- Power BI admin or workspace contributor rights
- SQL database DELETE permissions
- Service principal configured with appropriate permissions
- Azure subscription owner/contributor role

BREAKING CHANGE (v1.8.1):
- Undo-FinOpsOnboarding NO LONGER deletes databases
- Manual database deletion is now required (see Example 2 below)
- This is intentional to prevent accidental data loss
#>

# Import the AzureFinOpsOnboarding module
Import-Module AzureFinOpsOnboarding -Force

#region Configuration
# Power BI settings
$workspaceId = "12345678-1234-1234-1234-123456789012"  # Replace with your workspace GUID
$reportId = "87654321-4321-4321-4321-210987654321"     # Replace with your report GUID

# Database settings
$sqlConnectionString = "Server=myserver.database.windows.net;Database=FinOpsDB;User Id=finops_user;Password=<REDACTED>;"
$tableName = "Customers"
$keyColumn = "CustomerId"

# Customer to offboard
$customerId = "CUST001"
$customerGroupId = "abcdefab-abcd-abcd-abcd-abcdefabcdef"  # Entra ID group ObjectId

# Authentication settings (optional: use service principal for automation)
$useServicePrincipal = $false
$tenantId = "99999999-9999-9999-9999-999999999999"
$clientId = "app-client-id"
$clientSecret = $env:FINOPS_CLIENT_SECRET  # Store secrets securely!
#endregion

#region Example 1: Interactive Offboarding with Confirmation
Write-Host "`n=== Example 1: Interactive Offboarding ===" -ForegroundColor Cyan

# Perform offboarding with interactive Power BI login
# The function will prompt for confirmation before making changes
try {
    $result = Invoke-FinOpsOffboarding `
        -WorkspaceId $workspaceId `
        -ReportId $reportId `
        -AccessGroupObjectId $customerGroupId `
        -SqlConnectionString $sqlConnectionString `
        -KeyValue $customerId `
        -TableName $tableName `
        -KeyColumn $keyColumn `
        -PassThru `
        -Confirm

    # Check results
    if ($result.PowerBIAccessRevoked -and $result.DatabaseUpdated) {
        Write-Host "✅ Customer $customerId offboarded successfully!" -ForegroundColor Green
        Write-Host "   - Power BI access: Revoked" -ForegroundColor Green
        Write-Host "   - Database updated: $($result.RowsAffected) rows" -ForegroundColor Green
    }
    else {
        Write-Warning "⚠️ Offboarding incomplete for customer $customerId"
        if ($result.Errors.Count -gt 0) {
            Write-Host "Errors:" -ForegroundColor Red
            $result.Errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
        }
    }
}
catch {
    Write-Error "Offboarding failed: $_"
}
#endregion

#region Example 2: Service Principal Authentication (Unattended)
Write-Host "`n=== Example 2: Service Principal Authentication ===" -ForegroundColor Cyan

if ($useServicePrincipal) {
    try {
        $offboardParams = @{
            WorkspaceId         = $workspaceId
            ReportId            = $reportId
            AccessGroupObjectId = $customerGroupId
            SqlConnectionString = $sqlConnectionString
            KeyValue            = $customerId
            TableName           = $tableName
            KeyColumn           = $keyColumn
            UseServicePrincipal = $true
            TenantId            = $tenantId
            ClientId            = $clientId
            ClientSecret        = $clientSecret
            PassThru            = $true
        }

        $result = Invoke-FinOpsOffboarding @offboardParams

        # Log to file for audit trail
        $logEntry = [PSCustomObject]@{
            Timestamp          = $result.Timestamp.ToString("yyyy-MM-dd HH:mm:ss")
            CustomerId         = $result.KeyValue
            PowerBIRevoked     = $result.PowerBIAccessRevoked
            DatabaseUpdated    = $result.DatabaseUpdated
            RowsAffected       = $result.RowsAffected
            Success            = ($result.Errors.Count -eq 0)
            Errors             = $result.Errors -join "; "
            PerformedBy        = $env:USERNAME
            Machine            = $env:COMPUTERNAME
        }

        $logEntry | Export-Csv "offboarding-audit.csv" -Append -NoTypeInformation
        Write-Host "✅ Offboarding logged to audit file" -ForegroundColor Green
    }
    catch {
        Write-Error "Service principal offboarding failed: $_"
    }
}
else {
    Write-Host "Skipped (set `$useServicePrincipal = `$true to enable)" -ForegroundColor Yellow
}
#endregion

#region Example 3: Testing with -WhatIf
Write-Host "`n=== Example 3: Testing with -WhatIf ===" -ForegroundColor Cyan

# Test offboarding without making actual changes
Write-Host "Running offboarding in test mode (-WhatIf)..." -ForegroundColor Yellow

Invoke-FinOpsOffboarding `
    -WorkspaceId $workspaceId `
    -ReportId $reportId `
    -AccessGroupObjectId $customerGroupId `
    -SqlConnectionString $sqlConnectionString `
    -KeyValue $customerId `
    -WhatIf `
    -Verbose

Write-Host "✅ Test complete. No changes were made." -ForegroundColor Green
#endregion

#region Example 4: Bulk Offboarding from CSV
Write-Host "`n=== Example 4: Bulk Offboarding ===" -ForegroundColor Cyan

# Sample CSV format:
# CustomerId,GroupId
# CUST001,guid1
# CUST002,guid2
# CUST003,guid3

$csvPath = "customers-to-offboard.csv"

if (Test-Path $csvPath) {
    $customers = Import-Csv $csvPath
    $successCount = 0
    $failCount = 0

    foreach ($customer in $customers) {
        Write-Host "Offboarding customer: $($customer.CustomerId)..." -ForegroundColor Cyan

        try {
            $result = Invoke-FinOpsOffboarding `
                -WorkspaceId $workspaceId `
                -ReportId $reportId `
                -AccessGroupObjectId $customer.GroupId `
                -SqlConnectionString $sqlConnectionString `
                -KeyValue $customer.CustomerId `
                -PassThru `
                -Verbose:$false

            if ($result.PowerBIAccessRevoked -and $result.DatabaseUpdated) {
                $successCount++
                Write-Host "  ✅ Success" -ForegroundColor Green
            }
            else {
                $failCount++
                Write-Host "  ❌ Failed: $($result.Errors -join ', ')" -ForegroundColor Red
            }

            # Rate limiting to avoid throttling
            Start-Sleep -Seconds 2
        }
        catch {
            $failCount++
            Write-Host "  ❌ Exception: $_" -ForegroundColor Red
        }
    }

    Write-Host "`nBulk offboarding complete:" -ForegroundColor Cyan
    Write-Host "  Success: $successCount" -ForegroundColor Green
    Write-Host "  Failed: $failCount" -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "Green" })
}
else {
    Write-Host "CSV file not found: $csvPath" -ForegroundColor Yellow
    Write-Host "Create a CSV with columns: CustomerId, GroupId" -ForegroundColor Yellow
}
#endregion

#region Example 5: Error Handling and Rollback Planning
Write-Host "`n=== Example 5: Error Handling Best Practices ===" -ForegroundColor Cyan

# Demonstrate comprehensive error handling
function Invoke-SafeOffboarding {
    param(
        [Parameter(Mandatory)]
        [string]$CustomerId,
        [Parameter(Mandatory)]
        [string]$GroupId
    )

    $rollbackNeeded = $false
    $offboardResult = $null

    try {
        # Attempt offboarding
        $offboardResult = Invoke-FinOpsOffboarding `
            -WorkspaceId $workspaceId `
            -ReportId $reportId `
            -AccessGroupObjectId $GroupId `
            -SqlConnectionString $sqlConnectionString `
            -KeyValue $CustomerId `
            -PassThru `
            -ErrorAction Stop

        # Check if partial success requires rollback
        if ($offboardResult.PowerBIAccessRevoked -and -not $offboardResult.DatabaseUpdated) {
            Write-Warning "⚠️ Partial offboarding: Power BI revoked but database not updated"
            $rollbackNeeded = $true
        }
        elseif (-not $offboardResult.PowerBIAccessRevoked -and $offboardResult.DatabaseUpdated) {
            Write-Warning "⚠️ Partial offboarding: Database updated but Power BI access not revoked"
            $rollbackNeeded = $true
        }

        # If rollback needed, attempt to restore previous state
        if ($rollbackNeeded) {
            Write-Host "Attempting to rollback changes..." -ForegroundColor Yellow
            
            # Example: Re-grant Power BI access if database wasn't updated
            if ($offboardResult.PowerBIAccessRevoked -and -not $offboardResult.DatabaseUpdated) {
                # Grant-FinOpsPowerBIReportAccess -ReportId $reportId -EntraGroupId $GroupId
                Write-Host "Manual intervention required: Re-grant Power BI access" -ForegroundColor Red
            }
            
            # Example: Set IsActive back to 1 if Power BI wasn't revoked
            if (-not $offboardResult.PowerBIAccessRevoked -and $offboardResult.DatabaseUpdated) {
                Write-Host "Manual intervention required: Set IsActive = 1 in database" -ForegroundColor Red
            }
        }
        else {
            Write-Host "✅ Offboarding completed successfully with no errors" -ForegroundColor Green
        }
    }
    catch {
        Write-Error "Critical error during offboarding: $_"
        Write-Host "Manual review required for customer: $CustomerId" -ForegroundColor Red
    }

    return $offboardResult
}

# Test safe offboarding wrapper
# $safeResult = Invoke-SafeOffboarding -CustomerId "CUST004" -GroupId "test-group-guid"
#endregion

Write-Host "`n=== Examples Complete ===" -ForegroundColor Green
Write-Host "See docs\Invoke-FinOpsOffboarding.md for more information" -ForegroundColor Cyan

