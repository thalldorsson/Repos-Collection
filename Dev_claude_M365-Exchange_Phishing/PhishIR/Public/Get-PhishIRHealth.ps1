function Get-PhishIRHealth {
    <#
    .SYNOPSIS
        Returns health status of the PhishIR module and its dependencies.
    
    .DESCRIPTION
        Performs health checks on module version, required modules, and connection status.
        Returns a structured health object with status, checks, and recommendations.
    
    .EXAMPLE
        Get-PhishIRHealth
        
        Returns health status object with all checks.
    
    .EXAMPLE
        $health = Get-PhishIRHealth
        if ($health.Status -eq 'Healthy') { Write-Host 'All systems go!' }
        
        Check health status before running operations.
    
    .OUTPUTS
        PSCustomObject with properties: Status, Checks, Timestamp, ModuleVersion
    #>
    [CmdletBinding()]
    param()
    
    $checks = @()
    $overallHealthy = $true
    
    # Check 1: Module version
    $moduleVersion = '2.0.0'
    try {
        $module = Get-Module PhishIR
        if ($module) {
            $moduleVersion = $module.Version.ToString()
            $checks += [PSCustomObject]@{
                Check = 'ModuleLoaded'
                Status = 'Pass'
                Message = "PhishIR v$moduleVersion loaded"
            }
        } else {
            $checks += [PSCustomObject]@{
                Check = 'ModuleLoaded'
                Status = 'Warning'
                Message = 'PhishIR module not imported'
            }
            $overallHealthy = $false
        }
    } catch {
        $checks += [PSCustomObject]@{
            Check = 'ModuleLoaded'
            Status = 'Fail'
            Message = "Module check failed: $($_.Exception.Message)"
        }
        $overallHealthy = $false
    }
    
    # Check 2: ExchangeOnlineManagement module
    try {
        $exoModule = Get-Module ExchangeOnlineManagement -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
        if ($exoModule) {
            $minVersion = [version]'3.9.0'
            if ($exoModule.Version -ge $minVersion) {
                $checks += [PSCustomObject]@{
                    Check = 'ExchangeOnlineManagement'
                    Status = 'Pass'
                    Message = "ExchangeOnlineManagement v$($exoModule.Version) installed (>= $minVersion)"
                }
            } else {
                $checks += [PSCustomObject]@{
                    Check = 'ExchangeOnlineManagement'
                    Status = 'Warning'
                    Message = "ExchangeOnlineManagement v$($exoModule.Version) installed (recommend >= $minVersion)"
                }
                $overallHealthy = $false
            }
        } else {
            $checks += [PSCustomObject]@{
                Check = 'ExchangeOnlineManagement'
                Status = 'Fail'
                Message = 'ExchangeOnlineManagement module not installed'
            }
            $overallHealthy = $false
        }
    } catch {
        $checks += [PSCustomObject]@{
            Check = 'ExchangeOnlineManagement'
            Status = 'Fail'
            Message = "Module check failed: $($_.Exception.Message)"
        }
        $overallHealthy = $false
    }
    
    # Check 3: Exchange Online connection
    try {
        $exoSession = Get-PSSession | Where-Object { $_.ConfigurationName -eq 'Microsoft.Exchange' -and $_.State -eq 'Opened' }
        if ($exoSession) {
            $checks += [PSCustomObject]@{
                Check = 'ExchangeOnlineConnection'
                Status = 'Pass'
                Message = 'Connected to Exchange Online'
            }
        } else {
            $checks += [PSCustomObject]@{
                Check = 'ExchangeOnlineConnection'
                Status = 'Warning'
                Message = 'Not connected to Exchange Online (will auto-connect if needed)'
            }
        }
    } catch {
        $checks += [PSCustomObject]@{
            Check = 'ExchangeOnlineConnection'
            Status = 'Warning'
            Message = 'Could not verify Exchange Online connection'
        }
    }
    
    # Check 4: Compliance connection
    try {
        $ippsSession = Get-PSSession | Where-Object { $_.ComputerName -like '*protection.outlook.com' -and $_.State -eq 'Opened' }
        if ($ippsSession) {
            $checks += [PSCustomObject]@{
                Check = 'ComplianceConnection'
                Status = 'Pass'
                Message = 'Connected to Security & Compliance'
            }
        } else {
            $checks += [PSCustomObject]@{
                Check = 'ComplianceConnection'
                Status = 'Warning'
                Message = 'Not connected to Security & Compliance (will auto-connect if needed)'
            }
        }
    } catch {
        $checks += [PSCustomObject]@{
            Check = 'ComplianceConnection'
            Status = 'Warning'
            Message = 'Could not verify Compliance connection'
        }
    }
    
    # Determine overall status
    $status = if ($overallHealthy) { 'Healthy' } else { 'Degraded' }
    
    return [PSCustomObject]@{
        Status = $status
        Checks = $checks
        Timestamp = (Get-Date).ToString('o')
        ModuleVersion = $moduleVersion
    }
}
