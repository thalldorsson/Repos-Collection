function Get-PhishIRConfig {
    <#
    .SYNOPSIS
    Get PhishIR configuration settings with environment variable overrides.

    .DESCRIPTION
    Loads configuration from PhishIRConfig.psd1 and applies environment variable overrides
    for containerized/automated deployments. Supports dot notation access to nested settings.

    Configuration hierarchy (highest priority first):
    1. Environment variables (PHISHIR_*)
    2. PhishIRConfig.psd1
    3. Built-in defaults

    .PARAMETER Section
    Configuration section to retrieve (e.g., 'Storage', 'SignInTracking', 'GraphAPI').
    If not specified, returns entire configuration object.

    .PARAMETER Key
    Specific configuration key within section (e.g., 'DefaultDaysBack' in 'SignInTracking').

    .PARAMETER Reload
    Force reload configuration from disk, ignoring cached version.

    .EXAMPLE
    Get-PhishIRConfig

    Returns entire configuration object.

    .EXAMPLE
    Get-PhishIRConfig -Section 'Storage'

    Returns:
    BasePath         : C:\PhishIR
    IncidentStore    : @{Path='C:\PhishIR\IncidentStore\incidents.jsonl'; ...}
    Evidence         : @{BasePath='C:\PhishIR\Evidence'; ...}

    .EXAMPLE
    Get-PhishIRConfig -Section 'SignInTracking' -Key 'DefaultDaysBack'

    Returns: 7

    .EXAMPLE
    # Get incident store path (respects env var override)
    $storePath = Get-PhishIRConfig -Section 'Storage' -Key 'IncidentStore'
    $incidents = Get-Content $storePath.Path | ConvertFrom-Json

    .EXAMPLE
    # Override via environment variable (for CI/CD)
    $env:PHISHIR_STORAGE_BASEPATH = 'D:\PhishIR'
    $config = Get-PhishIRConfig -Reload
    $config.Storage.BasePath  # Returns 'D:\PhishIR'

    .NOTES
    Environment Variable Naming Convention:
    - Prefix: PHISHIR_
    - Nested keys separated by underscores
    - Examples:
      * PHISHIR_STORAGE_BASEPATH → Storage.BasePath
      * PHISHIR_SIGNTRACKING_DEFAULTDAYSBACK → SignInTracking.DefaultDaysBack
      * PHISHIR_SIEM_SENTINEL_ENABLED → SIEM.Sentinel.Enabled
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [ValidateSet('Storage', 'SignInTracking', 'GraphAPI', 'IncidentLogging', 'URLProcessing', 
                 'SIEM', 'Security', 'Archival', 'Performance', 'Compliance', 'Notifications', 'Features', 'Legacy')]
        [string]$Section,

        [Parameter()]
        [string]$Key,

        [Parameter()]
        [switch]$Reload
    )

    # Script-level cache for configuration
    if (-not (Get-Variable -Name 'PhishIRConfigCache' -Scope Script -ErrorAction SilentlyContinue) -or $Reload) {
        Write-Verbose "Loading PhishIR configuration from disk"
        
        # Determine config file path
        $moduleRoot = $PSScriptRoot | Split-Path -Parent
        $configPath = Join-Path $moduleRoot 'Config\PhishIRConfig.psd1'
        
        if (-not (Test-Path $configPath)) {
            throw "PhishIR configuration file not found: $configPath"
        }
        
        # Load configuration
        try {
            $script:PhishIRConfigCache = Import-PowerShellDataFile -Path $configPath
        } catch {
            throw "Failed to load PhishIR configuration: $($_.Exception.Message)"
        }
        
        # Apply environment variable overrides
        $envOverrides = Get-ChildItem Env:PHISHIR_* -ErrorAction SilentlyContinue
        foreach ($envVar in $envOverrides) {
            # Parse variable name: PHISHIR_STORAGE_BASEPATH → Storage.BasePath
            $parts = $envVar.Name -replace '^PHISHIR_', '' -split '_'
            
            if ($parts.Count -ge 2) {
                $section = $parts[0]
                $keyPath = $parts[1..($parts.Count - 1)]
                
                # Navigate to nested key
                $current = $script:PhishIRConfigCache.$section
                for ($i = 0; $i -lt $keyPath.Count - 1; $i++) {
                    $current = $current.$($keyPath[$i])
                }
                
                # Set value (convert boolean strings)
                $value = $envVar.Value
                if ($value -in @('true', 'false')) {
                    $value = [bool]::Parse($value)
                } elseif ($value -match '^\d+$') {
                    $value = [int]$value
                }
                
                $current.$($keyPath[-1]) = $value
                Write-Verbose "Applied env override: $($envVar.Name) = $value"
            }
        }
        
        Write-Verbose "Configuration loaded successfully (v$($script:PhishIRConfigCache.ConfigVersion))"
    }
    
    # Return requested configuration
    if ($Section) {
        if ($Key) {
            return $script:PhishIRConfigCache.$Section.$Key
        } else {
            return $script:PhishIRConfigCache.$Section
        }
    } else {
        return $script:PhishIRConfigCache
    }
}

