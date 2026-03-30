function Get-FinOpsPowerBIWorkspace {
    <#
    .SYNOPSIS
        Retrieves Power BI workspace information.

    .DESCRIPTION
        Gets workspace details by ID or lists all accessible workspaces. Supports both
        direct API calls and MCP delegate pattern for AI agent integration.

    .PARAMETER WorkspaceId
        GUID of the workspace to retrieve. If omitted, lists all accessible workspaces.

    .PARAMETER Filter
        Optional filter string for workspace names (when listing all).

    .PARAMETER UsePowerBIMcp
        Use registered MCP delegates instead of direct Power BI API calls.

    .EXAMPLE
        Get-FinOpsPowerBIWorkspace -WorkspaceId "11111111-1111-1111-1111-111111111111"

    .EXAMPLE
        Get-FinOpsPowerBIWorkspace -Filter "FinOps"

    .EXAMPLE
        Get-FinOpsPowerBIWorkspace -UsePowerBIMcp
    #>
    [CmdletBinding()]
    param(
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string]$WorkspaceId,
        
        [string]$Filter,
        [switch]$UsePowerBIMcp,
        [switch]$BypassCache,
        [int]$CacheTTL = 1800
    )

    # Create cache key
    $cacheKey = if ($WorkspaceId) {
        "pbiworkspace-$WorkspaceId"
    } elseif ($Filter) {
        "pbiworkspaces-filter-$Filter"
    } else {
        "pbiworkspaces-all"
    }
    
    # Check cache unless bypassed
    if (-not $BypassCache) {
        Write-Verbose "Checking cache for Power BI workspace (TTL: $CacheTTL seconds)"
        
        if ($script:FinOpsCache -and $script:FinOpsCache.ContainsKey($cacheKey)) {
            $cacheEntry = $script:FinOpsCache[$cacheKey]
            $age = (Get-Date) - $cacheEntry.Timestamp
            
            if ($age.TotalSeconds -lt $CacheTTL) {
                Write-Verbose "Cache hit for Power BI workspace (age: $([int]$age.TotalSeconds)s)"
                return $cacheEntry.Value
            } else {
                Write-Verbose "Cache expired for Power BI workspace"
            }
        } else {
            Write-Verbose "Cache miss for Power BI workspace - fetching from API"
        }
    } else {
        Write-Verbose "Cache bypassed - fetching fresh data"
    }
    
    try {
        if ($UsePowerBIMcp) {
            Write-Verbose "Retrieving workspace via Power BI MCP"
            
            $result = if ($WorkspaceId) {
                Invoke-FinOpsPowerBIMcp -Operation GetWorkspace -Arguments @{
                    WorkspaceId = $WorkspaceId
                }
            } else {
                $args = @{}
                if ($Filter) { $args.Filter = $Filter }
                Invoke-FinOpsPowerBIMcp -Operation GetWorkspaces -Arguments $args
            }
            
            # Cache the result
            if (-not $BypassCache -and $result) {
                Write-Verbose "Caching Power BI workspace result for $CacheTTL seconds"
                $capturedResult = $result
                $null = Get-FinOpsCachedValue -Key $cacheKey -TTLSeconds $CacheTTL -ScriptBlock { $capturedResult }
            }
            
            return $result
        } else {
            Write-Verbose "Retrieving workspace via Power BI API"
            
            if (-not (Get-Module -ListAvailable -Name MicrosoftPowerBIMgmt)) {
                Install-Module -Name MicrosoftPowerBIMgmt -Scope CurrentUser -Force -ErrorAction Stop
            }
            Import-Module MicrosoftPowerBIMgmt -ErrorAction Stop

            $token = $null
            try { $token = Get-PowerBIAccessToken -AsString -ErrorAction Stop } catch {}
            if (-not $token) {
                Connect-PowerBIServiceAccount -ErrorAction Stop | Out-Null
            }

            $result = if ($WorkspaceId) {
                Get-PowerBIWorkspace -Id $WorkspaceId -Scope Organization -ErrorAction Stop
            } else {
                $workspaces = Get-PowerBIWorkspace -Scope Organization -ErrorAction Stop
                if ($Filter) {
                    $workspaces | Where-Object { $_.Name -like "*$Filter*" }
                } else {
                    $workspaces
                }
            }
            
            # Cache the result
            if (-not $BypassCache -and $result) {
                Write-Verbose "Caching Power BI workspace result for $CacheTTL seconds"
                $capturedResult = $result
                $null = Get-FinOpsCachedValue -Key $cacheKey -TTLSeconds $CacheTTL -ScriptBlock { $capturedResult }
            }
            
            return $result
        }
    } catch {
        Write-Error "Failed to retrieve workspace: $_"
        return $null
    }
}
