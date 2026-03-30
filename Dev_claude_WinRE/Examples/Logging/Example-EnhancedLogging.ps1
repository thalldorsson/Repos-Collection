<#
.SYNOPSIS
    Example script demonstrating enhanced logging with correlation IDs

.DESCRIPTION
    Shows how to integrate EnhancedLogging module into WinRE detection scripts

.NOTES
    Version: 1.0.0
    Run: .\Example-EnhancedLogging.ps1
#>

# Import enhanced logging
Import-Module "$PSScriptRoot/../../Scripts/Modules/EnhancedLogging.psm1" -Force

# Configure logging
Set-LoggingConfiguration `
    -LogLevel Information `
    -LogFilePath "C:\ProgramData\WinREHealth\Logs\enhanced-example.log" `
    -MaxLogSizeMB 10

# Start correlation context for entire operation
Start-CorrelationContext -Operation "WinRE-Health-Detection-Example"

try {
    Write-LogEntry -Level Information -Message "Detection started" `
        -Data @{
            ComputerName = $env:COMPUTERNAME
            User = $env:USERNAME
            ScriptVersion = "1.0.0"
        }

    Write-Host "`n=== Detection Complete ===" -ForegroundColor Green
    Write-Host "Check example logs for correlation ID tracking" -ForegroundColor Cyan
}
catch {
    Write-LogEntry -Level Critical -Message "Detection failed" -Exception $_.Exception
    Write-Host "`n=== Detection Failed ===" -ForegroundColor Red
    throw
}
finally {
    Stop-CorrelationContext
}