function Initialize-PhishIREnvironment {
    <#
    .SYNOPSIS
    Initialize PhishIR directory structure based on configuration.

    .DESCRIPTION
    Creates all required directories for PhishIR operations including incident store,
    evidence collection, exports, and archival folders. Idempotent - safe to run multiple times.

    .PARAMETER VerifyOnly
    Don't create directories, only verify they exist and report missing folders.

    .PARAMETER IncludeNetworkShare
    Create network share path if configured (requires appropriate permissions).

    .EXAMPLE
    Initialize-PhishIREnvironment

    Creates all configured PhishIR directories:
    - C:\PhishIR\IncidentStore
    - C:\PhishIR\Evidence\ExcelAttachments
    - C:\PhishIR\Evidence\ExtractedUrls
    - C:\PhishIR\Exports\incident-reports
    - etc.

    .EXAMPLE
    Initialize-PhishIREnvironment -VerifyOnly

    Checks if all required directories exist without creating them.

    .EXAMPLE
    Initialize-PhishIREnvironment -IncludeNetworkShare

    Creates directories including network share path (if configured).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [switch]$VerifyOnly,

        [Parameter()]
        [switch]$IncludeNetworkShare
    )

    $config = Get-PhishIRConfig

    $requiredPaths = @(
        $config.Storage.BasePath
        $config.Storage.IncidentStore.Path | Split-Path -Parent
        $config.Storage.IncidentStore.ArchivePath
        $config.Storage.Evidence.BasePath
        $config.Storage.Evidence.ExcelAttachments
        $config.Storage.Evidence.ExtractedUrls
        $config.Storage.Evidence.EmailMetadata
        $config.Storage.Evidence.Indicators
        $config.Storage.Evidence.SignInLogs
        $config.Storage.Exports.BasePath
        $config.Storage.Exports.IncidentReports
        $config.Storage.Exports.Compliance
        $config.Storage.Exports.PowerBI
    )

    if ($IncludeNetworkShare -and $config.Storage.NetworkShare) {
        $requiredPaths += $config.Storage.NetworkShare
    }

    $missingPaths = @()
    $createdPaths = @()

    foreach ($path in $requiredPaths) {
        if (-not (Test-Path $path)) {
            $missingPaths += $path
            
            if (-not $VerifyOnly) {
                if ($PSCmdlet.ShouldProcess($path, 'Create directory')) {
                    try {
                        New-Item -ItemType Directory -Path $path -Force | Out-Null
                        $createdPaths += $path
                        Write-Verbose "Created: $path"
                    } catch {
                        Write-Warning "Failed to create $path : $($_.Exception.Message)"
                    }
                }
            }
        } else {
            Write-Verbose "Exists: $path"
        }
    }

    # Create README in evidence folder
    $evidenceReadmePath = Join-Path $config.Storage.Evidence.BasePath 'README.txt'
    if (-not (Test-Path $evidenceReadmePath) -and -not $VerifyOnly) {
        $readmeContent = @"
PhishIR Evidence Collection Folder
===================================
Created: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

This folder structure is used by PhishIR for centralized incident response data collection.

Folder Structure:
- ExcelAttachments/  : Quarantined Excel files with malicious hyperlinks
- ExtractedUrls/     : CSV exports of URLs extracted from attachments
- SignInLogs/        : Microsoft Entra ID sign-in logs for phishing email recipients
- EmailMetadata/     : Email delivery details (subject, recipients, timestamps)
- Indicators/        : Submitted threat indicators (Defender for Endpoint)

Retention Policy:
- Hot storage: 180 days
- Cold storage: 7 years (compliance)

For more information, see: docs/CENTRAL_DATA_COLLECTION.md
"@
        $readmeContent | Out-File -FilePath $evidenceReadmePath -Encoding UTF8
    }

    # Summary
    $result = [PSCustomObject]@{
        VerifiedPaths = $requiredPaths.Count
        MissingPaths = $missingPaths.Count
        CreatedPaths = $createdPaths.Count
        MissingPathsList = $missingPaths
        CreatedPathsList = $createdPaths
    }

    if ($VerifyOnly) {
        if ($missingPaths.Count -gt 0) {
            Write-Warning "Found $($missingPaths.Count) missing paths. Run Initialize-PhishIREnvironment (without -VerifyOnly) to create them."
        } else {
            Write-Host "All PhishIR directories exist" -ForegroundColor Green
        }
    } else {
        if ($createdPaths.Count -gt 0) {
            Write-Host "Created $($createdPaths.Count) directories" -ForegroundColor Green
        } else {
            Write-Host "All directories already exist" -ForegroundColor Green
        }
    }

    return $result
}

