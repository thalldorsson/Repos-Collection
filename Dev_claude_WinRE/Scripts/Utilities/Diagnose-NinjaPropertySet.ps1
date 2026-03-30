#Requires -Version 5.1

<#
.SYNOPSIS
  Diagnose Ninja-Property-Set functionality and field accessibility.

.DESCRIPTION
  Tests whether Ninja-Property-Set cmdlet can actually write to Device Custom Fields.
  Identifies if the problem is cmdlet availability, field names, permissions, or device context.

.NOTES
  Run via NinjaOne Automation Policy for accurate device context.
  Attempts writes to test fields to confirm functionality.
#>

Write-Host "=== Ninja-Property-Set Diagnostic ===" -ForegroundColor Cyan
Write-Host "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host ""

# Detect environment
$ninjaDeviceId = $env:COMPUTERNAME

Write-Host "Environment Detection:" -ForegroundColor Yellow
Write-Host "  ComputerName: $(if($ninjaDeviceId) { $ninjaDeviceId } else { '<NOT SET>' })"
Write-Host ""

# Test 1: Cmdlet availability
Write-Host "Test 1: Ninja-Property-Set Cmdlet Availability" -ForegroundColor Yellow
$cmd = Get-Command Ninja-Property-Set -ErrorAction SilentlyContinue
if ($cmd) {
    Write-Host "  ✅ Ninja-Property-Set cmdlet FOUND" -ForegroundColor Green
    Write-Host "     Source: $($cmd.Source)"
} else {
    Write-Host "  ❌ Ninja-Property-Set cmdlet NOT FOUND" -ForegroundColor Red
    Write-Host "     This cmdlet must be available for field writes to work."
    Write-Host "     Possible fix: Ensure NinjaOne agent v5.x+ is installed."
    exit 1
}
Write-Host ""

# Test 2: Ninja-Property-Get availability
Write-Host "Test 2: Ninja-Property-Get Cmdlet Availability" -ForegroundColor Yellow
$getCmd = Get-Command Ninja-Property-Get -ErrorAction SilentlyContinue
if ($getCmd) {
    Write-Host "  ✅ Ninja-Property-Get cmdlet FOUND" -ForegroundColor Green
} else {
    Write-Host "  ⚠️  Ninja-Property-Get cmdlet NOT FOUND (optional)" -ForegroundColor Yellow
}
Write-Host ""

# Test 3: Write a simple test value
Write-Host "Test 3: Write Test Value" -ForegroundColor Yellow
$testFieldName = "winreScriptVersion"
$testValue = "Diagnostic_$(Get-Date -Format 'yyyyMMdd_HHmmss')"

