function Add-PhishIRIncidentRecord {
    <#
    .SYNOPSIS
    Append a structured phishing incident record to the centralized PhishIR incident store (JSONL).

    .DESCRIPTION
    Creates and appends a JSON-serialized incident record (one line per record) to the incident store
    located at PhishIR/IncidentStore/incidents.jsonl (configurable via -StorePath). Supports multi-tenant
    operations, correlation IDs, and flexible metadata fields. Thread-safe append with retry logic.

    Recommended usage: Call after completing a containment workflow (e.g., URL blocking, quarantine, device remediation)
    to persist evidence, actions taken, and audit approvals.

    Record schema (example):
    {
      "SchemaVersion": "1.0",
      "IncidentId": "INC-2025-001",
      "TimestampUtc": "2025-11-19T12:34:56Z",
      "Type": "ExcelPhishing",
      "SourceFiles": ["Invoice_305980.xlsx"],
      "ExtractedUrls": ["https://evil.us-east-1.linodeobjects.com/payload.svg"],
      "Actions": {
         "UrlsBlocked": true,
         "EmailQuarantined": true,
         "DevicesIsolated": 2,
         "IndicatorsCreated": 3
      },
      "Tenants": [ { "TenantId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx", "TenantName": "Customer A" } ],
      "CorrelationId": "5c9f4b6d-b3d2-4f02-9c3d-0f6b1a49c2c3",
      "ApprovedBy": "SOC Lead",
      "Severity": "High",
      "Status": "Contained",
      "Notes": "Linode object storage SVG payload. No lateral movement detected.",
      "Tags": ["Excel","Phishing","URL","MultiTenant"]
    }

    .PARAMETER IncidentType
    High-level classification (e.g., ExcelPhishing, CredentialHarvesting, BEC, MalwareDelivery).

    .PARAMETER IncidentId
    Optional explicit incident ID. If omitted, auto-generates pattern INC-<yyyyMMdd>-<random4>.

    .PARAMETER SourceFiles
    Array of file names or paths analyzed (attachments, payloads, exported artifacts).

    .PARAMETER ExtractedUrls
    Array of malicious/suspicious URLs identified during investigation.

    .PARAMETER Actions
    Hashtable describing actions performed (e.g., @{ UrlsBlocked = $true; EmailQuarantined = $true }).

    .PARAMETER Tenants
    Array of tenant objects @{ TenantId = "guid"; TenantName = "Name" } for multi-tenant operations.

    .PARAMETER Severity
    One of: Low, Medium, High, Critical.

    .PARAMETER Status
    One of: Detected, Investigating, Contained, Eradicated, Closed.

    .PARAMETER ApprovedBy
    Name / role of approver for destructive actions.

    .PARAMETER Notes
    Free-form text (<= 1000 chars) summarizing details, findings, caveats.

    .PARAMETER Tags
    Array of additional classification tags.

    .PARAMETER CorrelationId
    Optional correlation GUID. Auto-generated if omitted.

    .PARAMETER StorePath
    Override path to incident store file (default: PhishIR/IncidentStore/incidents.jsonl).

    .PARAMETER PassThru
    Return the created incident object.

    .EXAMPLE
    Add-PhishIRIncidentRecord -IncidentType ExcelPhishing -ExtractedUrls $urls -SourceFiles $files -Actions @{ UrlsBlocked = $true } -Severity High -Status Contained -ApprovedBy "SOC Lead"

    Append an Excel phishing incident with minimal metadata.

    .EXAMPLE
    Add-PhishIRIncidentRecord -IncidentType CredentialHarvesting -ExtractedUrls $urls -Tenants $tenantArray -Actions @{ UrlsBlocked = $true; EmailQuarantined = $true } -Tags phishing,credential -Notes "Finance targeted."

    Multi-tenant credential harvesting incident.

    .NOTES
    - Thread-safe append implemented using a named global mutex.
    - Each record is a single JSON line to support log shipping / ingestion.
    - For SIEM ingestion, ship incidents.jsonl via agent or scheduled task.

    .LINK
    Get-PhishIRIncidentRecord
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$IncidentType,

        [Parameter()]
        [string]$IncidentId,

        [Parameter()]
        [string[]]$SourceFiles,

        [Parameter()]
        [string[]]$ExtractedUrls,

        [Parameter()]
        [hashtable]$Actions,

        [Parameter()]
        [array]$Tenants,

        [Parameter()]
        [ValidateSet('Low','Medium','High','Critical')]
        [string]$Severity = 'Medium',

        [Parameter()]
        [ValidateSet('Detected','Investigating','Contained','Eradicated','Closed')]
        [string]$Status = 'Detected',

        [Parameter()]
        [string]$ApprovedBy,

        [Parameter()]
        [ValidateLength(0,1000)]
        [string]$Notes,

        [Parameter()]
        [string[]]$Tags,

        [Parameter()]
        [Guid]$CorrelationId,

        [Parameter()]
        [string]$StorePath,

        [Parameter()]
        [switch]$PassThru
    )

    begin {
        # Resolve store path (use centralized config with partitioning support)
        if (-not $StorePath) {
            try {
                # Use partitioned path based on incident timestamp
                $StorePath = Get-PhishIRIncidentStorePath -Timestamp (Get-Date) -CreateIfMissing
            } catch {
                # Fallback to legacy single-file path if partitioning function unavailable
                try {
                    $StorePath = Get-PhishIRStoragePath -PathType IncidentStore -CreateIfMissing
                } catch {
                    # Final fallback to hard-coded path
                    $moduleRoot = Split-Path -Parent $MyInvocation.MyCommand.Module.Path
                    $defaultDir = Join-Path $moduleRoot 'IncidentStore'
                    if (-not (Test-Path $defaultDir)) { New-Item -ItemType Directory -Path $defaultDir -Force | Out-Null }
                    $StorePath = Join-Path $defaultDir 'incidents.jsonl'
                }
            }
        }

        # Ensure parent directory exists
        $parent = Split-Path -Parent $StorePath
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

        # Auto-generate IncidentId if missing
        if (-not $IncidentId) {
            $date = (Get-Date).ToString('yyyyMMdd')
            $rand = -join ((65..90 + 48..57) | Get-Random -Count 4 | ForEach-Object { [char]$_ })
            $IncidentId = "INC-$date-$rand"
        }

        # Auto-generate CorrelationId
        if (-not $CorrelationId) { $CorrelationId = [Guid]::NewGuid() }

        # Basic validation
        if ($ExtractedUrls) {
            $invalid = $ExtractedUrls | Where-Object { $_ -notmatch '^https?://.+' }
            if ($invalid) { throw "Invalid URL(s) detected: $($invalid -join ', ')" }
        }

        $timestampUtc = (Get-Date).ToUniversalTime().ToString('o')

        $record = [ordered]@{
            SchemaVersion = '1.0'
            IncidentId    = $IncidentId
            TimestampUtc  = $timestampUtc
            Type          = $IncidentType
            SourceFiles   = $SourceFiles
            ExtractedUrls = $ExtractedUrls
            Actions       = $Actions
            Tenants       = $Tenants
            CorrelationId = $CorrelationId.Guid
            ApprovedBy    = $ApprovedBy
            Severity      = $Severity
            Status        = $Status
            Notes         = $Notes
            Tags          = $Tags
        }

        $json = $record | ConvertTo-Json -Depth 6 -Compress

        # Mutex name stable across sessions
        $mutexName = 'Global/PhishIRIncidentStoreMutex'
        $mutex = $null
        try {
            $mutex = New-Object System.Threading.Mutex($false, $mutexName)
        } catch {
            Write-Warning "Failed to create/access mutex: $_"
        }

        $attempts = 0
        $maxAttempts = 5
        $written = $false

        while (-not $written -and $attempts -lt $maxAttempts) {
            $attempts++
            try {
                if ($mutex) { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(5)) } else { $acquired = $true }
                if (-not $acquired) { Write-Warning "Attempt $attempts could not acquire incident store lock"; Start-Sleep -Milliseconds 300; continue }

                if ($PSCmdlet.ShouldProcess($StorePath, "Append incident $IncidentId")) {
                    Add-Content -Path $StorePath -Value $json
                    $written = $true
                    Write-Host "✓ Incident appended: $IncidentId" -ForegroundColor Green
                }
            } catch {
                Write-Warning "Attempt $attempts failed: $_"
                Start-Sleep -Milliseconds 200
            } finally {
                if ($mutex) { $mutex.ReleaseMutex() | Out-Null }
            }
        }

        if (-not $written) { throw "Failed to append incident after $maxAttempts attempts" }

        if ($PassThru) { return [PSCustomObject]$record }
    }
}

