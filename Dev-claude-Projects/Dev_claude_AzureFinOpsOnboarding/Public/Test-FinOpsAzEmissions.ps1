function Test-FinOpsAzEmissions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string[]]$SubscriptionIds,
        [ValidateSet('Scope1', 'Scope2', 'Scope3')][string[]]$CarbonScopes = @('Scope1')
    )
    $apiVersion = '2023-04-01-preview'
    # Use a 90-60 day window similar to original script
    $startDate = (Get-Date).AddDays(-90).ToString('yyyy-MM-01')
    $endDate = (Get-Date).AddDays(-60).ToString('yyyy-MM-01')
    $uri = "https://management.azure.com/providers/Microsoft.Carbon/carbonEmissionReports?api-version=$apiVersion"
    $body = @{
        reportType = 'OverallSummaryReport'
        subscriptionList = $SubscriptionIds
        carbonScopeList = $CarbonScopes
        dateRange = @{ start = $startDate; end = $endDate }
    }
    try {
        Invoke-FinOpsAzurePost -Uri $uri -Token $Token -Body $body | Out-Null
        # Assume success if request accepted (no exception)
        New-FinOpsCheckResult -Name 'Emissions' -Success $true -Metrics @{ RequestedSubscriptions = $SubscriptionIds.Count } -ApiVersion $apiVersion
    }
    catch {
        New-FinOpsCheckResult -Name 'Emissions' -Success $false -ErrorDetail $_.Exception.Message -ApiVersion $apiVersion
    }
}
