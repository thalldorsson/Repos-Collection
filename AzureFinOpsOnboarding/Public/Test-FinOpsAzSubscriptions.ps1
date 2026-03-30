function Test-FinOpsAzSubscriptions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token,
        [switch]$IncludeData,
        [switch]$BypassCache,
        [int]$CacheTTL = 3600
    )
    $apiVersion = '2022-12-01'
    $uri = "https://management.azure.com/subscriptions?api-version=$apiVersion"
    
    # Create cache key based on token hash (to support multi-tenant scenarios)
    $tokenHash = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Token))).Replace('-','')
    $cacheKey = "azsubscriptions-$($tokenHash.Substring(0,16))"
    
    # Check cache unless bypassed
    if (-not $BypassCache) {
        Write-Verbose "Checking cache for subscriptions (TTL: $CacheTTL seconds)"
        
        # Check if cache entry exists and is not expired
        if ($script:FinOpsCache -and $script:FinOpsCache.ContainsKey($cacheKey)) {
            $cacheEntry = $script:FinOpsCache[$cacheKey]
            $age = (Get-Date) - $cacheEntry.Timestamp
            
            if ($age.TotalSeconds -lt $TTLSeconds) {
                Write-Verbose "Cache hit for subscriptions (age: $([int]$age.TotalSeconds)s)"
                return $cacheEntry.Value
            } else {
                Write-Verbose "Cache expired for subscriptions (age: $([int]$age.TotalSeconds)s, TTL: $TTLSeconds s)"
            }
        } else {
            Write-Verbose "Cache miss for subscriptions - fetching from API"
        }
    } else {
        Write-Verbose "Cache bypassed - fetching fresh data"
    }
    try {
        $data = Invoke-FinOpsAzureGet -Uri $uri -Token $Token
        $subs = @()
        $current = $data
        while ($current) {
            if ($current.value) { $subs += $current.value }
            $next = $current.nextLink
            if (-not $next) { break }
            $current = Invoke-FinOpsAzureGet -Uri $next -Token $Token
        }
        if (-not $subs) { return New-FinOpsCheckResult -Name 'Subscriptions' -Success $false -ErrorDetail 'No subscriptions returned' -ApiVersion $apiVersion }
        $metrics = @{ Count = $subs.Count }
        $payload = if ($IncludeData) { $subs } else { $null }
        $result = New-FinOpsCheckResult -Name 'Subscriptions' -Success $true -Data $payload -Metrics $metrics -ApiVersion $apiVersion
        
        # Cache the result
        if (-not $BypassCache) {
            Write-Verbose "Caching subscriptions result for $CacheTTL seconds"
            $capturedResult = $result
            $null = Get-FinOpsCachedValue -Key $cacheKey -TTLSeconds $CacheTTL -ScriptBlock { $capturedResult }
        }
        
        return $result
    }
    catch {
        New-FinOpsCheckResult -Name 'Subscriptions' -Success $false -ErrorDetail $_.Exception.Message -ApiVersion $apiVersion
    }
}
