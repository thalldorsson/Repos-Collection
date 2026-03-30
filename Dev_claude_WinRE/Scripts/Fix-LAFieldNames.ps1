# Updates KQL query files to use Log Analytics suffixed field names
# Log Analytics automatically adds type suffixes to custom log fields
param()

# Field mappings based on actual Log Analytics schema
$fieldMappings = @{
    'ComputerName(?!_)' = 'ComputerName_s'
    'Manufacturer(?!_)' = 'Manufacturer_s'
    'Model(?!_)' = 'Model_s'
    'SerialNumber(?!_)' = 'SerialNumber_s'
    'OSVersion(?!_)' = 'OSVersion_s'
    'OSBuild(?!_)' = 'OSBuild_s'
    'OSEdition(?!_)' = 'OSEdition_s'
    'Severity(?!_)' = 'Severity_s'
    'BitLockerStatus(?!_)' = 'BitLockerStatus_s'
    'WinRELocation(?!_)' = 'WinRELocation_s'
    'ScriptVersion(?!_)' = 'ScriptVersion_s'
    'Source(?!_)(?=\s|$|\|)' = 'Source_s'
    'RecommendedActionCode(?!_)' = 'RecommendedActionCode_s'
    'NinjaDeviceId(?!_)' = 'NinjaDeviceId_s'
    'TestMessage(?!_)' = 'TestMessage_s'
    'WinREEnabled(?!_)' = 'WinREEnabled_b'
    'KB5034441Vulnerable(?!_)' = 'KB5034441Vulnerable_b'
    'RemediationReady(?!_)' = 'RemediationReady_b'
    'PartitionAccessible(?!_)' = 'PartitionAccessible_b'
    'CanGrowTo500MB(?!_)' = 'CanGrowTo500MB_b'
    'TpmPresent(?!_)' = 'TpmPresent_b'
    'TpmReady(?!_)' = 'TpmReady_b'
    'IsVirtualMachine(?!_)' = 'IsVirtualMachine_b'
    'IsLastPartition(?!_)' = 'IsLastPartition_b'
    'PendingReboot(?!_)' = 'PendingReboot_b'
    'ConfidenceScore(?!_)' = 'ConfidenceScore_d'
    'ScriptExecutionTimeMS(?!_)' = 'ScriptExecutionTimeMS_d'
    'PartitionSizeMB(?!_)' = 'PartitionSizeMB_d'
    'PartitionFreeMB(?!_)' = 'PartitionFreeMBEstimated_d'
    'PartitionFreeTrendMBPerDay(?!_)' = 'PartitionFreeTrendMBPerDay_d'
    'DaysUntilSpaceCritical(?!_)' = 'DaysUntilSpaceCritical_d'
    'RecoveryPartitionCount(?!_)' = 'RecoveryPartitionCount_d'
    'TrendAnalysisPeriodDays(?!_)' = 'TrendAnalysisPeriodDays_d'
    'CriticalityPriority(?!_)' = 'CriticalityPriority_d'
    'RecommendedActionCodeBitmask(?!_)' = 'RecommendedActionCodeBitmask_d'
    'TestId(?!_)' = 'TestId_g'
    'WinREBCDId(?!_)' = 'BCDRecoveryGuid_g'
    'BCDRecoveryGuid(?!_)(?=\s|$|\||;)' = 'BCDRecoveryGuid_g'
    'Error(?!_)(?=\s|$|\||;)' = 'Error_s'
    'CriticalityReason(?!_)' = 'CriticalityReason_s'
    'TrendDirection(?!_)' = 'TrendDirection_s'
    'DeviceCriticality(?!_)' = 'DeviceCriticality_s'
    'PartitionOperationalStatus(?!_)' = 'PartitionOperationalStatus_s'
    'PartitionHealthStatus(?!_)' = 'PartitionHealthStatus_s'
    'DiskHealthStatus(?!_)' = 'DiskHealthStatus_s'
    'DiskOperationalStatus(?!_)' = 'DiskOperationalStatus_s'
}

$queryFiles = Get-ChildItem -Path ".\Queries" -Filter "*.kql" -File
$updatedCount = 0
$skippedCount = 0

foreach ($file in $queryFiles) {
    Write-Host "Processing: $($file.Name)..." -ForegroundColor Cyan
    
    $content = Get-Content $file.FullName -Raw
    $originalContent = $content
    $changesMode = 0
    
    foreach ($pattern in $fieldMappings.Keys) {
        $replacement = $fieldMappings[$pattern]
        $regex = [regex]::new("\b$pattern\b")
        $matchCount = $regex.Matches($content).Count
        
        if ($matchCount -gt 0) {
            $content = $regex.Replace($content, $replacement)
            $changesMode += $matchCount
        }
    }
    
    if ($content -ne $originalContent) {
        Set-Content -Path $file.FullName -Value $content -NoNewline
        Write-Host "  Updated with $changesMode field name changes" -ForegroundColor Green
        $updatedCount++
    } else {
        Write-Host "  No changes needed" -ForegroundColor Gray
        $skippedCount++
    }
}

Write-Host ""
Write-Host "Summary: Updated $updatedCount files, Skipped $skippedCount files" -ForegroundColor Cyan
