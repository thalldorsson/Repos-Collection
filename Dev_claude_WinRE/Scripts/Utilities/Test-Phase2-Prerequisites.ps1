<#
.SYNOPSIS
    Validates Phase 2 operational prerequisites before deployment.

.DESCRIPTION
    Test-Phase2-Prerequisites.ps1 performs pre-flight validation for WinRE Health Monitoring Phase 2 deployment:
    - 10 NinjaOne device custom fields exist
    - Azure Monitor workspace connectivity (*.ods.opinsights.azure.com:443)
    - Workspace credentials valid (HMAC-SHA256 signature generation test)
    - Detection script version check (should be 1.6.0-ninja or higher)
    - DCR not already deployed (optional - checks for existing WinRE-Health-DCR)

.PARAMETER WorkspaceId
    Azure Log Analytics Workspace ID (GUID format).

.PARAMETER WorkspaceKey
    Azure Log Analytics Workspace Key (Base64 SharedKey).

.PARAMETER CheckNinjaFields
    Validate 10 NinjaOne custom fields exist. Requires NinjaCli or Ninja-Property-Get cmdlet.
    Default: $false (skip NinjaOne checks for non-RMM environments)

.PARAMETER CheckDCR
    Check if WinRE-Health-DCR already deployed in Azure subscription. Requires Azure CLI.
    Default: $false (skip DCR check)

.PARAMETER SubscriptionId
    Azure Subscription ID (required if CheckDCR is $true).

.EXAMPLE
    .\Test-Phase2-Prerequisites.ps1 -WorkspaceId "12345678-1234-1234-1234-123456789abc" -WorkspaceKey "base64key=="
    Tests Azure connectivity and credential validation only (no NinjaOne/DCR checks).

.EXAMPLE
    .\Test-Phase2-Prerequisites.ps1 -WorkspaceId $env:LA_WORKSPACE_ID -WorkspaceKey $env:LA_WORKSPACE_KEY -CheckNinjaFields
    Tests Azure connectivity AND validates 10 NinjaOne custom fields exist.

.EXAMPLE
    .\Test-Phase2-Prerequisites.ps1 -WorkspaceId $id -WorkspaceKey $key -CheckDCR -SubscriptionId "sub-guid"
    Tests Azure connectivity AND checks if WinRE-Health-DCR is already deployed.

.NOTES
    Version: 1.6.0
    Author: WinRE Health Monitoring Team
    Created: 2026-01-09
    Phase: Phase 2 Operational Deployment
    Reference: Docs/PHASE2-DEPLOYMENT-PLAN.md
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, HelpMessage="Azure Log Analytics Workspace ID (GUID)")]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')]
    [string]$WorkspaceId,

    [Parameter(Mandatory=$true, HelpMessage="Azure Log Analytics Workspace Key (Base64)")]
    [ValidateNotNullOrEmpty()]
    [string]$WorkspaceKey,

    [Parameter(Mandatory=$false)]
    [switch]$CheckNinjaFields,

    [Parameter(Mandatory=$false)]
    [switch]$CheckDCR,

    [Parameter(Mandatory=$false)]
    [string]$SubscriptionId
)

#Requires -Version 5.1

# Initialize results tracking
$script:TestResults = @()
$script:FailureCount = 0

