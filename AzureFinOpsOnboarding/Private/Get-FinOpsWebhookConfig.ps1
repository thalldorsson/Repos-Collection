<#
.SYNOPSIS
Loads webhook configuration from configuration file.

.DESCRIPTION
Loads webhook-config.json from the module's Config directory.
Falls back to default values if file not found.

.PARAMETER ConfigPath
Optional custom path to webhook-config.json. If not specified, uses module default.

.OUTPUTS
[hashtable] containing webhook configuration

.NOTES
- Config file location: .\Config\webhook-config.json
- Returns merged config (file + defaults)
- Caches config for performance (reload with -Force)
#>
function Get-FinOpsWebhookConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    # Return cached config if available and not forced
    if ($script:FinOpsWebhookConfig -and -not $Force) {
        return $script:FinOpsWebhookConfig
    }

    # Determine config file path
    if (-not $ConfigPath) {
        $moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $ConfigPath = Join-Path -Path $moduleRoot -ChildPath 'Config' | Join-Path -ChildPath 'webhook-config.json'
    }

    # Default configuration
    $defaultConfig = @{
        WebhookRetry = @{
            Enabled                    = $true
            MaxRetries                 = 4
            InitialRetryDelaySeconds   = 2
            BackoffMultiplier          = 4
            HealthCheckTimeoutSeconds  = 5
            HealthCheckCacheDurationSeconds = 30
        }
        CircuitBreaker = @{
            Enabled            = $true
            FailureThreshold   = 5
            ResetSeconds       = 300
            HalfOpenTestAttempts = 1
        }
        Fallback = @{
            QueueEnabled            = $true
            QueuePath               = Join-Path $env:APPDATA 'FinOps\WebhookQueue'
            RetentionDays           = 30
            EnableEmailNotification = $false
            AdminEmail              = ''
            MaxQueueItemSize        = 10485760
        }
        Logging = @{
            Enabled            = $true
            LogPath            = Join-Path $env:APPDATA 'FinOps\Logs\WebhookDelivery'
            RetentionDays      = 90
            LogLevel           = 'Information'
            IncludeResponseBody = $false
            RotationPolicy     = 'Daily'
        }
        Endpoints = @{
            Teams = @{
                Enabled      = $true
                MaxRetries   = 4
                TimeoutSeconds = 30
            }
            PowerBI = @{
                Enabled      = $true
                MaxRetries   = 4
                TimeoutSeconds = 30
            }
            Jira = @{
                Enabled      = $true
                MaxRetries   = 3
                TimeoutSeconds = 20
            }
        }
    }

    # Try to load config file
    $config = $defaultConfig
    if (Test-Path -Path $ConfigPath) {
        try {
            $fileConfig = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
            
            # Merge file config with defaults (file overrides defaults)
            if ($fileConfig) {
                foreach ($section in $fileConfig.Keys) {
                    if ($config.ContainsKey($section) -and $fileConfig[$section] -is [hashtable]) {
                        foreach ($key in $fileConfig[$section].Keys) {
                            $config[$section][$key] = $fileConfig[$section][$key]
                        }
                    }
                    else {
                        $config[$section] = $fileConfig[$section]
                    }
                }
            }

            Write-Verbose "Loaded webhook config from: $ConfigPath"
        }
        catch {
            Write-Warning "Failed to load webhook config from $ConfigPath, using defaults: $_"
        }
    }
    else {
        Write-Verbose "Webhook config file not found at $ConfigPath, using defaults"
    }

    # Expand environment variables in paths
    if ($config.Fallback.QueuePath -like '*%*') {
        $config.Fallback.QueuePath = [System.Environment]::ExpandEnvironmentVariables($config.Fallback.QueuePath)
    }
    if ($config.Logging.LogPath -like '*%*') {
        $config.Logging.LogPath = [System.Environment]::ExpandEnvironmentVariables($config.Logging.LogPath)
    }

    # Cache config
    $script:FinOpsWebhookConfig = $config

    return $config
}
