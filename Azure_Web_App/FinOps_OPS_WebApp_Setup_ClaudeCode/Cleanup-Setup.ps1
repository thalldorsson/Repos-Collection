# ===============================================================
# FinOps WebApp Setup Cleanup Script
# Removes files and folders not needed for production deployment
# Version: 2.0
# ===============================================================

<#
.SYNOPSIS
    Cleans up the FinOps WebApp setup folder by removing development artifacts and non-production files.

.DESCRIPTION
    This script removes files and folders that are not needed for production deployment,
    including node_modules, design documentation, empty folders, and temporary files.

.PARAMETER SetupPath
    The path to the setup folder to clean. Defaults to current directory.

.PARAMETER DryRun
    If specified, shows what would be removed without actually deleting anything.

.EXAMPLE
    .\Cleanup-Setup.ps1
    Cleans the current directory.

.EXAMPLE
    .\Cleanup-Setup.ps1 -SetupPath "C:\MySetup" -DryRun -Verbose
    Shows what would be cleaned in the specified path with detailed output.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SetupPath = (Get-Location).Path,
    
    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

Write-Host "🧹 FinOps WebApp Setup Cleanup" -ForegroundColor Green
Write-Host "==============================" -ForegroundColor Green
Write-Host "Setup Path: $SetupPath" -ForegroundColor Cyan
if ($DryRun) { Write-Host "Mode: DRY RUN (no files will be deleted)" -ForegroundColor Yellow }
Write-Host ""

# Define files and folders to remove (not needed for production setup)
$itemsToRemove = @(
    # Development/design documentation
    @{ Path = "Frontend\DESIGN-UNIFICATION-COMPLETE.md"; Type = "File"; Reason = "Design documentation not needed for deployment" },
    @{ Path = "Frontend\design-system-test.html"; Type = "File"; Reason = "Test file not needed for deployment" },
    
    # Empty development folders (will only remove if empty)
    @{ Path = "Frontend\public"; Type = "EmptyFolder"; Reason = "Empty public folder" },
    @{ Path = "Frontend\src\components\Auth"; Type = "EmptyFolder"; Reason = "Empty Auth components folder" },
    @{ Path = "Frontend\src\components\Dashboard"; Type = "EmptyFolder"; Reason = "Empty Dashboard components folder" },
    @{ Path = "Frontend\src\config"; Type = "EmptyFolder"; Reason = "Empty config folder" },
    
    # Backend development artifacts
    @{ Path = "Backend\node_modules"; Type = "Folder"; Reason = "Node modules will be reinstalled during deployment" },
    
    # Log and temporary files (patterns)
    @{ Path = "*.log"; Type = "Pattern"; Reason = "Log files not needed for deployment" },
    @{ Path = "*.tmp"; Type = "Pattern"; Reason = "Temporary files not needed for deployment" },
    @{ Path = ".env.local"; Type = "Pattern"; Reason = "Local environment files not needed for deployment" }
)

$removedItems = @()
$skippedItems = @()

Write-Host "Scanning for cleanup items..." -ForegroundColor Cyan

