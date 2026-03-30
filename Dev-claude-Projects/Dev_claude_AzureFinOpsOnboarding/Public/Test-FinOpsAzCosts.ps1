function Test-FinOpsAzCosts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$StartDate,
        [Parameter(Mandatory)][string]$EndDate,
        [int]$Top = 5
    )
    $apiVersion = '2024-08-01'
    $filter = "properties/usageStart ge '$StartDate' and properties/usageEnd lt '$EndDate'"
    $encodedFilter = [System.Web.HttpUtility]::UrlEncode($filter)
    $uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Consumption/usageDetails?api-version=$apiVersion&$filter=$encodedFilter&$top=$Top"
    try {
        $data = Invoke-FinOpsAzureGet -Uri $uri -Token $Token
        $items = $data.value
        $metrics = @{ Count = ($items | Measure-Object).Count }
        if (-not $items) { return New-FinOpsCheckResult -Name 'Costs' -Success $false -ErrorDetail 'No usage details returned' -ApiVersion $apiVersion }
        # Return only a minimal projection to avoid large payloads
        $sample = $items | Select-Object -First 3 -Property id, name, @{n = 'usageStart'; e = { $_.properties.usageStart } }, @{n = 'cost'; e = { $_.properties.pretaxCost } }
        New-FinOpsCheckResult -Name 'Costs' -Success $true -Data $sample -Metrics $metrics -ApiVersion $apiVersion
    }
    catch {
        New-FinOpsCheckResult -Name 'Costs' -Success $false -ErrorDetail $_.Exception.Message -ApiVersion $apiVersion
    }
}