function Write-TestResult {
    param(
        [string]$TestName,
        [string]$Status,  # Pass, Fail, Skip, Warning
        [string]$Message,
        [string]$Remediation = ""
    )
    
    $result = [PSCustomObject]@{
        TestName    = $TestName
        Status      = $Status
        Message     = $Message
        Remediation = $Remediation
        Timestamp   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
    
    $script:TestResults += $result
    
    # Color-coded console output
    $color = switch ($Status) {
        "Pass"    { "Green" }
        "Fail"    { "Red" }
        "Warning" { "Yellow" }
        "Skip"    { "Gray" }
        default   { "White" }
    }
    
    Write-Host "[$Status] $TestName" -ForegroundColor $color
    Write-Host "  → $Message" -ForegroundColor $color
    if ($Remediation) {
        Write-Host "  ⚠ Remediation: $Remediation" -ForegroundColor Yellow
    }
    
    if ($Status -eq "Fail") {
        $script:FailureCount++
    }
}

# ============================================================================
# TEST 1: Detection Script Version Check
# ============================================================================
Write-Host "`n=== Test 1: Detection Script Version Check ===" -ForegroundColor Cyan

$detectorPath = Join-Path $PSScriptRoot "..\Detection\WinRE-Health-Detection-NinjaOne.ps1"
if (Test-Path $detectorPath) {
    $content = Get-Content $detectorPath -Raw
    if ($content -match 'Version:\s+([\d\.]+)-?(\w*)') {
        $version = $matches[1]
        $variant = $matches[2]
        $fullVersion = if ($variant) { "$version-$variant" } else { $version }
        
        if ($version -ge "1.6.0") {
            Write-TestResult -TestName "Detection Script Version" -Status "Pass" `
                -Message "Version $fullVersion detected (Phase 2 compatible)"
        } else {
            Write-TestResult -TestName "Detection Script Version" -Status "Fail" `
                -Message "Version $fullVersion is below 1.6.0" `
                -Remediation "Update WinRE-Health-Detection-NinjaOne.ps1 to 1.6.0-ninja or higher"
        }
    } else {
        Write-TestResult -TestName "Detection Script Version" -Status "Warning" `
            -Message "Could not parse version from script header" `
            -Remediation "Verify script file integrity"
    }
} else {
    Write-TestResult -TestName "Detection Script Version" -Status "Fail" `
        -Message "Detection script not found at $detectorPath" `
        -Remediation "Verify repository structure and file paths"
}

# ============================================================================
# TEST 2: Azure Log Analytics Workspace Connectivity
# ============================================================================
Write-Host "`n=== Test 2: Azure Log Analytics Connectivity ===" -ForegroundColor Cyan

$workspaceEndpoint = "$WorkspaceId.ods.opinsights.azure.com"
$testConnection = Test-NetConnection -ComputerName $workspaceEndpoint -Port 443 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue

if ($testConnection.TcpTestSucceeded) {
    Write-TestResult -TestName "Workspace Endpoint Connectivity" -Status "Pass" `
        -Message "Successfully connected to $workspaceEndpoint:443"
} else {
    Write-TestResult -TestName "Workspace Endpoint Connectivity" -Status "Fail" `
        -Message "Cannot reach $workspaceEndpoint:443" `
        -Remediation "Verify firewall rules allow outbound HTTPS to *.ods.opinsights.azure.com, check proxy settings"
}

# ============================================================================
# TEST 3: Workspace Credentials Validation (HMAC-SHA256 Test)
# ============================================================================
Write-Host "`n=== Test 3: Workspace Credentials Validation ===" -ForegroundColor Cyan

try {
    # Test HMAC-SHA256 signature generation (same logic as Send-ToLogAnalytics)
    $testPayload = '{"test":"phase2-prerequisites"}'
    $contentLength = [System.Text.Encoding]::UTF8.GetByteCount($testPayload)
    $rfc1123date = [DateTime]::UtcNow.ToString("r")
    $stringToHash = "POST`n$contentLength`napplication/json`nx-ms-date:$rfc1123date`n/api/logs"
    
    $bytesToHash = [System.Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($WorkspaceKey)
    
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = $keyBytes
    $signature = [Convert]::ToBase64String($hmac.ComputeHash($bytesToHash))
    
    Write-TestResult -TestName "Workspace Key HMAC Generation" -Status "Pass" `
        -Message "Successfully generated HMAC-SHA256 signature (key format valid)"
} catch {
    Write-TestResult -TestName "Workspace Key HMAC Generation" -Status "Fail" `
        -Message "Failed to generate HMAC signature: $($_.Exception.Message)" `
        -Remediation "Verify WorkspaceKey is valid Base64 SharedKey from Azure portal"
}

# ============================================================================
# TEST 4: TLS 1.2 Enforcement
# ============================================================================
Write-Host "`n=== Test 4: TLS 1.2 Enforcement ===" -ForegroundColor Cyan

$currentTLS = [Net.ServicePointManager]::SecurityProtocol
if ($currentTLS -match "Tls12") {
    Write-TestResult -TestName "TLS 1.2 Enabled" -Status "Pass" `
        -Message "TLS 1.2 is enabled ($currentTLS)"
} else {
    Write-TestResult -TestName "TLS 1.2 Enabled" -Status "Warning" `
        -Message "TLS 1.2 not explicitly enabled ($currentTLS)" `
        -Remediation "Detection script will enforce TLS 1.2, but verify system support"
}

# ============================================================================
# TEST 5: NinjaOne Custom Fields (Optional)
# ============================================================================
if ($CheckNinjaFields) {
    Write-Host "`n=== Test 5: NinjaOne Custom Fields Validation ===" -ForegroundColor Cyan
    
    $requiredFields = @(
        "winreDeviceLocation",
        "winreManufactureDate",
        "winreDeviceAge",
        "winreDepartmentName",
        "winreDeviceOrgUnit",
        "winreFirstSeenDate",
        "winreVirtualMachineType",
        "winrePhysicalMemoryGB",
        "winreStorageCapacityGB",
        "winreProcessorCores"
    )
    
    # Check if Ninja-Property-Get is available
    $ninjaCmd = Get-Command Ninja-Property-Get -ErrorAction SilentlyContinue
    if (-not $ninjaCmd) {
        Write-TestResult -TestName "NinjaOne Custom Fields" -Status "Skip" `
            -Message "Ninja-Property-Get cmdlet not found (not running in NinjaOne RMM context)" `
            -Remediation "Run this test on a NinjaOne-managed device OR manually verify fields exist in NinjaOne portal"
    } else {
        $missingFields = @()
        foreach ($field in $requiredFields) {
            try {
                $value = & Ninja-Property-Get $field 2>$null
                # Field exists if cmdlet succeeds (even if value is empty)
            } catch {
                $missingFields += $field
            }
        }
        
        if ($missingFields.Count -eq 0) {
            Write-TestResult -TestName "NinjaOne Custom Fields" -Status "Pass" `
                -Message "All 10 Phase 2 custom fields exist"
        } else {
            Write-TestResult -TestName "NinjaOne Custom Fields" -Status "Fail" `
                -Message "$($missingFields.Count) missing fields: $($missingFields -join ', ')" `
                -Remediation "Create missing Device Custom Fields in NinjaOne Administration > Custom Fields (see Docs/README-NinjaOne-Setup.md)"
        }
    }
} else {
    Write-Host "`n=== Test 5: NinjaOne Custom Fields (SKIPPED) ===" -ForegroundColor Gray
    Write-Host "  Use -CheckNinjaFields to enable this test" -ForegroundColor Gray
}

# ============================================================================
# TEST 6: DCR Deployment Check (Optional)
# ============================================================================
if ($CheckDCR) {
    Write-Host "`n=== Test 6: Data Collection Rule Deployment Check ===" -ForegroundColor Cyan
    
    # Check if Azure CLI is available
    $azCmd = Get-Command az -ErrorAction SilentlyContinue
    if (-not $azCmd) {
        Write-TestResult -TestName "DCR Deployment Status" -Status "Skip" `
            -Message "Azure CLI (az) not found" `
            -Remediation "Install Azure CLI from https://aka.ms/InstallAzureCLIDocs"
    } else {
        if (-not $SubscriptionId) {
            Write-TestResult -TestName "DCR Deployment Status" -Status "Skip" `
                -Message "SubscriptionId parameter not provided" `
                -Remediation "Provide -SubscriptionId parameter to check DCR deployment"
        } else {
            try {
                # Query for existing DCR
                $dcrQuery = "az monitor data-collection rule list --subscription '$SubscriptionId' --query `"[?name=='WinRE-Health-DCR'].{Name:name, ResourceGroup:resourceGroup}`" --output json"
                $dcrResult = Invoke-Expression $dcrQuery | ConvertFrom-Json
                
                if ($dcrResult.Count -gt 0) {
                    Write-TestResult -TestName "DCR Deployment Status" -Status "Warning" `
                        -Message "WinRE-Health-DCR already exists in resource group '$($dcrResult[0].ResourceGroup)'" `
                        -Remediation "Use -WhatIf to test DCR deployment without overwriting existing rule"
                } else {
                    Write-TestResult -TestName "DCR Deployment Status" -Status "Pass" `
                        -Message "No existing WinRE-Health-DCR found (safe to deploy)"
                }
            } catch {
                Write-TestResult -TestName "DCR Deployment Status" -Status "Warning" `
                    -Message "Failed to query Azure: $($_.Exception.Message)" `
                    -Remediation "Verify Azure CLI authentication: az login"
            }
        }
    }
} else {
    Write-Host "`n=== Test 6: DCR Deployment Check (SKIPPED) ===" -ForegroundColor Gray
    Write-Host "  Use -CheckDCR -SubscriptionId <guid> to enable this test" -ForegroundColor Gray
}

# ============================================================================
# SUMMARY REPORT
# ============================================================================
Write-Host "`n======================================" -ForegroundColor Cyan
Write-Host "Phase 2 Prerequisites Validation Summary" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan

$passCount = ($script:TestResults | Where-Object { $_.Status -eq "Pass" }).Count
$failCount = ($script:TestResults | Where-Object { $_.Status -eq "Fail" }).Count
$warnCount = ($script:TestResults | Where-Object { $_.Status -eq "Warning" }).Count
$skipCount = ($script:TestResults | Where-Object { $_.Status -eq "Skip" }).Count
$totalTests = $script:TestResults.Count

Write-Host "`nTest Results:" -ForegroundColor White
Write-Host "  ✓ Pass:    $passCount" -ForegroundColor Green
Write-Host "  ✗ Fail:    $failCount" -ForegroundColor Red
Write-Host "  ⚠ Warning: $warnCount" -ForegroundColor Yellow
Write-Host "  ○ Skip:    $skipCount" -ForegroundColor Gray
Write-Host "  Total:     $totalTests`n" -ForegroundColor White

# Output detailed results to JSON for automation
$reportPath = Join-Path $env:TEMP "Phase2-Prerequisites-Report-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$script:TestResults | ConvertTo-Json -Depth 3 | Out-File $reportPath -Encoding UTF8
Write-Host "Detailed report saved: $reportPath" -ForegroundColor Cyan

# Exit code based on failures
if ($failCount -gt 0) {
    Write-Host "`n❌ VALIDATION FAILED: $failCount critical issue(s) detected" -ForegroundColor Red
    Write-Host "Review remediation guidance above before proceeding with Phase 2 deployment.`n" -ForegroundColor Yellow
    exit 1
} elseif ($warnCount -gt 0) {
    Write-Host "`n⚠ VALIDATION PASSED WITH WARNINGS: $warnCount non-critical issue(s)" -ForegroundColor Yellow
    Write-Host "Phase 2 deployment can proceed, but review warnings above.`n" -ForegroundColor Yellow
    exit 0
} else {
    Write-Host "`n✅ VALIDATION PASSED: All prerequisites met for Phase 2 deployment" -ForegroundColor Green
    Write-Host "Proceed with deployment: See Docs/PHASE2-DEPLOYMENT-PLAN.md`n" -ForegroundColor Cyan
    exit 0
}
