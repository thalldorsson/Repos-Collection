function Get-PhishIRIncidentRecord {
    <#
    .SYNOPSIS
    Retrieve and filter stored PhishIR incident records from the JSONL incident store.

    .DESCRIPTION
    Reads newline-delimited JSON incident records from the incident store file (default
    PhishIR/IncidentStore/incidents.jsonl) and applies client-side filtering. Supports
    filtering by IncidentId, Type, Severity, Status, Date range, URL contents, Tags,
    and tenant information.

    Provides summary statistics view or full detail view. Designed for audit reporting,
    post-incident analysis, and multi-tenant oversight.

    .PARAMETER IncidentId
    Filter to a specific incident ID (exact match).

    .PARAMETER IncidentType
    Filter by incident type (exact or partial with -Like).

    .PARAMETER Severity
    Filter by severity (Low, Medium, High, Critical).

    .PARAMETER Status
    Filter by status (Detected, Investigating, Contained, Eradicated, Closed).

    .PARAMETER UrlContains
    Return incidents where any ExtractedUrls contains the provided substring.

    .PARAMETER Tag
    Return incidents containing all specified tags.

    .PARAMETER TenantId
    Return incidents involving the specified tenant GUID.

    .PARAMETER Since
    Only return incidents with TimestampUtc >= this date/time.

    .PARAMETER Until
    Only return incidents with TimestampUtc <= this date/time.

    .PARAMETER StorePath
    Override path to incident store file.

    .PARAMETER Summary
    Return aggregated summary statistics by Type/Severity/Status.

    .EXAMPLE
    Get-PhishIRIncidentRecord -Severity High -Since (Get-Date).AddDays(-7)

    Return high severity incidents from last 7 days.

    .EXAMPLE
    Get-PhishIRIncidentRecord -UrlContains "linodeobjects.com" -Summary

    Summary of incidents containing URLs referencing linodeobjects.com.

    .EXAMPLE
    Get-PhishIRIncidentRecord -Tag Phishing,Excel -Status Contained

    Return contained Excel phishing incidents tagged as phishing.

    .EXAMPLE
    Get-PhishIRIncidentRecord -TenantId "11111111-2222-3333-4444-555555555555" -Since "2025-01-01"

    Incidents affecting a specific tenant since start of year.

    .LINK
    Add-PhishIRIncidentRecord
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$IncidentId,
        [Parameter()]
        [string]$IncidentType,
        [Parameter()]
        [ValidateSet('Low','Medium','High','Critical')]
        [string]$Severity,
        [Parameter()]
        [ValidateSet('Detected','Investigating','Contained','Eradicated','Closed')]
        [string]$Status,
        [Parameter()]
        [string]$UrlContains,
        [Parameter()]
        [string[]]$Tag,
        [Parameter()]
        [Guid]$TenantId,
        [Parameter()]
        [DateTime]$Since,
        [Parameter()]
        [DateTime]$Until,
        [Parameter()]
        [string]$StorePath,
        [Parameter()]
        [switch]$Summary
    )

    begin {
        if (-not $StorePath) {
            try {
                $StorePath = Get-PhishIRStoragePath -PathType IncidentStore
            } catch {
                # Fallback to legacy path if config helpers not available
                $moduleRoot = Split-Path -Parent $MyInvocation.MyCommand.Module.Path
                $StorePath = Join-Path (Join-Path $moduleRoot 'IncidentStore') 'incidents.jsonl'
            }
        }
        if (-not (Test-Path $StorePath)) {
            Write-Warning "Incident store not found: $StorePath"
            return
        }

        $rawLines = Get-Content -Path $StorePath -ErrorAction Stop | Where-Object { $_.Trim() -ne '' }
        $records = @()
        foreach ($line in $rawLines) {
            try {
                $obj = $line | ConvertFrom-Json -ErrorAction Stop
                $records += $obj
            } catch {
                Write-Warning "Skipping malformed line: $line"
            }
        }
    }

    process {
        $filtered = $records

        if ($IncidentId) { $filtered = $filtered | Where-Object { $_.IncidentId -eq $IncidentId } }
        if ($IncidentType) { $filtered = $filtered | Where-Object { $_.Type -like $IncidentType } }
        if ($Severity) { $filtered = $filtered | Where-Object { $_.Severity -eq $Severity } }
        if ($Status) { $filtered = $filtered | Where-Object { $_.Status -eq $Status } }
        if ($UrlContains) { $filtered = $filtered | Where-Object { $_.ExtractedUrls -and ($_.ExtractedUrls | Where-Object { $_ -like "*${UrlContains}*" }) } }
        if ($Tag) { $filtered = $filtered | Where-Object { $_.Tags -and (@(Compare-Object -ReferenceObject $Tag -DifferenceObject $_.Tags -IncludeEqual | Where-Object { $_.SideIndicator -eq '==' }).Count -eq $Tag.Count) } }
        if ($TenantId) { $filtered = $filtered | Where-Object { $_.Tenants -and ($_.Tenants | Where-Object { $_.TenantId -eq $TenantId.Guid }) } }
        if ($Since) { $filtered = $filtered | Where-Object { [DateTime]$_.TimestampUtc -ge $Since.ToUniversalTime() } }
        if ($Until) { $filtered = $filtered | Where-Object { [DateTime]$_.TimestampUtc -le $Until.ToUniversalTime() } }

        if ($Summary) {
            $count = $filtered.Count
            Write-Host "Total incidents: $count" -ForegroundColor Green
            $byType = $filtered | Group-Object Type | Sort-Object Count -Descending
            $bySeverity = $filtered | Group-Object Severity | Sort-Object Count -Descending
            $byStatus = $filtered | Group-Object Status | Sort-Object Count -Descending

            [PSCustomObject]@{
                Total     = $count
                ByType    = ($byType | ForEach-Object { "${($_.Name)}=${($_.Count)}" }) -join '; '
                BySeverity= ($bySeverity | ForEach-Object { "${($_.Name)}=${($_.Count)}" }) -join '; '
                ByStatus  = ($byStatus | ForEach-Object { "${($_.Name)}=${($_.Count)}" }) -join '; '
            }
        } else {
            $filtered | ForEach-Object {
                [PSCustomObject]@{
                    IncidentId    = $_.IncidentId
                    TimestampUtc  = $_.TimestampUtc
                    Type          = $_.Type
                    Severity      = $_.Severity
                    Status        = $_.Status
                    UrlCount      = ($_.ExtractedUrls | Measure-Object).Count
                    SourceCount   = ($_.SourceFiles | Measure-Object).Count
                    Actions       = $_.Actions
                    Tenants       = $_.Tenants
                    ApprovedBy    = $_.ApprovedBy
                    Tags          = $_.Tags
                }
            }
        }
    }
}
