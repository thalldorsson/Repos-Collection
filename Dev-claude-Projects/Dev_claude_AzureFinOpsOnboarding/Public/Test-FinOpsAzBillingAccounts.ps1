function Test-FinOpsAzBillingAccounts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token,
        [switch]$IncludeData
    )
    $apiVersion = '2019-10-01-preview'
    $uri = "https://management.azure.com/providers/Microsoft.Billing/billingAccounts?api-version=$apiVersion"
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
        New-FinOpsCheckResult -Name 'BillingAccounts' -Success $true -Data $payload -Metrics $metrics -ApiVersion $apiVersion
    }
    catch {
        New-FinOpsCheckResult -Name 'BillingAccounts' -Success $false -ErrorDetail $_.Exception.Message -ApiVersion $apiVersion
    }
}
