function Get-FinOpsCachedValue {
    <#
    .SYNOPSIS
        Retrieves or computes a cached value with TTL (Time To Live) expiration.
    
    .DESCRIPTION
        Provides a simple in-memory caching layer for expensive API calls.
        Cached values expire after a specified TTL (in seconds) and are automatically refreshed.
        Uses a script-level hashtable for storage across function calls within a session.
    
    .PARAMETER Key
        Unique cache key to identify the cached value.
    
    .PARAMETER ScriptBlock
        ScriptBlock to execute if the cache is empty or expired. The result is cached.
    
    .PARAMETER TTLSeconds
        Time to live in seconds. Default is 3600 (1 hour).
        After this duration, the cached value is considered stale and refreshed.
    
    .PARAMETER Force
        Forces cache refresh regardless of TTL status.
    
    .EXAMPLE
        $subscriptions = Get-FinOpsCachedValue -Key "azsubscriptions-$tenantId" -TTLSeconds 3600 -ScriptBlock {
            Get-AzSubscription -TenantId $tenantId
        }
    
    .EXAMPLE
        # Clear cache for a specific key
        Get-FinOpsCachedValue -Key "mykey" -Force -ScriptBlock { $null }
    
    .NOTES
        Cache is session-scoped (cleared when module is reloaded or PowerShell session ends).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Key,
        
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        
        [Parameter(Mandatory=$false)]
        [int]$TTLSeconds = 3600,
        
        [Parameter(Mandatory=$false)]
        [switch]$Force
    )
    
    # Initialize script-level cache hashtable if it doesn't exist
    if (-not $script:FinOpsCache) {
        $script:FinOpsCache = @{}
        Write-Verbose "[Get-FinOpsCachedValue] Initialized cache store"
    }
    
    $now = [datetime]::UtcNow
    $cacheEntry = $script:FinOpsCache[$Key]
    
    # Check if cache entry exists and is still valid
    $isCacheValid = $false
    if ($cacheEntry -and -not $Force) {
        $age = ($now - $cacheEntry.Timestamp).TotalSeconds
        $isCacheValid = $age -lt $TTLSeconds
        
        if ($isCacheValid) {
            Write-Verbose "[Get-FinOpsCachedValue] Cache HIT for key '$Key' (age: $([math]::Round($age, 1))s, TTL: ${TTLSeconds}s)"
            return $cacheEntry.Value
        } else {
            Write-Verbose "[Get-FinOpsCachedValue] Cache EXPIRED for key '$Key' (age: $([math]::Round($age, 1))s, TTL: ${TTLSeconds}s)"
        }
    } else {
        Write-Verbose "[Get-FinOpsCachedValue] Cache MISS for key '$Key' $(if ($Force) { '(forced refresh)' })"
    }
    
    # Execute scriptblock to get fresh value
    try {
        Write-Verbose "[Get-FinOpsCachedValue] Executing scriptblock for key '$Key'"
        $value = & $ScriptBlock
        
        # Store in cache
        $script:FinOpsCache[$Key] = @{
            Value = $value
            Timestamp = $now
            TTLSeconds = $TTLSeconds
        }
        
        Write-Verbose "[Get-FinOpsCachedValue] Cached value for key '$Key' (TTL: ${TTLSeconds}s)"
        return $value
    }
    catch {
        Write-Warning "[Get-FinOpsCachedValue] Failed to execute scriptblock for key '$Key': $($_.Exception.Message)"
        throw
    }
}

function Clear-FinOpsCache {
    <#
    .SYNOPSIS
        Clears the FinOps cache completely or for specific keys.
    
    .DESCRIPTION
        Removes cached values from the session cache. Useful for testing or forcing refresh.
    
    .PARAMETER Key
        Optional specific key to clear. If omitted, clears entire cache.
    
    .EXAMPLE
        Clear-FinOpsCache
    
    .EXAMPLE
        Clear-FinOpsCache -Key "azsubscriptions-tenant123"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$Key
    )
    
    if (-not $script:FinOpsCache) {
        Write-Verbose "[Clear-FinOpsCache] Cache does not exist"
        return
    }
    
    if ($Key) {
        if ($script:FinOpsCache.ContainsKey($Key)) {
            $script:FinOpsCache.Remove($Key)
            Write-Verbose "[Clear-FinOpsCache] Removed cache entry for key '$Key'"
        } else {
            Write-Verbose "[Clear-FinOpsCache] Key '$Key' not found in cache"
        }
    } else {
        $count = $script:FinOpsCache.Count
        $script:FinOpsCache.Clear()
        Write-Verbose "[Clear-FinOpsCache] Cleared all cache entries (removed $count items)"
    }
}

function Get-FinOpsCacheStats {
    <#
    .SYNOPSIS
        Returns statistics about the current cache state.
    
    .DESCRIPTION
        Provides insight into cache contents, including key names, ages, and TTLs.
    
    .EXAMPLE
        Get-FinOpsCacheStats | Format-Table
    
    .OUTPUTS
        Array of cache entry objects with Key, Age (seconds), TTL, and Expired status.
    #>
    [CmdletBinding()]
    param()
    
    if (-not $script:FinOpsCache -or $script:FinOpsCache.Count -eq 0) {
        Write-Verbose "[Get-FinOpsCacheStats] Cache is empty"
        return @()
    }
    
    $now = [datetime]::UtcNow
    $stats = foreach ($kvp in $script:FinOpsCache.GetEnumerator()) {
        $age = ($now - $kvp.Value.Timestamp).TotalSeconds
        $isExpired = $age -ge $kvp.Value.TTLSeconds
        
        [pscustomobject]@{
            Key = $kvp.Key
            AgeSeconds = [math]::Round($age, 1)
            TTLSeconds = $kvp.Value.TTLSeconds
            Expired = $isExpired
            Timestamp = $kvp.Value.Timestamp
        }
    }
    
    return $stats
}
