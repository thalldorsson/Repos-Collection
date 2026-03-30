<#
.SYNOPSIS
    Packages WinRE Health scripts for Intune Proactive Remediation deployment.

.DESCRIPTION
    Automates the creation of deployment packages for Microsoft Intune.
    Creates a ready-to-deploy ZIP file containing detection and remediation scripts,
    configuration files, and deployment documentation.

.PARAMETER OutputPath
    Path for the output ZIP package. Default: .\WinREHealth-Intune-Package.zip

.PARAMETER WorkspaceId
    Log Analytics Workspace ID to embed in the configuration.

.PARAMETER WorkspaceKey
    Log Analytics Workspace Key to embed in the configuration.
    NOTE: Consider using Azure Key Vault for production deployments.

.PARAMETER DetectionScriptVariant
    Detection script variant to include. Options: Simple, Enhanced, Full
    Default: Simple

.PARAMETER IncludeRemediation
    Include the remediation script in the package. Default: $true

.PARAMETER IncludeReadme
    Include a README file with deployment instructions. Default: $true

.PARAMETER Version
    Version string to include in the package. Default: 1.4.0

.PARAMETER NoConfig
    Skip embedding workspace configuration (for manual configuration).

.EXAMPLE
    .\New-IntunePackage.ps1 -WorkspaceId "abc123" -WorkspaceKey "key123"
    Creates package with embedded workspace configuration.

.EXAMPLE
    .\New-IntunePackage.ps1 -NoConfig -OutputPath "C:\Packages\WinRE.zip"
    Creates package without embedded configuration.

.EXAMPLE
    .\New-IntunePackage.ps1 -DetectionScriptVariant Enhanced -IncludeRemediation $false
    Creates package with enhanced detection only (no remediation).

.NOTES
    Author: WinRE Health Monitor Team
    Version: 1.4.0
    Purpose: Streamline Intune deployment process
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\WinREHealth-Intune-Package.zip",

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceId,

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceKey,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Simple", "Enhanced", "Full")]
    [string]$DetectionScriptVariant = "Simple",

    [Parameter(Mandatory = $false)]
    [bool]$IncludeRemediation = $true,

    [Parameter(Mandatory = $false)]
    [bool]$IncludeReadme = $true,

    [Parameter(Mandatory = $false)]
    [string]$Version = "1.4.0",

    [Parameter(Mandatory = $false)]
    [switch]$NoConfig
)

#region Script Paths
$ScriptRoot = Split-Path -Parent $PSCommandPath
$DetectionScripts = @{
    Simple   = Join-Path $ScriptRoot "Detection\WinRE-Health-Detection-Intune-Simple.ps1"
    Enhanced = Join-Path $ScriptRoot "Detection\WinRE-Health-Detection-Intune-Enhanced.ps1"
    Full     = Join-Path $ScriptRoot "Detection\WinRE-Health-Detection-NinjaOne.ps1"
}
$RemediationScript = Join-Path $ScriptRoot "Remediation\WinRE-Remediate.ps1"
#endregion

#region Helper Functions
function Test-ScriptPaths {
    $selectedDetection = $DetectionScripts[$DetectionScriptVariant]
    
    if (-not (Test-Path $selectedDetection)) {
        Write-Warning "Detection script not found: $selectedDetection"
        # Try to find any detection script
        $fallback = Get-ChildItem -Path (Join-Path $ScriptRoot "Detection") -Filter "*.ps1" | Select-Object -First 1
        if ($fallback) {
            Write-Host "Using fallback detection script: $($fallback.FullName)" -ForegroundColor Yellow
            return $fallback.FullName
        }
        throw "No detection script found in $ScriptRoot\Detection"
    }
    
    return $selectedDetection
}

