<#
.SYNOPSIS
    Loads environment configuration from .env file and sets PowerShell environment variables.

.DESCRIPTION
    Reads a .env file (POSIX format: key=value, one per line) and sets corresponding PowerShell
    environment variables. Supports comments (#), empty lines, and quoted values.
    
    This module makes configuration from .env accessible to scripts without modifying parameters.
    Scripts can read settings via environment variables: $env:LA_WORKSPACE_ID, etc.

.PARAMETER EnvFilePath
    Path to .env file (default: .env in project root or current directory)

.PARAMETER SetGlobal
    If true, sets Global scope variables in addition to $env: (useful for debugging)

.NOTES ON VERBOSE
    This script uses PowerShell's built-in Verbose common parameter provided by CmdletBinding.
    Use -Verbose on invocation to see detailed output (no custom Verbose parameter is defined).

.EXAMPLE
    # Load .env from current directory
    & .\Scripts\Modules\Load-EnvFile.ps1
    
    # Then use environment variables in scripts
    $workspaceId = $env:LA_WORKSPACE_ID

.EXAMPLE
    # Load .env with verbose output
    & .\Scripts\Modules\Load-EnvFile.ps1 -Verbose

.EXAMPLE
    # Load from custom path
    & .\Scripts\Modules\Load-EnvFile.ps1 -EnvFilePath ".\config\.env.prod"

.NOTES
    Author: Thorsteinn Halldorsson
    Version: 1.0.0
    The .env file is git-ignored for security. Keep sensitive credentials in .env, not in code.
#>

[CmdletBinding()]
param(
    [string]$EnvFilePath = ".env",
    [switch]$SetGlobal
)

# Resolve to absolute path if relative
if (-not [System.IO.Path]::IsPathRooted($EnvFilePath)) {
    # Try project root first
    $projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $testPath = Join-Path $projectRoot $EnvFilePath
    
    if (Test-Path $testPath) {
        $EnvFilePath = $testPath
    } else {
        # Fall back to current directory
        $EnvFilePath = Join-Path (Get-Location) $EnvFilePath
    }
}

if (-not (Test-Path $EnvFilePath)) {
    Write-Warning ".env file not found at: $EnvFilePath"
    Write-Warning "Create one by copying .env.example (cp .env.example .env) and then edit with your credentials."
    return
}

Write-Verbose "Loading environment from: $EnvFilePath"

$loadedCount = 0
$errorCount = 0

try {
    Get-Content $EnvFilePath | ForEach-Object {
        $line = $_.Trim()
        
        # Skip empty lines and comments
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
            return
        }
        
        # Parse key=value
        if ($line -match '^([^=]+)=(.*)$') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            
            # Remove surrounding quotes if present
            if (($value.StartsWith('"') -and $value.EndsWith('"')) -or 
                ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            
            # Set environment variable
            [System.Environment]::SetEnvironmentVariable($key, $value, [System.EnvironmentVariableTarget]::Process)
            
            if ($SetGlobal) {
                Set-Variable -Name $key -Value $value -Scope Global -Force
            }
            
            # Verbose output per variable (masked for secrets)
            $displayValue = if ($key -match '(KEY|SECRET|PASSWORD)') {
                "[hidden - $($value.Length) chars]"
            } else {
                $value
            }
            Write-Verbose "Loaded: $key = $displayValue"
            
            $loadedCount++
        }
        else {
            Write-Host "  ⚠️  Invalid line format (skipped): $line" -ForegroundColor Yellow
            $errorCount++
        }
    }
    
    if ($loadedCount -gt 0) {
        Write-Host "Loaded $loadedCount environment variables" -ForegroundColor Green
    }
    
    if ($errorCount -gt 0) {
        Write-Warning "Encountered $errorCount parsing errors (see above)"
    }
}
catch {
    Write-Error "Error reading .env file: $($_.Exception.Message)"
    throw
}
