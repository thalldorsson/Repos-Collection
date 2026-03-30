function Test-FinOpsAzSubscriptions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token,
        [switch]$IncludeData
    )
    $apiVersion = '2022-12-01'
    $uri = "https://management.azure.com/subscriptions?api-version=$apiVersion"
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
        New-FinOpsCheckResult -Name 'Subscriptions' -Success $true -Data $payload -Metrics $metrics -ApiVersion $apiVersion
    }
    catch {
        New-FinOpsCheckResult -Name 'Subscriptions' -Success $false -ErrorDetail $_.Exception.Message -ApiVersion $apiVersion
    }
}
