<#
Builds the SampleTimelinePlugin and installs it into the repo `plugins/` folder.

Usage (from repo root):
  powershell -ExecutionPolicy Bypass -File scripts\install-sample-plugin.ps1

This script will:
 - dotnet build SampleTimelinePlugin in Release
 - create plugins\SampleTimelinePlugin if missing
 - copy the built DLL into the plugins folder
#>

param(
    [string]$Configuration = 'Release',
    [string]$Framework = 'net8.0'
)

Write-Host "Building SampleTimelinePlugin ($Configuration / $Framework)..."

$proj = Join-Path -Path $PSScriptRoot -ChildPath "..\SampleTimelinePlugin\SampleTimelinePlugin.csproj"
$proj = Resolve-Path -Path $proj | Select-Object -ExpandProperty Path

dotnet build $proj -c $Configuration || { Write-Error "Build failed"; exit 1 }

$buildOut = Join-Path -Path $PSScriptRoot -ChildPath "..\SampleTimelinePlugin\bin\$Configuration\$Framework"
$buildOut = Resolve-Path -Path $buildOut | Select-Object -ExpandProperty Path

$dest = Join-Path -Path $PSScriptRoot -ChildPath "..\plugins\SampleTimelinePlugin"
if (-not (Test-Path -LiteralPath $dest)) {
    Write-Host "Creating plugin folder: $dest"
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
}

$dllName = 'SampleTimelinePlugin.dll'
$src = Join-Path -Path $buildOut -ChildPath $dllName
if (-not (Test-Path -LiteralPath $src)) {
    Write-Error "Built DLL not found: $src"
    exit 1
}

Copy-Item -Path $src -Destination $dest -Force
Write-Host "Copied $dllName -> $dest"

Write-Host "Sample plugin installed. Run: dotnet run --project ManicTimeWorklogCLI -- plugins list"
