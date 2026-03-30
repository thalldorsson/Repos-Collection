function Get-FinOpsConfiguration {
    <#
    .SYNOPSIS
        Loads configuration from config.json file.
    
    .DESCRIPTION
        Reads and parses the config.json file from the module root or a specified path.
        Returns a PSCustomObject with configuration settings that can be used with other module functions.
    
    .PARAMETER Path
        Path to the configuration file. Defaults to config.json in the module root directory.
    
    .EXAMPLE
        $config = Get-FinOpsConfiguration
        Invoke-FinOpsOnboarding -TenantId $config.defaultTenantId -OutputDirectory $config.outputDirectory ...
    
    .EXAMPLE
        Get-FinOpsConfiguration -Path "C:\FinOps\myconfig.json"
    
    .OUTPUTS
        PSCustomObject with configuration properties
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Path
    )
    
    try {
        # Default to config.json in module root if no path specified
        if (-not $Path) {
            $moduleRoot = Split-Path -Parent $PSScriptRoot
            $Path = Join-Path $moduleRoot "config.json"
        }
        
        # Check if file exists
        if (-not (Test-Path $Path)) {
            Write-Warning "Configuration file not found at: $Path"
            Write-Warning "To create a configuration file, copy config.json.example to config.json and customize it."
            return $null
        }
        
        Write-Verbose "Loading configuration from: $Path"
        
        # Read and parse JSON
        $configContent = Get-Content -Path $Path -Raw -ErrorAction Stop
        $config = $configContent | ConvertFrom-Json -ErrorAction Stop
        
        Write-Verbose "Configuration loaded successfully"
        
        return $config
        
    } catch {
        Write-Error "Failed to load configuration file: $_"
        return $null
    }
}