foreach ($item in $itemsToRemove) {
    $fullPath = Join-Path $SetupPath $item.Path
    
    switch ($item.Type) {
        "File" {
            if (Test-Path $fullPath -PathType Leaf) {
                if ($DryRun) {
                    Write-Host "[DRY RUN] Would remove file: $($item.Path)" -ForegroundColor Yellow
                    Write-Host "  Reason: $($item.Reason)" -ForegroundColor Gray
                } else {
                    try {
                        Remove-Item $fullPath -Force
                        Write-Host "✅ Removed file: $($item.Path)" -ForegroundColor Green
                        if ($Verbose) { Write-Host "  Reason: $($item.Reason)" -ForegroundColor Gray }
                        $removedItems += $item
                    }
                    catch {
                        Write-Host "❌ Failed to remove file: $($item.Path)" -ForegroundColor Red
                        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
                    }
                }
            } else {
                if ($Verbose) { Write-Host "⚪ File not found: $($item.Path)" -ForegroundColor Gray }
                $skippedItems += $item
            }
        }
        
        "Folder" {
            if (Test-Path $fullPath -PathType Container) {
                if ($DryRun) {
                    Write-Host "[DRY RUN] Would remove folder: $($item.Path)" -ForegroundColor Yellow
                    Write-Host "  Reason: $($item.Reason)" -ForegroundColor Gray
                } else {
                    try {
                        Remove-Item $fullPath -Recurse -Force
                        Write-Host "✅ Removed folder: $($item.Path)" -ForegroundColor Green
                        if ($Verbose) { Write-Host "  Reason: $($item.Reason)" -ForegroundColor Gray }
                        $removedItems += $item
                    }
                    catch {
                        Write-Host "❌ Failed to remove folder: $($item.Path)" -ForegroundColor Red
                        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
                    }
                }
            } else {
                if ($Verbose) { Write-Host "⚪ Folder not found: $($item.Path)" -ForegroundColor Gray }
                $skippedItems += $item
            }
        }
        
        "EmptyFolder" {
            if (Test-Path $fullPath -PathType Container) {
                $contents = Get-ChildItem $fullPath -Force -ErrorAction SilentlyContinue
                if ($contents.Count -eq 0) {
                    if ($DryRun) {
                        Write-Host "[DRY RUN] Would remove empty folder: $($item.Path)" -ForegroundColor Yellow
                        Write-Host "  Reason: $($item.Reason)" -ForegroundColor Gray
                    } else {
                        try {
                            Remove-Item $fullPath -Force
                            Write-Host "✅ Removed empty folder: $($item.Path)" -ForegroundColor Green
                            if ($Verbose) { Write-Host "  Reason: $($item.Reason)" -ForegroundColor Gray }
                            $removedItems += $item
                        }
                        catch {
                            Write-Host "❌ Failed to remove empty folder: $($item.Path)" -ForegroundColor Red
                            Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
                        }
                    }
                } else {
                    Write-Host "⚠️ Keeping non-empty folder: $($item.Path)" -ForegroundColor Cyan
                    if ($Verbose) { Write-Host "  Contains $($contents.Count) items" -ForegroundColor Gray }
                    $skippedItems += $item
                }
            } else {
                if ($Verbose) { Write-Host "⚪ Folder not found: $($item.Path)" -ForegroundColor Gray }
                $skippedItems += $item
            }
        }
        
        "Pattern" {
            $patternFiles = Get-ChildItem -Path $SetupPath -Recurse -Filter $item.Path -ErrorAction SilentlyContinue
            if ($patternFiles) {
                foreach ($file in $patternFiles) {
                    $relativePath = $file.FullName.Replace("$SetupPath\", "")
                    if ($DryRun) {
                        Write-Host "[DRY RUN] Would remove pattern file: $relativePath" -ForegroundColor Yellow
                        Write-Host "  Reason: $($item.Reason)" -ForegroundColor Gray
                    } else {
                        try {
                            Remove-Item $file.FullName -Force
                            Write-Host "✅ Removed pattern file: $relativePath" -ForegroundColor Green
                            if ($Verbose) { Write-Host "  Reason: $($item.Reason)" -ForegroundColor Gray }
                        }
                        catch {
                            Write-Host "❌ Failed to remove pattern file: $relativePath" -ForegroundColor Red
                            Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
                        }
                    }
                }
                $removedItems += $item
            } else {
                if ($Verbose) { Write-Host "⚪ No files matching pattern: $($item.Path)" -ForegroundColor Gray }
                $skippedItems += $item
            }
        }
    }
}

# Summary
Write-Host "`n" + "="*50 -ForegroundColor Green
Write-Host "🧹 CLEANUP SUMMARY" -ForegroundColor Green
Write-Host "="*50 -ForegroundColor Green

if ($DryRun) {
    Write-Host "DRY RUN MODE - No files were actually removed" -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "📊 Statistics:" -ForegroundColor Cyan
Write-Host "  Items processed: $($itemsToRemove.Count)" -ForegroundColor White
Write-Host "  Items removed: $($removedItems.Count)" -ForegroundColor Green
Write-Host "  Items skipped: $($skippedItems.Count)" -ForegroundColor Yellow

if ($removedItems.Count -gt 0) {
    Write-Host "`n✅ Successfully removed:" -ForegroundColor Green
    $removedItems | ForEach-Object { Write-Host "  - $($_.Path)" -ForegroundColor White }
}

if ($skippedItems.Count -gt 0 -and $Verbose) {
    Write-Host "`n⚪ Skipped items:" -ForegroundColor Yellow
    $skippedItems | ForEach-Object { Write-Host "  - $($_.Path)" -ForegroundColor Gray }
}

Write-Host "`n📁 Current folder structure:" -ForegroundColor Cyan
try {
    Get-ChildItem $SetupPath -Recurse -Directory | Where-Object { 
        # Only show directories that contain files or are essential
        $hasFiles = (Get-ChildItem $_.FullName -File -ErrorAction SilentlyContinue).Count -gt 0
        $isEssential = $_.Name -in @("Frontend", "Backend", "src", "components", "Layout", "infra", "docs")
        $hasFiles -or $isEssential
    } | ForEach-Object { 
        $relativePath = $_.FullName.Replace($SetupPath, "").TrimStart('\')
        $indent = "  " * ($relativePath.Split('\').Count - 1)
        Write-Host "$indent📁 $($_.Name)/" -ForegroundColor Cyan
        
        # Show key files in essential directories
        if ($_.Name -in @("Frontend", "Backend")) {
            $keyFiles = Get-ChildItem $_.FullName -File | Where-Object { 
                $_.Name -match '\.(html|js|json|md)$' 
            } | Select-Object -First 3
            $keyFiles | ForEach-Object {
                Write-Host "$indent  📄 $($_.Name)" -ForegroundColor White
            }
            if ((Get-ChildItem $_.FullName -File).Count -gt 3) {
                $remainingCount = (Get-ChildItem $_.FullName -File).Count - 3
                Write-Host "$indent  ... and $remainingCount more files" -ForegroundColor Gray
            }
        }
    }
} catch {
    Write-Host "Error displaying folder structure: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`n🎯 Cleanup completed successfully!" -ForegroundColor Green
if (-not $DryRun) {
    Write-Host "The setup is now ready for production deployment." -ForegroundColor Green
}
Write-Host ""
