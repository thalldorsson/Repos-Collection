function Get-PhishIRIncidentStorePath {
    <#
    .SYNOPSIS
    Resolve the incident store file path, supporting monthly partitioning when enabled.

    .DESCRIPTION
    Returns the appropriate incident store file path based on configuration. When monthly
    partitioning is enabled, returns a month-specific file (e.g., incidents-2025-11.jsonl).
    Otherwise, returns the default single incidents.jsonl file.

    Monthly partitioning improves performance for large deployments by:
    - Reducing file size and lock contention
    - Speeding up queries (filter by month client-side)
    - Simplifying archival (move old month files to cold storage)
    - Enabling parallel SIEM ingestion

    .PARAMETER Timestamp
    Timestamp to determine which partition file to use. Defaults to current time.

    .PARAMETER CreateIfMissing
    Create the parent directory if it doesn't exist.

    .EXAMPLE
    $storePath = Get-PhishIRIncidentStorePath
    Add-Content -Path $storePath -Value $jsonLine

    Get current month's incident store path.

    .EXAMPLE
    $storePath = Get-PhishIRIncidentStorePath -Timestamp (Get-Date "2025-10-15")
    $incidents = Get-Content $storePath | ConvertFrom-Json

    Retrieve incidents from October 2025 partition.

    .EXAMPLE
    # Enable monthly partitioning in PhishIRConfig.psd1
    Storage = @{
        IncidentStore = @{
            MonthlyPartitioning = $true
        }
    }

    .NOTES
    Partitioning is controlled by Storage.IncidentStore.MonthlyPartitioning config setting.
    When disabled, all incidents are written to a single incidents.jsonl file.

    .LINK
    Add-PhishIRIncidentRecord
    Get-PhishIRIncidentRecord
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [datetime]$Timestamp = (Get-Date),

        [Parameter(Mandatory = $false)]
        [switch]$CreateIfMissing
    )

    try {
        $config = Get-PhishIRConfig -Section 'Storage'
        $baseStorePath = $config.IncidentStore.Path
        $partitioningEnabled = $config.IncidentStore.MonthlyPartitioning

        if ($partitioningEnabled) {
            # Generate month-specific filename: incidents-YYYY-MM.jsonl
            $month = $Timestamp.ToString('yyyy-MM')
            $directory = Split-Path -Parent $baseStorePath
            $fileName = "incidents-$month.jsonl"
            $partitionedPath = Join-Path $directory $fileName

            Write-Verbose "Monthly partitioning enabled. Using partition: $fileName"

            if ($CreateIfMissing -and -not (Test-Path $directory)) {
                New-Item -ItemType Directory -Path $directory -Force | Out-Null
                Write-Verbose "Created incident store directory: $directory"
            }

            return $partitionedPath
        } else {
            # Single file mode (default)
            Write-Verbose "Monthly partitioning disabled. Using single file: $baseStorePath"

            if ($CreateIfMissing) {
                $directory = Split-Path -Parent $baseStorePath
                if (-not (Test-Path $directory)) {
                    New-Item -ItemType Directory -Path $directory -Force | Out-Null
                    Write-Verbose "Created incident store directory: $directory"
                }
            }

            return $baseStorePath
        }
    } catch {
        # Fallback to legacy path if config unavailable
        Write-Warning "Failed to load config for incident store path: $($_.Exception.Message)"
        
        $moduleRoot = Split-Path -Parent $PSScriptRoot
        $defaultPath = Join-Path (Join-Path $moduleRoot 'IncidentStore') 'incidents.jsonl'
        
        if ($CreateIfMissing) {
            $directory = Split-Path -Parent $defaultPath
            if (-not (Test-Path $directory)) {
                New-Item -ItemType Directory -Path $directory -Force | Out-Null
            }
        }

        return $defaultPath
    }
}
