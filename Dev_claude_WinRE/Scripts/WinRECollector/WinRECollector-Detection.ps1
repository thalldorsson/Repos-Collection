#Requires -Version 5.1
<#
.SYNOPSIS
  WinRE Health Detection Script - For Intune Proactive Remediations.
.DESCRIPTION
  Detection script runs as part of Intune Proactive Remediations.
  Returns 0 (success) if WinRE is enabled and partition is healthy; non-zero if issues detected.
  Used in conjunction with WinRECollector-Remediation.ps1.
  
.NOTES
  Version: 1.0.0
  Schema Version: 2024-12-04
  Exit codes:
    0 = Compliant (WinRE enabled, partition accessible)
    1 = Non-compliant (WinRE disabled or issues detected)
  
.EXAMPLE
  & .\WinRECollector-Detection.ps1
#>

$ErrorActionPreference = 'SilentlyContinue'

try {
    # Check WinRE status
    $reagentOutput = & reagentc /info 2>&1 | Out-String
    
    if ($reagentOutput -match 'Windows RE status\s*:\s*Enabled') {
        # WinRE is enabled; check partition
        $disk = Get-Disk -Number 0 -ErrorAction SilentlyContinue
        if ($disk) {
            $partitions = Get-Partition -DiskNumber 0 -ErrorAction SilentlyContinue | 
                          Where-Object { $_.Type -in @('Recovery', 'System', 'Hidden') -and $_.Size -gt 100MB }
            
            if ($partitions) {
                # Compliant: WinRE enabled and partition exists
                Write-Host "WinRE is enabled and recovery partition exists."
                exit 0
            }
        }
    }
    
    # Non-compliant: WinRE disabled or partition missing
    Write-Host "WinRE is disabled or recovery partition not found."
    exit 1
}
catch {
    Write-Host "Detection error: $_"
    exit 1
}