try {
    Write-Host "  Attempting: Ninja-Property-Set $testFieldName '$testValue'" -ForegroundColor Cyan
    Ninja-Property-Set $testFieldName $testValue -ErrorAction Stop
    Write-Host "  ✅ Write command executed (no exception)" -ForegroundColor Green
} catch {
    Write-Host "  ❌ Write command threw exception:" -ForegroundColor Red
    Write-Host "     $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# Test 4: Verify write by reading back
if ($getCmd) {
    Write-Host "Test 4: Verify Write (Read Back)" -ForegroundColor Yellow
    try {
        Write-Host "  Attempting: Ninja-Property-Get $testFieldName" -ForegroundColor Cyan
        $readValue = Ninja-Property-Get $testFieldName -ErrorAction Stop
        
        if ($readValue -eq $testValue) {
            Write-Host "  ✅ Value verified! Field contains: '$readValue'" -ForegroundColor Green
            Write-Host "     Write AND read successful - Ninja integration working!" -ForegroundColor Green
        } else {
            Write-Host "  ⚠️  Value mismatch:" -ForegroundColor Yellow
            Write-Host "     Expected: '$testValue'" -ForegroundColor Yellow
            Write-Host "     Actual:   '$readValue'" -ForegroundColor Yellow
            Write-Host "     This indicates stale or unexpected data in the field." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  ❌ Read command threw exception:" -ForegroundColor Red
        Write-Host "     $($_.Exception.Message)" -ForegroundColor Red
    }
} else {
    Write-Host "Test 4: Verify Write (Read Back)" -ForegroundColor Yellow
    Write-Host "  ⏭️  Skipped (Ninja-Property-Get not available)" -ForegroundColor Gray
}
Write-Host ""

# Test 5: List field names we're trying to write
Write-Host "Test 5: Known Device Custom Field Names" -ForegroundColor Yellow
$expectedFields = @(
    'winreEnabled','winreSeverity','winreKB5034441Vulnerable','winreConfidenceScore',
    'winreRecommendation','winrePartitionSizeMB','winrePartitionFreeMB','winreLastCheck',
    'winreBitLockerStatus','winreWindows11Ready','winreSecureBoot','winreFirmwareType'
)
Write-Host "  Expected minimum fields (12):" -ForegroundColor Cyan
$expectedFields | ForEach-Object { Write-Host "    - $_" }
Write-Host ""

# Test 6: Attempt to write all core fields
Write-Host "Test 6: Attempt Core Field Writes" -ForegroundColor Yellow
$successCount = 0
$failureCount = 0

$testData = @{
    'winreEnabled' = 'true'
    # Use values compatible with common Ninja field types to avoid format rejections
    'winreSeverity' = 'false'                      # boolean field in many setups
    'winreKB5034441Vulnerable' = 'false'
    'winreConfidenceScore' = '95'
    'winreRecommendation' = 'Diagnostic test'
    'winreLastCheck' = (Get-Date).ToString('s')     # ISO: yyyy-MM-ddTHH:mm:ss
    'winreFirmwareType' = '3e8bb00a-753c-4e77-afc6-104537116ea7' # UEFI GUID
}

foreach ($field in $testData.Keys) {
    try {
        Write-Host "  Writing: $field" -ForegroundColor Gray -NoNewline
        Ninja-Property-Set $field $testData[$field] -ErrorAction Stop
        Write-Host " ✅" -ForegroundColor Green
        $successCount++
    } catch {
        Write-Host " ❌ ($($_.Exception.Message))" -ForegroundColor Red
        $failureCount++
    }
}

Write-Host ""
Write-Host "  Results: $successCount succeeded, $failureCount failed" -ForegroundColor Cyan
Write-Host ""

# Summary
Write-Host "=== Summary ===" -ForegroundColor Cyan

if (-not $cmd) {
    Write-Host "❌ BLOCKED: Ninja-Property-Set cmdlet not available" -ForegroundColor Red
    Write-Host "   ACTION: Install/update NinjaOne agent to v5.x+" -ForegroundColor Yellow
    exit 1
}

if ($successCount -gt 0) {
    Write-Host "✅ SUCCESS: Ninja-Property-Set is working" -ForegroundColor Green
    if ($successCount -eq $testData.Count) {
        Write-Host "   All test fields written successfully." -ForegroundColor Green
        Write-Host "   → Check NinjaOne device to confirm values appear." -ForegroundColor Green
        Write-Host "   → If values still don't appear: field names may not match exactly." -ForegroundColor Yellow
    } else {
        Write-Host "   $failureCount field(s) failed. Check field names in NinjaOne." -ForegroundColor Yellow
    }
} else {
    Write-Host "❌ FAILURE: Ninja-Property-Set calls failed" -ForegroundColor Red
    Write-Host "   Possible causes:" -ForegroundColor Yellow
    Write-Host "   1. Field names don't exist in NinjaOne" -ForegroundColor Yellow
    Write-Host "   2. Field type mismatch (e.g., text vs checkbox)" -ForegroundColor Yellow
    Write-Host "   3. Insufficient permissions" -ForegroundColor Yellow
    Write-Host "   4. Device not bound to NinjaOne context" -ForegroundColor Yellow
    Write-Host "" -ForegroundColor Yellow
    Write-Host "   ACTION: Run 'Get-Command Ninja-Property-*' to see what's available" -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "Diagnostic complete." -ForegroundColor Cyan
exit 0