function New-PackageReadme {
    param(
        [string]$Version,
        [bool]$HasRemediation,
        [bool]$HasConfig
    )
    
    $configNote = if ($HasConfig) {
        "Configuration is embedded in the scripts. Review and update if needed."
    }
    else {
        "⚠️ IMPORTANT: You must configure the WorkspaceId and WorkspaceKey in the detection script before deployment."
    }
    
    $remediationInstructions = if ($HasRemediation) {
        @"
2. **Remediation Script:** `Remediation.ps1`
   - Upload as Remediation script
   - Runs when detection script returns non-zero exit code
   - Attempts to fix WinRE partition issues
"@
    }
    else {
        @"
2. **Remediation Script:** Not included
   - This package includes detection only
   - Manual remediation will be required
"@
    }
    
    return @"
# WinRE Health Monitoring - Intune Package

**Version:** $Version  
**Generated:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  
**Package Type:** Intune Proactive Remediation

---

## 📦 Package Contents

| File | Purpose |
|------|---------|
| Detection.ps1 | Scans device for WinRE health and KB5034441 vulnerability |
| Remediation.ps1 | Fixes WinRE partition issues (if included) |
| config.json | Workspace configuration (if embedded) |
| README.md | This file |

---

## 🚀 Deployment Instructions

### Step 1: Create Proactive Remediation in Intune

1. Navigate to: **Microsoft Intune admin center** → **Devices** → **Remediations**
2. Click **+ Create script package**
3. Enter the following details:
   - **Name:** WinRE Health Monitoring v$Version
   - **Description:** Monitors and remediates WinRE partition issues for KB5034441 compliance

### Step 2: Upload Scripts

1. **Detection Script:** `Detection.ps1`
   - Upload as Detection script
   - Exit code 0 = Compliant (healthy)
   - Exit code 1 = Non-compliant (needs remediation)

$remediationInstructions

### Step 3: Configure Script Settings

| Setting | Recommended Value |
|---------|------------------|
| Run this script using the logged-on credentials | No |
| Enforce script signature check | No (or Yes if signed) |
| Run script in 64-bit PowerShell | Yes |

### Step 4: Assign to Devices

1. Click **Assignments**
2. Add device groups:
   - **Include:** All Windows 10/11 devices
   - **Exclude:** Virtual machines, servers (optional)
3. Set schedule:
   - **Frequency:** Daily
   - **Time:** 2:00 AM (outside business hours)

---

## ⚙️ Configuration

$configNote

### Required Configuration (if not embedded)

Edit `Detection.ps1` and set these values:

```powershell
`$WorkspaceId = "YOUR-WORKSPACE-ID-HERE"
`$WorkspaceKey = "YOUR-WORKSPACE-KEY-HERE"
```

### Optional Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `$Ephemeral` | `$true` | Clean up temp files after execution |
| `$OutputStdOut` | `$false` | Output JSON to console |
| `$TestMode` | `$false` | Skip actual disk operations |

---

## 📊 Monitoring Results

### In Intune

1. Navigate to: **Devices** → **Remediations** → **WinRE Health Monitoring**
2. View:
   - **Overview:** Success/failure rates
   - **Device status:** Per-device results
   - **Script output:** Detection/remediation logs

### In Log Analytics

Run this query to see device health:

```kql
WinREHealthV2_CL
| where TimeGenerated > ago(24h)
| summarize arg_max(TimeGenerated, *) by ComputerName_s
| project 
    ComputerName = ComputerName_s,
    Vulnerable = KB5034441Vulnerable_b,
    WinREEnabled = WinREEnabled_b,
    PartitionSizeMB = PartitionSizeMB_d,
    Severity = Severity_s
| order by Vulnerable desc
```

---

## 🔧 Troubleshooting

### Detection Script Issues

| Issue | Solution |
|-------|----------|
| Script times out | Increase timeout in Intune settings |
| Exit code always 0 | Check script execution policy |
| No data in Log Analytics | Verify WorkspaceId and WorkspaceKey |

### Remediation Issues

| Issue | Solution |
|-------|----------|
| Remediation fails | Check for pending reboots |
| Partition resize fails | Verify adequate free space on OS drive |
| WinRE won't enable | Run `reagentc /info` manually for details |

### Common Error Codes

| Exit Code | Meaning |
|-----------|---------|
| 0 | Success (compliant) |
| 1 | Non-compliant (needs remediation) |
| 2 | Error during detection |
| 3 | Pre-flight check failed |

---

## 📚 Additional Resources

- [Main Documentation](../README.md)
- [Troubleshooting Guide](../Docs/TROUBLESHOOTING.md)
- [Quick Reference](../Docs/QUICK-REFERENCE-CHEATSHEET.md)
- [FAQ](../Docs/FAQ.md)

---

## 📞 Support

- **Issues:** Open a GitHub Issue
- **Questions:** See FAQ documentation
- **Updates:** Check CHANGELOG.md for latest version

---

**WinRE Health Monitoring v$Version**  
*Keeping Windows Recovery Environment healthy*
"@
}

