# Create NinjaOne Custom Fields for Phase 3
# This script generates the field definitions for manual creation in NinjaOne UI
# Author: WinRE Health Toolkit Team
# Date: 2026-01-10
# Phase: 3 - System Health Assessment

<#
.SYNOPSIS
    Generates NinjaOne custom field definitions for Phase 3 system health assessment.

.DESCRIPTION
    This script outputs the 15 Phase 3 custom field definitions that must be created
    in the NinjaOne Admin Portal before deploying the Phase 3 detection script.
    
    Fields are organized by category:
    - Hardware Health (6 fields)
    - OS Compliance (5 fields)
    - Network Readiness (4 fields)
    - Migration Readiness Summary (3 fields, optional but recommended)

.EXAMPLE
    .\Create-NinjaOne-Phase3-Fields.ps1
    
    Displays all Phase 3 field definitions to console.

.EXAMPLE
    .\Create-NinjaOne-Phase3-Fields.ps1 | Out-File -FilePath .\Phase3-Fields.txt
    
    Exports field definitions to a text file for reference.

.NOTES
    NinjaOne does not support API-based custom field creation. Fields must be
    created manually in Administration > Device Custom Fields.
    
    After creating fields, deploy the updated detection script (v1.7.0+) to
    populate the fields with data.
#>

param(
    [switch]$ExportCSV,
    [string]$OutputPath = ".\NinjaOne-Phase3-Fields.csv"
)

# Define Phase 3 custom fields
$phase3Fields = @(
    # Hardware Health Fields (6)
    @{
        Category = "Hardware Health"
        Name = "winreSystemDriveFreeMB"
        Type = "Number (Double)"
        Description = "C: drive free space in MB - Critical for device reset (Phase 3)"
        Critical = "Yes"
        Thresholds = "< 10 GB = CRITICAL, < 20 GB = WARNING"
    },
    @{
        Category = "Hardware Health"
        Name = "winreSystemDriveFreePercent"
        Type = "Number (Double)"
        Description = "C: drive free space percentage (Phase 3)"
        Critical = "Yes"
        Thresholds = "Calculated from drive size"
    },
    @{
        Category = "Hardware Health"
        Name = "winreTotalPhysicalMemoryMB"
        Type = "Number (Double)"
        Description = "Total physical RAM in MB (Phase 3)"
        Critical = "Yes"
        Thresholds = "< 2 GB = CRITICAL, < 4 GB = WARNING"
    },
    @{
        Category = "Hardware Health"
        Name = "winreAvailablePhysicalMemoryMB"
        Type = "Number (Double)"
        Description = "Available physical RAM in MB (Phase 3)"
        Critical = "No"
        Thresholds = "Informational only"
    },
    @{
        Category = "Hardware Health"
        Name = "winreBatteryHealthStatus"
        Type = "Text"
        Description = "Battery health status for laptops (Phase 3)"
        Critical = "Yes"
        Thresholds = "Laptop-specific, values: Fully Charged, Charging, Low, Critical, N/A"
    },
    @{
        Category = "Hardware Health"
        Name = "winreBatteryEstimatedChargeRemaining"
        Type = "Number (Double)"
        Description = "Battery charge percentage 0-100 (Phase 3)"
        Critical = "No"
        Thresholds = "< 30% = WARNING (if not charging)"
    },
    
    # OS Compliance Fields (5)
    @{
        Category = "OS Compliance"
        Name = "winreWindowsVersion"
        Type = "Text"
        Description = "Windows OS version (e.g., 10.0.19045) - Phase 3"
        Critical = "Yes"
        Thresholds = "Version tracking"
    },
    @{
        Category = "OS Compliance"
        Name = "winreWindowsBuildNumber"
        Type = "Text"
        Description = "Windows build number (e.g., 19045) - Phase 3"
        Critical = "Yes"
        Thresholds = "< 19041 = CRITICAL, < 19043 = WARNING"
    },
    @{
        Category = "OS Compliance"
        Name = "winrePendingRebootStatus"
        Type = "Text"
        Description = "Pending reboot status: Yes/No/Unknown - CRITICAL (Phase 3)"
        Critical = "CRITICAL"
        Thresholds = "'Yes' blocks device reset operation"
    },
    @{
        Category = "OS Compliance"
        Name = "winrePendingRebootDays"
        Type = "Number (Double)"
        Description = "Days since reboot required - CRITICAL (Phase 3)"
        Critical = "CRITICAL"
        Thresholds = "> 7 days = CRITICAL, > 3 days = WARNING"
    },
    @{
        Category = "OS Compliance"
        Name = "winreSystemFileIntegrityStatus"
        Type = "Text"
        Description = "System file integrity via DISM (Phase 3)"
        Critical = "Yes"
        Thresholds = "Values: Healthy, Issues Detected, Unknown"
    },
    
    # Network Readiness Fields (4)
    @{
        Category = "Network Readiness"
        Name = "winreInternetConnectivity"
        Type = "Checkbox (Boolean)"
        Description = "Internet connectivity status - CRITICAL (Phase 3)"
        Critical = "Yes"
        Thresholds = "False = CRITICAL (no internet)"
    },
    @{
        Category = "Network Readiness"
        Name = "winreDNSResolutionStatus"
        Type = "Text"
        Description = "DNS resolution functionality - CRITICAL (Phase 3)"
        Critical = "Yes"
        Thresholds = "'Failed' = CRITICAL"
    },
    @{
        Category = "Network Readiness"
        Name = "winreMicrosoftEndpointAccess"
        Type = "Checkbox (Boolean)"
        Description = "Microsoft enrollment endpoint access - CRITICAL (Phase 3)"
        Critical = "CRITICAL"
        Thresholds = "False = CRITICAL (blocks Intune enrollment)"
    },
    @{
        Category = "Network Readiness"
        Name = "winreCertificateHealthStatus"
        Type = "Text"
        Description = "Certificate health status (Phase 3)"
        Critical = "Yes"
        Thresholds = "'Expired' = CRITICAL, 'Invalid' = WARNING"
    },
    
    # Migration Readiness Summary Fields (3, recommended)
    @{
        Category = "Migration Readiness"
        Name = "winreMigrationReadinessScore"
        Type = "Number (Double)"
        Description = "Overall migration readiness score 0-100 (Phase 3)"
        Critical = "Yes"
        Thresholds = "< 60 = No-Go, 60-79 = Caution, >= 80 = Go"
    },
    @{
        Category = "Migration Readiness"
        Name = "winreMigrationReadinessStatus"
        Type = "Text"
        Description = "Migration readiness status: Go/Caution/No-Go (Phase 3)"
        Critical = "Yes"
        Thresholds = "Based on readiness score"
    },
    @{
        Category = "Migration Readiness"
        Name = "winreMigrationReadinessIssues"
        Type = "Text (WYSIWYG)"
        Description = "Semicolon-separated list of blocking issues (Phase 3)"
        Critical = "Yes"
        Thresholds = "Aggregated from all health dimensions"
    }
)

