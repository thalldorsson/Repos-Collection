function Test-FinOpsAzBillingAccounts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token,
        [switch]$IncludeData,
        [switch]$BypassCache,
        [int]$CacheTTL = 3600
    )
    $apiVersion = '2019-10-01-preview'
    $uri = "https://management.azure.com/providers/Microsoft.Billing/billingAccounts?api-version=$apiVersion"
    
    # Create cache key based on token hash
    $tokenHash = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Token))).Replace('-','')
    $cacheKey = "azbillingaccounts-$($tokenHash.Substring(0,16))"
    
    # Check cache unless bypassed
    if (-not $BypassCache) {
        Write-Verbose "Checking cache for billing accounts (TTL: $CacheTTL seconds)"
        
        if ($script:FinOpsCache -and $script:FinOpsCache.ContainsKey($cacheKey)) {
            $cacheEntry = $script:FinOpsCache[$cacheKey]
            $age = (Get-Date) - $cacheEntry.Timestamp
            
            if ($age.TotalSeconds -lt $CacheTTL) {
                Write-Verbose "Cache hit for billing accounts (age: $([int]$age.TotalSeconds)s)"
                return $cacheEntry.Value
            } else {
                Write-Verbose "Cache expired for billing accounts"
            }
        } else {
            Write-Verbose "Cache miss for billing accounts - fetching from API"
        }
    } else {
        Write-Verbose "Cache bypassed - fetching fresh data"
    }
    try {
        $data = Invoke-FinOpsAzureGet -Uri $uri -Token $Token
        $accounts = @()
        $current = $data
        while ($current) {
            if ($current.value) { $accounts += $current.value }
            $next = $current.nextLink
            if (-not $next) { break }
            $current = Invoke-FinOpsAzureGet -Uri $next -Token $Token
        }
        if (-not $accounts) { return New-FinOpsCheckResult -Name 'BillingAccounts' -Success $false -ErrorDetail 'No billing accounts returned' -ApiVersion $apiVersion }
        $metrics = @{ Count = $accounts.Count }
        $payload = if ($IncludeData) { $accounts } else { $accounts | Select-Object -First 3 -Property name, displayName }
        $result = New-FinOpsCheckResult -Name 'BillingAccounts' -Success $true -Data $payload -Metrics $metrics -ApiVersion $apiVersion
        
        # Cache the result
        if (-not $BypassCache) {
            Write-Verbose "Caching billing accounts result for $CacheTTL seconds"
            $capturedResult = $result
            $null = Get-FinOpsCachedValue -Key $cacheKey -TTLSeconds $CacheTTL -ScriptBlock { $capturedResult }
        }
        
        return $result
    }
    catch {
        New-FinOpsCheckResult -Name 'BillingAccounts' -Success $false -ErrorDetail $_.Exception.Message -ApiVersion $apiVersion
    }
}