function New-PackageConfig {
    param(
        [string]$WorkspaceId,
        [string]$WorkspaceKey,
        [string]$Version
    )
    
    return @{
        WorkspaceId      = $WorkspaceId
        WorkspaceKey     = $WorkspaceKey
        Version          = $Version
        GeneratedAt      = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        Generator        = "New-IntunePackage.ps1"
        PackageType      = "Intune Proactive Remediation"
        DetectionVariant = $DetectionScriptVariant
        Notes            = "Configuration generated automatically. Update WorkspaceKey if rotated."
    } | ConvertTo-Json -Depth 5
}
#endregion

#region Main Logic
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " WinRE Health - Intune Package Builder" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Validate parameters
if (-not $NoConfig) {
    if (-not $WorkspaceId -or -not $WorkspaceKey) {
        Write-Warning "WorkspaceId and WorkspaceKey not provided."
        Write-Warning "Use -NoConfig to create package without embedded configuration."
        $NoConfig = $true
    }
}

# Find detection script
Write-Host "Locating scripts..." -ForegroundColor Yellow
$detectionScriptPath = Test-ScriptPaths

if (-not $detectionScriptPath) {
    throw "Detection script not found"
}

Write-Host "  Detection: $detectionScriptPath" -ForegroundColor Gray

# Check remediation script
if ($IncludeRemediation) {
    if (Test-Path $RemediationScript) {
        Write-Host "  Remediation: $RemediationScript" -ForegroundColor Gray
    }
    else {
        Write-Warning "Remediation script not found: $RemediationScript"
        $IncludeRemediation = $false
    }
}

# Create temp directory for package contents
$packageDir = Join-Path $env:TEMP "WinREHealth-Package-$(Get-Random)"
New-Item -Path $packageDir -ItemType Directory -Force | Out-Null

