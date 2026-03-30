function Get-PhishIRMailboxTargets {
    <#
    .SYNOPSIS
    Resolve mailbox targets for a tenant using include lists, groups, CSV files, and Graph query filters.
    .DESCRIPTION
    Given a tenant object (from Get-PhishIRTenantConfig), returns the final resolved mailbox list after
    applying expansions (groups, csv, query) and exclusions. Provides telemetry summary.
    
    Supports advanced Microsoft Graph OData filter queries for dynamic mailbox selection:
    - accountEnabled eq true
    - userType eq 'Member'
    - startsWith(userPrincipalName,'user')
    - department eq 'Finance'
    - Complex filters with 'and', 'or' operators
    
    .PARAMETER Tenant
    Tenant object from tenant configuration.
    .PARAMETER IncludeDisabled
    Include accounts that may be disabled (requires Graph query expansion capture). If not specified disabled accounts filtered.
    .PARAMETER GraphFilter
    Override Graph query filter. If specified, uses this instead of tenant targeting query.
    .PARAMETER PageSize
    Number of results per page for Graph queries (default: 999, max: 999).
    .OUTPUTS
    PSCustomObject with ResolvedMailboxes, SourceBreakdown, and QueryMetrics.
    .EXAMPLE
    $config = Get-PhishIRTenantConfig -Validate
    Get-PhishIRMailboxTargets -Tenant $config.tenants[0]
    
    .EXAMPLE
    Get-PhishIRMailboxTargets -Tenant $tenant -GraphFilter "department eq 'Finance' and accountEnabled eq true"
    
    Use custom Graph filter to target specific department.
    
    .EXAMPLE
    Get-PhishIRMailboxTargets -Tenant $tenant -IncludeDisabled -PageSize 500
    
    Include disabled accounts with custom page size for large result sets.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Tenant,
        [Parameter()][switch]$IncludeDisabled,
        [Parameter()][string]$GraphFilter,
        [Parameter()][ValidateRange(1, 999)][int]$PageSize = 999
    )
    
    $sources = [ordered]@{
        Explicit = @(); Groups = @(); Csv = @(); Graph = @(); Excluded = @()
    }
    $mailboxes = @()
    $queryMetrics = @{
        GraphQueryExecuted = $false
        GraphResultCount = 0
        GraphPagesRetrieved = 0
        GraphQueryDurationMs = 0
    }

    # Use already resolved mailboxes if available
    if ($Tenant.resolvedMailboxes -and -not $GraphFilter) {
        # Already resolved by loader; reconstruct source counts using targeting hints
        if ($Tenant.targeting.includeMailboxes) { $sources.Explicit += $Tenant.targeting.includeMailboxes }
        if ($Tenant.targeting.groups) { $sources.Groups += $Tenant.targeting.groups }
        if ($Tenant.targeting.csvPath) { if (Test-Path $Tenant.targeting.csvPath) { $sources.Csv += '<csvFile>' } }
        if ($Tenant.targeting.query) { $sources.Graph += $Tenant.targeting.query }
        $mailboxes += $Tenant.resolvedMailboxes
    } else {
        # Perform fresh resolution with enhanced Graph query support
        
        # 1. Include explicit mailboxes
        if ($Tenant.targeting.includeMailboxes) { 
            $sources.Explicit = $Tenant.targeting.includeMailboxes
            $mailboxes += $Tenant.targeting.includeMailboxes 
        }

        # 2. Groups (mail-enabled) - requires Exchange Online connection
        if ($Tenant.targeting.groups) {
            foreach ($g in $Tenant.targeting.groups) {
                if (Get-Command Get-DistributionGroupMember -ErrorAction SilentlyContinue) {
                    try {
                        $members = Get-DistributionGroupMember -Identity $g -ErrorAction Stop | Select-Object -ExpandProperty PrimarySmtpAddress
                        if ($members) { 
                            $sources.Groups += $members
                            $mailboxes += $members 
                        }
                    } catch { 
                        Write-Warning "Failed to resolve group '$g': $($_.Exception.Message)" 
                    }
                } else {
                    Write-Warning "Group resolution skipped (Get-DistributionGroupMember not available)."
                }
            }
        }

        # 3. CSV Path
        if ($Tenant.targeting.csvPath -and (Test-Path $Tenant.targeting.csvPath)) {
            try {
                $csv = Import-Csv -Path $Tenant.targeting.csvPath
                # Assume first column or 'Mailbox' column
                $col = if ($csv[0].PSObject.Properties.Name -contains 'Mailbox') { 'Mailbox' } else { $csv[0].PSObject.Properties[0].Name }
                $csvMailboxes = $csv | Select-Object -ExpandProperty $col
                $sources.Csv = $csvMailboxes
                $mailboxes += $csvMailboxes
            } catch { 
                Write-Warning "Failed to import CSV '$($Tenant.targeting.csvPath)': $($_.Exception.Message)" 
            }
        }

        # 4. Graph Query Filter expansion with paging support
        $effectiveFilter = if ($GraphFilter) { $GraphFilter } else { $Tenant.targeting.query }
        
        if ($effectiveFilter) {
            if (Get-Command Get-MgUser -ErrorAction SilentlyContinue) {
                try {
                    # Ensure Graph connection
                    if (-not (Get-MgContext)) {
                        try { 
                            Write-Verbose "Connecting to Microsoft Graph..."
                            Connect-MgGraph -Scopes 'User.Read.All' -ErrorAction Stop | Out-Null 
                        } catch { 
                            Write-Warning 'Connect-MgGraph failed; continuing without query expansion.' 
                        }
                    }
                    
                    if (Get-MgContext) {
                        # Execute Graph query with paging support
                        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                        $queryMetrics.GraphQueryExecuted = $true
                        
                        Write-Verbose "Executing Graph query: $effectiveFilter"
                        
                        # Build Graph query parameters
                        $graphParams = @{
                            Filter = $effectiveFilter
                            All = $true
                            Property = 'UserPrincipalName', 'AccountEnabled', 'UserType'
                            PageSize = $PageSize
                            ErrorAction = 'Stop'
                        }
                        
                        # Execute query
                        $graphUsers = Get-MgUser @graphParams
                        
                        # Filter disabled accounts if needed
                        if (-not $IncludeDisabled) {
                            $graphUsers = $graphUsers | Where-Object { $_.AccountEnabled -eq $true }
                        }
                        
                        $graphMailboxes = $graphUsers | Select-Object -ExpandProperty UserPrincipalName
                        
                        $stopwatch.Stop()
                        $queryMetrics.GraphQueryDurationMs = [int]$stopwatch.ElapsedMilliseconds
                        $queryMetrics.GraphResultCount = $graphMailboxes.Count
                        $queryMetrics.GraphPagesRetrieved = [Math]::Ceiling($graphMailboxes.Count / $PageSize)
                        
                        if ($graphMailboxes) { 
                            $sources.Graph = $graphMailboxes
                            $mailboxes += $graphMailboxes 
                        }
                        
                        Write-Verbose "Graph query completed: $($graphMailboxes.Count) mailboxes in $($queryMetrics.GraphQueryDurationMs)ms"
                    }
                } catch { 
                    Write-Warning "Graph query expansion failed for tenant '$($Tenant.displayName)': $($_.Exception.Message)" 
                }
            } else {
                Write-Warning "Microsoft Graph module not available - skipping query expansion for tenant '$($Tenant.displayName)'"
            }
        }

        # Deduplicate
        $mailboxes = $mailboxes | Sort-Object -Unique
    }

    # Apply exclusions
    if ($Tenant.targeting.excludeMailboxes) { 
        $sources.Excluded = $Tenant.targeting.excludeMailboxes
        $mailboxes = $mailboxes | Where-Object { $_ -notin $Tenant.targeting.excludeMailboxes } 
    }

    $result = [PSCustomObject]@{
        TenantDisplayName = $Tenant.displayName
        TenantId = $Tenant.tenantId
        Total = if ($mailboxes) { @($mailboxes).Count } else { 0 }
        ResolvedMailboxes = $mailboxes
        SourceBreakdown = [PSCustomObject]@{
            Explicit = if ($sources.Explicit) { @($sources.Explicit).Count } else { 0 }
            Groups = if ($sources.Groups) { @($sources.Groups).Count } else { 0 }
            Csv = if ($sources.Csv) { @($sources.Csv).Count } else { 0 }
            GraphQuery = if ($sources.Graph) { @($sources.Graph).Count } else { 0 }
            Excluded = if ($sources.Excluded) { @($sources.Excluded).Count } else { 0 }
        }
        QueryMetrics = [PSCustomObject]$queryMetrics
    }
    
    # Record telemetry if available
    if ($queryMetrics.GraphQueryExecuted -and (Get-Command Send-PhishIRMetric -ErrorAction SilentlyContinue)) {
        try {
            Send-PhishIRMetric -MetricName 'mailbox.query.executed' -Value 1 -Tags @{ 
                TenantId = $Tenant.tenantId
                ResultCount = $queryMetrics.GraphResultCount
            }
            Send-PhishIRMetric -MetricName 'mailbox.query.duration' -Value $queryMetrics.GraphQueryDurationMs -Unit 'milliseconds' -Tags @{ 
                TenantId = $Tenant.tenantId
            }
        } catch {
            Write-Verbose "Failed to record metrics: $($_.Exception.Message)"
        }
    }
    
    return $result
}

Export-ModuleMember -Function Get-PhishIRMailboxTargets
