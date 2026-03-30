function Test-PhishIRConfiguration {
    <#
    .SYNOPSIS
    Validate the PhishIRConfig.psd1 configuration file for correctness and completeness.

    .DESCRIPTION
    Performs comprehensive validation of the PhishIR configuration file, checking:
    - File existence and PowerShell data file syntax
    - Required sections and keys are present
    - Path accessibility (storage directories)
    - SIEM integration settings (when enabled)
    - Azure Blob Storage configuration (when archival enabled)
    - Feature flag consistency
    - Environment variable overrides

    Returns a validation report with errors, warnings, and recommendations.

    .PARAMETER ConfigPath
    Path to PhishIRConfig.psd1 file. If not specified, uses default module config path.

    .PARAMETER CheckPaths
    Test that all configured storage paths exist or can be created.

    .PARAMETER CheckSIEM
    Validate SIEM integration settings (Sentinel WorkspaceId, Splunk HEC endpoint).

    .PARAMETER CheckAzureBlob
    Validate Azure Blob Storage settings for archival (requires Az.Storage module).

    .PARAMETER Detailed
    Return detailed validation report including all checks performed.

    .EXAMPLE
    Test-PhishIRConfiguration

    Perform basic configuration validation.

    .EXAMPLE
    Test-PhishIRConfiguration -CheckPaths -CheckSIEM -Detailed

    Comprehensive validation including path accessibility and SIEM settings.

    .EXAMPLE
    Test-PhishIRConfiguration -ConfigPath "C:\CustomConfig\PhishIRConfig.psd1"

    Validate a custom configuration file.

    .NOTES
    This function is called automatically by Initialize-PhishIREnvironment when -VerifyOnly is used.
    Recommended to run before deploying configuration changes to production.

    .LINK
    Get-PhishIRConfig
    Initialize-PhishIREnvironment
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $false)]
        [switch]$CheckPaths,

        [Parameter(Mandatory = $false)]
        [switch]$CheckSIEM,

        [Parameter(Mandatory = $false)]
        [switch]$CheckAzureBlob,

        [Parameter(Mandatory = $false)]
        [switch]$Detailed
    )

    $errors = @()
    $warnings = @()
    $info = @()
    $checks = @()

    # Determine config file path
    if (-not $ConfigPath) {
        $moduleRoot = Split-Path -Parent $PSScriptRoot
        $ConfigPath = Join-Path $moduleRoot 'Config' 'PhishIRConfig.psd1'
    }

    # Check 1: File existence
    $checks += [PSCustomObject]@{
        Check = 'ConfigFileExists'
        Status = 'Unknown'
        Message = ''
    }

    if (-not (Test-Path $ConfigPath)) {
        $errors += "Configuration file not found: $ConfigPath"
        $checks[-1].Status = 'Failed'
        $checks[-1].Message = "File not found: $ConfigPath"
    } else {
        $checks[-1].Status = 'Passed'
        $checks[-1].Message = "File exists: $ConfigPath"
        $info += "Configuration file found: $ConfigPath"
    }

    # Check 2: Parse configuration file
    $checks += [PSCustomObject]@{
        Check = 'ConfigFileParseable'
        Status = 'Unknown'
        Message = ''
    }

    $config = $null
    if ($errors.Count -eq 0) {
        try {
            $config = Import-PowerShellDataFile -Path $ConfigPath -ErrorAction Stop
            $checks[-1].Status = 'Passed'
            $checks[-1].Message = 'Configuration file parsed successfully'
            $info += "Configuration file is valid PowerShell data file"
        } catch {
            $errors += "Failed to parse configuration file: $($_.Exception.Message)"
            $checks[-1].Status = 'Failed'
            $checks[-1].Message = "Parse error: $($_.Exception.Message)"
        }
    }

    if ($config) {
        # Check 3: Required sections
        $requiredSections = @('Storage', 'SignInTracking', 'GraphAPI', 'IncidentLogging')
        
        foreach ($section in $requiredSections) {
            $checks += [PSCustomObject]@{
                Check = "Section_$section"
                Status = 'Unknown'
                Message = ''
            }

            if (-not $config.ContainsKey($section)) {
                $errors += "Missing required section: $section"
                $checks[-1].Status = 'Failed'
                $checks[-1].Message = "Section '$section' is missing"
            } else {
                $checks[-1].Status = 'Passed'
                $checks[-1].Message = "Section '$section' present"
            }
        }

        # Check 4: Storage section validation
        if ($config.ContainsKey('Storage')) {
            $storage = $config.Storage

            # Check BasePath
            $checks += [PSCustomObject]@{
                Check = 'Storage_BasePath'
                Status = 'Unknown'
                Message = ''
            }

            if (-not $storage.BasePath) {
                $errors += "Storage.BasePath is not defined"
                $checks[-1].Status = 'Failed'
                $checks[-1].Message = 'BasePath not defined'
            } else {
                $checks[-1].Status = 'Passed'
                $checks[-1].Message = "BasePath: $($storage.BasePath)"

                if ($CheckPaths) {
                    if (Test-Path $storage.BasePath) {
                        $info += "Storage base path exists: $($storage.BasePath)"
                    } else {
                        $warnings += "Storage base path does not exist (will be created): $($storage.BasePath)"
                    }
                }
            }

            # Check IncidentStore configuration
            if (-not $storage.IncidentStore) {
                $warnings += "Storage.IncidentStore section is missing"
            } elseif (-not $storage.IncidentStore.Path) {
                $errors += "Storage.IncidentStore.Path is not defined"
            }
        }

        # Check 5: SignInTracking validation
        if ($config.ContainsKey('SignInTracking')) {
            $signIn = $config.SignInTracking

            $checks += [PSCustomObject]@{
                Check = 'SignInTracking_Configuration'
                Status = 'Unknown'
                Message = ''
            }

            # Validate DaysBack range
            if ($signIn.DefaultDaysBack -lt 1 -or $signIn.DefaultDaysBack -gt 30) {
                $warnings += "SignInTracking.DefaultDaysBack should be between 1-30 days (current: $($signIn.DefaultDaysBack))"
                $checks[-1].Status = 'Warning'
                $checks[-1].Message = "DefaultDaysBack out of recommended range: $($signIn.DefaultDaysBack)"
            } else {
                $checks[-1].Status = 'Passed'
                $checks[-1].Message = "DefaultDaysBack: $($signIn.DefaultDaysBack) days"
            }

            # Validate BatchSize
            if ($signIn.BatchSize -lt 1 -or $signIn.BatchSize -gt 100) {
                $warnings += "SignInTracking.BatchSize should be between 1-100 (current: $($signIn.BatchSize))"
            }
        }

        # Check 6: GraphAPI validation
        if ($config.ContainsKey('GraphAPI')) {
            $graphAPI = $config.GraphAPI

            $checks += [PSCustomObject]@{
                Check = 'GraphAPI_Scopes'
                Status = 'Unknown'
                Message = ''
            }

            if (-not $graphAPI.RequiredScopes -or $graphAPI.RequiredScopes.Count -eq 0) {
                $errors += "GraphAPI.RequiredScopes is empty or missing"
                $checks[-1].Status = 'Failed'
                $checks[-1].Message = 'No required scopes defined'
            } else {
                $checks[-1].Status = 'Passed'
                $checks[-1].Message = "$($graphAPI.RequiredScopes.Count) scopes defined"
                $info += "Required Graph API scopes: $($graphAPI.RequiredScopes -join ', ')"
            }

            # Validate rate limiting settings
            if ($graphAPI.RequestsPerMinute -lt 1 -or $graphAPI.RequestsPerMinute -gt 600) {
                $warnings += "GraphAPI.RequestsPerMinute should be between 1-600 (current: $($graphAPI.RequestsPerMinute))"
            }
        }

        # Check 7: SIEM integration validation
        if ($CheckSIEM) {
            if ($config.ContainsKey('SIEM')) {
                $siem = $config.SIEM

                # Sentinel validation
                if ($siem.Sentinel -and $siem.Sentinel.Enabled) {
                    $checks += [PSCustomObject]@{
                        Check = 'SIEM_Sentinel'
                        Status = 'Unknown'
                        Message = ''
                    }

                    if (-not $siem.Sentinel.WorkspaceId) {
                        $errors += "SIEM.Sentinel.Enabled is true but WorkspaceId is not configured"
                        $checks[-1].Status = 'Failed'
                        $checks[-1].Message = 'Sentinel enabled but WorkspaceId missing'
                    } elseif (-not $siem.Sentinel.SharedKey) {
                        $errors += "SIEM.Sentinel.Enabled is true but SharedKey is not configured"
                        $checks[-1].Status = 'Failed'
                        $checks[-1].Message = 'Sentinel enabled but SharedKey missing'
                    } else {
                        $checks[-1].Status = 'Passed'
                        $checks[-1].Message = 'Sentinel configuration complete'
                        $info += "Sentinel integration configured for workspace: $($siem.Sentinel.WorkspaceId)"
                    }
                }

                # Splunk validation
                if ($siem.Splunk -and $siem.Splunk.Enabled) {
                    $checks += [PSCustomObject]@{
                        Check = 'SIEM_Splunk'
                        Status = 'Unknown'
                        Message = ''
                    }

                    if (-not $siem.Splunk.HecEndpoint) {
                        $errors += "SIEM.Splunk.Enabled is true but HecEndpoint is not configured"
                        $checks[-1].Status = 'Failed'
                        $checks[-1].Message = 'Splunk enabled but HecEndpoint missing'
                    } elseif (-not $siem.Splunk.HecToken) {
                        $errors += "SIEM.Splunk.Enabled is true but HecToken is not configured"
                        $checks[-1].Status = 'Failed'
                        $checks[-1].Message = 'Splunk enabled but HecToken missing'
                    } else {
                        $checks[-1].Status = 'Passed'
                        $checks[-1].Message = 'Splunk configuration complete'
                        $info += "Splunk integration configured for endpoint: $($siem.Splunk.HecEndpoint)"
                    }
                }
            }
        }

        # Check 8: Azure Blob Storage validation
        if ($CheckAzureBlob) {
            if ($config.ContainsKey('Archival')) {
                $archival = $config.Archival

                if ($archival.AzureBlob -and $archival.AzureBlob.StorageAccountName) {
                    $checks += [PSCustomObject]@{
                        Check = 'Archival_AzureBlob'
                        Status = 'Unknown'
                        Message = ''
                    }

                    if (-not $archival.AzureBlob.ContainerName) {
                        $errors += "Archival.AzureBlob.StorageAccountName is set but ContainerName is missing"
                        $checks[-1].Status = 'Failed'
                        $checks[-1].Message = 'ContainerName missing'
                    } else {
                        $checks[-1].Status = 'Passed'
                        $checks[-1].Message = "Storage: $($archival.AzureBlob.StorageAccountName), Container: $($archival.AzureBlob.ContainerName)"
                        $info += "Azure Blob archival configured: $($archival.AzureBlob.StorageAccountName)/$($archival.AzureBlob.ContainerName)"
                    }

                    # Check if Az.Storage module is available
                    if (-not (Get-Module -ListAvailable -Name Az.Storage)) {
                        $warnings += "Az.Storage module not installed. Install with: Install-Module Az.Storage"
                    }
                }
            }
        }

        # Check 9: Feature flags consistency
        if ($config.ContainsKey('Features')) {
            $features = $config.Features
            $enabledFeatures = @()

            foreach ($key in $features.Keys) {
                if ($features[$key] -eq $true) {
                    $enabledFeatures += $key
                }
            }

            if ($enabledFeatures.Count -gt 0) {
                $info += "Experimental features enabled: $($enabledFeatures -join ', ')"
                $warnings += "Experimental features are enabled. Use with caution in production."
            }
        }

        # Check 10: Environment variable overrides
        $envVars = Get-ChildItem Env: | Where-Object { $_.Name -like 'PHISHIR_*' }
        if ($envVars) {
            $checks += [PSCustomObject]@{
                Check = 'EnvironmentVariableOverrides'
                Status = 'Info'
                Message = "$($envVars.Count) environment variable override(s) detected"
            }

            $info += "Environment variable overrides detected: $($envVars.Count)"
            foreach ($envVar in $envVars) {
                $info += "  $($envVar.Name) = $($envVar.Value)"
            }
        }
    }

    # Build validation report
    $valid = ($errors.Count -eq 0)

    $report = [PSCustomObject]@{
        Valid = $valid
        ConfigPath = $ConfigPath
        ErrorCount = $errors.Count
        WarningCount = $warnings.Count
        InfoCount = $info.Count
        Errors = $errors
        Warnings = $warnings
        Info = $info
    }

    if ($Detailed) {
        Add-Member -InputObject $report -NotePropertyName 'Checks' -NotePropertyValue $checks
    }

    # Display summary
    if ($valid) {
        Write-Host "`n✓ Configuration validation PASSED" -ForegroundColor Green
    } else {
        Write-Host "`n✗ Configuration validation FAILED" -ForegroundColor Red
    }

    Write-Host "  Errors: $($errors.Count)" -ForegroundColor $(if ($errors.Count -gt 0) { 'Red' } else { 'Green' })
    Write-Host "  Warnings: $($warnings.Count)" -ForegroundColor $(if ($warnings.Count -gt 0) { 'Yellow' } else { 'Green' })
    Write-Host "  Info: $($info.Count)" -ForegroundColor Cyan

    if ($errors.Count -gt 0) {
        Write-Host "`nErrors:" -ForegroundColor Red
        $errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    }

    if ($warnings.Count -gt 0) {
        Write-Host "`nWarnings:" -ForegroundColor Yellow
        $warnings | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    }

    if ($Detailed -and $info.Count -gt 0) {
        Write-Host "`nInfo:" -ForegroundColor Cyan
        $info | ForEach-Object { Write-Host "  - $_" -ForegroundColor Cyan }
    }

    return $report
}