try {
    Write-Host ""
    Write-Host "Building package..." -ForegroundColor Yellow
    
    # Copy detection script
    Write-Host "  Adding Detection.ps1" -ForegroundColor Gray
    Copy-Item -Path $detectionScriptPath -Destination (Join-Path $packageDir "Detection.ps1") -Force
    
    # Copy remediation script
    if ($IncludeRemediation) {
        Write-Host "  Adding Remediation.ps1" -ForegroundColor Gray
        Copy-Item -Path $RemediationScript -Destination (Join-Path $packageDir "Remediation.ps1") -Force
    }
    
    # Create config file
    if (-not $NoConfig) {
        Write-Host "  Adding config.json" -ForegroundColor Gray
        $configContent = New-PackageConfig -WorkspaceId $WorkspaceId -WorkspaceKey $WorkspaceKey -Version $Version
        $configContent | Out-File -FilePath (Join-Path $packageDir "config.json") -Encoding UTF8
        
        # Update detection script with embedded config
        $detectionContent = Get-Content -Path (Join-Path $packageDir "Detection.ps1") -Raw
        $workspaceIdUpdated = $false
        $workspaceKeyUpdated = $false
        
        # Update WorkspaceId if pattern found
        if ($detectionContent -match '\$WorkspaceId\s*=\s*[''"][^''"]*[''"]') {
            $detectionContent = $detectionContent -replace '(\$WorkspaceId\s*=\s*)[''"][^''"]*[''"]', "`$1'$WorkspaceId'"
            $workspaceIdUpdated = $true
        }
        
        # Update WorkspaceKey if pattern found
        if ($detectionContent -match '\$WorkspaceKey\s*=\s*[''"][^''"]*[''"]') {
            $detectionContent = $detectionContent -replace '(\$WorkspaceKey\s*=\s*)[''"][^''"]*[''"]', "`$1'$WorkspaceKey'"
            $workspaceKeyUpdated = $true
        }
        
        # Save updated content if any changes were made
        if ($workspaceIdUpdated -or $workspaceKeyUpdated) {
            $detectionContent | Out-File -FilePath (Join-Path $packageDir "Detection.ps1") -Encoding UTF8 -NoNewline
            if ($workspaceIdUpdated -and $workspaceKeyUpdated) {
                Write-Host "  ✓ Embedded workspace configuration" -ForegroundColor Green
            }
            elseif ($workspaceIdUpdated) {
                Write-Host "  ⚠ Embedded WorkspaceId only (WorkspaceKey pattern not found)" -ForegroundColor Yellow
            }
            else {
                Write-Host "  ⚠ Embedded WorkspaceKey only (WorkspaceId pattern not found)" -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "  ⚠ Could not embed configuration (script format may differ)" -ForegroundColor Yellow
        }
    }
    
    # Create README
    if ($IncludeReadme) {
        Write-Host "  Adding README.md" -ForegroundColor Gray
        $readmeContent = New-PackageReadme -Version $Version -HasRemediation $IncludeRemediation -HasConfig (-not $NoConfig)
        $readmeContent | Out-File -FilePath (Join-Path $packageDir "README.md") -Encoding UTF8
    }
    
    # Create ZIP package
    Write-Host ""
    Write-Host "Creating ZIP archive..." -ForegroundColor Yellow
    
    # Ensure output path is absolute
    if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
        $OutputPath = Join-Path (Get-Location) $OutputPath
    }
    
    # Ensure output directory exists
    $outputDir = Split-Path -Parent $OutputPath
    if ($outputDir -and -not (Test-Path $outputDir)) {
        New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
    }
    
    # Remove existing package if present
    if (Test-Path $OutputPath) {
        Remove-Item -Path $OutputPath -Force
    }
    
    # Create ZIP
    Compress-Archive -Path (Join-Path $packageDir "*") -DestinationPath $OutputPath -Force
    
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " Package Created Successfully!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Package Details:" -ForegroundColor White
    Write-Host "  Location:    $OutputPath" -ForegroundColor Gray
    Write-Host "  Version:     $Version" -ForegroundColor Gray
    Write-Host "  Detection:   $DetectionScriptVariant variant" -ForegroundColor Gray
    Write-Host "  Remediation: $(if ($IncludeRemediation) { 'Included' } else { 'Not included' })" -ForegroundColor Gray
    Write-Host "  Config:      $(if ($NoConfig) { 'Not embedded (manual setup required)' } else { 'Embedded' })" -ForegroundColor Gray
    
    $fileSize = (Get-Item $OutputPath).Length / 1KB
    Write-Host "  Size:        $([Math]::Round($fileSize, 1)) KB" -ForegroundColor Gray
    Write-Host ""
    
    # List contents
    Write-Host "Package Contents:" -ForegroundColor White
    Get-ChildItem -Path $packageDir | ForEach-Object {
        Write-Host "  - $($_.Name)" -ForegroundColor Gray
    }
    Write-Host ""
    
    # Next steps
    Write-Host "Next Steps:" -ForegroundColor White
    Write-Host "  1. Extract the ZIP file" -ForegroundColor Gray
    Write-Host "  2. Review README.md for deployment instructions" -ForegroundColor Gray
    if ($NoConfig) {
        Write-Host "  3. Update WorkspaceId and WorkspaceKey in Detection.ps1" -ForegroundColor Yellow
    }
    Write-Host "  $(if ($NoConfig) { '4' } else { '3' }). Upload to Intune Proactive Remediations" -ForegroundColor Gray
    Write-Host ""
    
    # Return package info
    return @{
        Success         = $true
        OutputPath      = $OutputPath
        Version         = $Version
        Detection       = $DetectionScriptVariant
        Remediation     = $IncludeRemediation
        ConfigEmbedded  = -not $NoConfig
        SizeKB          = [Math]::Round($fileSize, 1)
    }
}
catch {
    Write-Error "Failed to create package: $_"
    throw
}
finally {
    # Cleanup temp directory
    if (Test-Path $packageDir) {
        Remove-Item -Path $packageDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
#endregion
