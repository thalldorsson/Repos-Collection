function Get-PhishIRTenantConfig {
    <#
    .SYNOPSIS
    Load and validate multi-tenant configuration for PhishIR operations.

    .DESCRIPTION
    Reads a tenants JSON configuration file (default: samples/tenants.sample.json or tenants.json if present),
    performs lightweight validation of required fields, applies environment overrides, and returns a
    structured object for downstream mailbox targeting, reporting, and execution controls.

    Environment Overrides:
      PHISHIR_TENANTS_FILE  - Explicit path to tenants.json
      PHISHIR_OUTPUT_ROOT   - Override output.root for all tenants

    .PARAMETER Path
    Optional path to tenants configuration. If omitted, resolves in priority order:
      1. $env:PHISHIR_TENANTS_FILE
      2. tenants.json (repo root when not ignored)
      3. samples/tenants.sample.json

    .PARAMETER Validate
    Perform basic validation checks (required fields, non-empty tenants array). Throws on failure.

    .OUTPUTS
    PSCustomObject

    .EXAMPLE
    $cfg = Get-PhishIRTenantConfig -Validate
    $cfg.tenants | Select-Object displayName, tenantId

    .EXAMPLE
    $cfg = Get-PhishIRTenantConfig -Path 'c:/secure/tenants.json'

    .NOTES
    For production usage create a private tenants.json (gitignored) and keep sample file for reference.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Path,
        [Parameter()]
        [switch]$Validate
    )

    try {
        # Resolve path precedence
        if (-not $Path) {
            if ($env:PHISHIR_TENANTS_FILE) {
                $Path = $env:PHISHIR_TENANTS_FILE
            } else {
                $repoRoot = (Get-Item $PSScriptRoot).Parent.Parent.FullName
                $candidatePrimary = Join-Path $repoRoot 'tenants.json'
                $candidateSample  = Join-Path $repoRoot 'samples' 'tenants.sample.json'
                if (Test-Path $candidatePrimary) {
                    $Path = $candidatePrimary
                } else {
                    $Path = $candidateSample
                }
            }
        }

        if (-not (Test-Path $Path)) {
            throw "Tenant configuration file not found: $Path"
        }

        $raw = Get-Content -Path $Path -Raw -Encoding UTF8
        $config = $raw | ConvertFrom-Json

        # Basic validation
        if ($Validate) {
            if (-not $config.version) { throw 'Missing required top-level field: version' }
            if (-not $config.tenants) { throw 'Missing required top-level field: tenants' }
            if (-not ($config.tenants.Count -gt 0)) { throw 'Tenants array must contain at least one tenant' }
            foreach ($t in $config.tenants) {
                foreach ($required in 'displayName','tenantId','tenantDomain') {
                    if (-not $t.PSObject.Properties.Name -contains $required -or -not $t.$required) {
                        throw "Tenant missing required field: $required (displayName=$($t.displayName))"
                    }
                }
                if (-not $t.featureFlags) { throw "Tenant missing featureFlags block (displayName=$($t.displayName))" }
                if (-not ($t.featureFlags.PSObject.Properties.Name -contains 'whatIf')) { throw "Tenant featureFlags must include whatIf (displayName=$($t.displayName))" }
                if (-not $t.output) { throw "Tenant missing output block (displayName=$($t.displayName))" }
                foreach ($outReq in 'root','pathTemplate') { if (-not ($t.output.PSObject.Properties.Name -contains $outReq)) { throw "Tenant output missing $outReq (displayName=$($t.displayName))" } }
            }
        }

        # Apply environment output root override
        if ($env:PHISHIR_OUTPUT_ROOT) {
            foreach ($t in $config.tenants) {
                $t.output.root = $env:PHISHIR_OUTPUT_ROOT
            }
        } else {
            # Expand token syntax ${PHISHIR_OUTPUT_ROOT:-./out}
            foreach ($t in $config.tenants) {
                if ($t.output.root -match '\${PHISHIR_OUTPUT_ROOT:-([^}]+)}') {
                    $t.output.root = $Matches[1]
                }
            }
        }

        # Enrich with resolved mailbox list
        foreach ($t in $config.tenants) {
            $resolved = @()

            # 1. Include explicit mailboxes
            if ($t.targeting.includeMailboxes) { $resolved += $t.targeting.includeMailboxes }

            # 2. Groups (mail-enabled) - placeholder resolution (requires Exchange Online)
            if ($t.targeting.groups) {
                foreach ($g in $t.targeting.groups) {
                    if (Get-Command Get-DistributionGroupMember -ErrorAction SilentlyContinue) {
                        try {
                            $members = Get-DistributionGroupMember -Identity $g -ErrorAction Stop | Select-Object -ExpandProperty PrimarySmtpAddress
                            if ($members) { $resolved += $members }
                        } catch { Write-Warning "Failed to resolve group '$g': $($_.Exception.Message)" }
                    } else {
                        Write-Warning "Group resolution skipped (Get-DistributionGroupMember not available)."
                    }
                }
            }

            # 3. CSV Path
            if ($t.targeting.csvPath -and (Test-Path $t.targeting.csvPath)) {
                try {
                    $csv = Import-Csv -Path $t.targeting.csvPath
                    # Assume first column or 'Mailbox' column
                    $col = if ($csv[0].PSObject.Properties.Name -contains 'Mailbox') { 'Mailbox' } else { $csv[0].PSObject.Properties[0].Name }
                    $resolved += ($csv | Select-Object -ExpandProperty $col)
                } catch { Write-Warning "Failed to import CSV '$($t.targeting.csvPath)': $($_.Exception.Message)" }
            }

            # 4. Graph Query Filter expansion
            if ($t.targeting.query) {
                if (Get-Command Get-MgUser -ErrorAction SilentlyContinue) {
                    try {
                        # Attempt silent connection if not connected
                        if (-not (Get-MgContext)) {
                            try { Connect-MgGraph -Scopes 'User.Read.All' -ErrorAction Stop | Out-Null } catch { Write-Warning 'Connect-MgGraph failed; continuing without query expansion.' }
                        }
                        $graphUsers = Get-MgUser -Filter $t.targeting.query -All -Property UserPrincipalName -ErrorAction Stop | Select-Object -ExpandProperty UserPrincipalName
                        if ($graphUsers) { $resolved += $graphUsers }
                    } catch { Write-Warning "Graph query expansion failed for tenant '$($t.displayName)': $($_.Exception.Message)" }
                } else {
                    Write-Warning "Microsoft Graph module not available - skipping query expansion for tenant '$($t.displayName)'"
                }
            }

            # Deduplicate
            $resolved = $resolved | Sort-Object -Unique

            # Exclusions
            if ($t.targeting.excludeMailboxes) { $resolved = $resolved | Where-Object { $_ -notin $t.targeting.excludeMailboxes } }

            Add-Member -InputObject $t -NotePropertyName resolvedMailboxes -NotePropertyValue $resolved -Force

            # Capture base concurrency for adaptation
            if ($t.execution -and -not ($t.execution.PSObject.Properties.Name -contains 'baseConcurrency')) {
                Add-Member -InputObject $t.execution -NotePropertyName baseConcurrency -NotePropertyValue $t.execution.concurrency -Force
            }
        }

        # Basic approvals normalization
        foreach ($t in $config.tenants) {
            if ($t.approvals -and $t.approvals.requireApproval) {
                foreach ($p in 'hardDeletePhrase','purgePhrase') {
                    if (-not $t.approvals.$p) { Write-Warning "Tenant '$($t.displayName)' approvals missing $p" }
                }
            }
        }

        return $config
    } catch {
        Write-Error "Failed to load tenant configuration: $_"
        throw
    }
}

Export-ModuleMember -Function Get-PhishIRTenantConfig