# Display formatted output
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "NinjaOne Phase 3 Custom Fields" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "Total Fields to Create: $($phase3Fields.Count)" -ForegroundColor Yellow
Write-Host "These fields must be created in NinjaOne Admin Portal:" -ForegroundColor Yellow
Write-Host "Administration > Device Custom Fields > Add New Field`n" -ForegroundColor Yellow

$currentCategory = ""
$categoryCount = 1

foreach ($field in $phase3Fields) {
    if ($field.Category -ne $currentCategory) {
        $currentCategory = $field.Category
        Write-Host "`n--- Category $categoryCount`: $currentCategory ---" -ForegroundColor Green
        $categoryCount++
    }
    
    Write-Host "`nField Name: " -NoNewline -ForegroundColor White
    Write-Host $field.Name -ForegroundColor Cyan
    Write-Host "  Type: " -NoNewline -ForegroundColor Gray
    Write-Host $field.Type -ForegroundColor White
    Write-Host "  Description: " -NoNewline -ForegroundColor Gray
    Write-Host $field.Description -ForegroundColor White
    Write-Host "  Critical: " -NoNewline -ForegroundColor Gray
    
    if ($field.Critical -eq "CRITICAL") {
        Write-Host $field.Critical -ForegroundColor Red
    } elseif ($field.Critical -eq "Yes") {
        Write-Host $field.Critical -ForegroundColor Yellow
    } else {
        Write-Host $field.Critical -ForegroundColor Gray
    }
    
    Write-Host "  Thresholds: " -NoNewline -ForegroundColor Gray
    Write-Host $field.Thresholds -ForegroundColor White
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Next Steps:" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "1. Create all $($phase3Fields.Count) custom fields in NinjaOne Admin Portal" -ForegroundColor Yellow
Write-Host "2. Verify field types match exactly (Number vs Text vs Checkbox)" -ForegroundColor Yellow
Write-Host "3. Deploy updated detection script (v1.7.0+) to devices" -ForegroundColor Yellow
Write-Host "4. Validate data populates in NinjaOne within 24 hours" -ForegroundColor Yellow
Write-Host "5. Review Phase 3 deployment guide: Docs/PHASE3-DEPLOYMENT-PLAN.md`n" -ForegroundColor Yellow

# Export to CSV if requested
if ($ExportCSV) {
    $phase3Fields | Select-Object Category, Name, Type, Description, Critical, Thresholds |
        Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Host "Field definitions exported to: $OutputPath" -ForegroundColor Green
}

Write-Host "`nFor detailed field specifications, see: Docs/PHASE3-NINJAONE-FIELDS.md`n" -ForegroundColor Cyan