function Get-PhishIRStoragePath {
    <#
    .SYNOPSIS
    Get centralized storage paths for PhishIR operations.

    .DESCRIPTION
    Returns configured paths for incident store, evidence collection, and exports.
    Helper function to simplify path resolution in other PhishIR functions.

    .PARAMETER PathType
    Type of path to retrieve: IncidentStore, ExcelAttachments, ExtractedUrls,
    SignInLogs, EmailMetadata, Indicators, IncidentReports, Compliance, PowerBI.

    .PARAMETER CreateIfMissing
    Create directory if it doesn't exist.

    .EXAMPLE
    $storePath = Get-PhishIRStoragePath -PathType IncidentStore
    Add-PhishIRIncidentRecord -StorePath $storePath.Path

    .EXAMPLE
    $urlsPath = Get-PhishIRStoragePath -PathType ExtractedUrls -CreateIfMissing
    Export-Csv -Path (Join-Path $urlsPath "campaign-$(Get-Date -Format 'yyyyMMdd').csv")

    .EXAMPLE
    # Get all configured paths
    Get-PhishIRStoragePath -PathType All

    Returns:
    IncidentStore     : C:\PhishIR\IncidentStore\incidents.jsonl
    ExcelAttachments  : C:\PhishIR\Evidence\ExcelAttachments
    ExtractedUrls     : C:\PhishIR\Evidence\ExtractedUrls
    SignInLogs        : C:\PhishIR\Evidence\SignInLogs
    ...
    #>
    [CmdletBinding()]
    [OutputType([string], [PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('IncidentStore', 'ExcelAttachments', 'ExtractedUrls', 'SignInLogs', 
                     'EmailMetadata', 'Indicators', 'IncidentReports', 'Compliance', 'PowerBI', 'All')]
        [string]$PathType,

        [Parameter()]
        [switch]$CreateIfMissing
    )

    $config = Get-PhishIRConfig

    $paths = @{
        IncidentStore = $config.Storage.IncidentStore.Path
        ExcelAttachments = $config.Storage.Evidence.ExcelAttachments
        ExtractedUrls = $config.Storage.Evidence.ExtractedUrls
        SignInLogs = $config.Storage.Evidence.SignInLogs
        EmailMetadata = $config.Storage.Evidence.EmailMetadata
        Indicators = $config.Storage.Evidence.Indicators
        IncidentReports = $config.Storage.Exports.IncidentReports
        Compliance = $config.Storage.Exports.Compliance
        PowerBI = $config.Storage.Exports.PowerBI
    }

    if ($PathType -eq 'All') {
        return [PSCustomObject]$paths
    }

    $path = $paths[$PathType]

    if ($CreateIfMissing -and -not (Test-Path $path)) {
        $directory = if ($PathType -eq 'IncidentStore') { Split-Path $path -Parent } else { $path }
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        Write-Verbose "Created directory: $directory"
    }

    return $path
}

Export-ModuleMember -Function Get-PhishIRConfig, Initialize-PhishIREnvironment, Get-PhishIRStoragePath
