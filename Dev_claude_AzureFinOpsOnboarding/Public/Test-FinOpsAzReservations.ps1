function Test-FinOpsAzReservations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token
    )
    $apiVersion = '2022-11-01'
    $uri = "https://management.azure.com/providers/Microsoft.Capacity/reservations?api-version=$apiVersion&$take=1"
    try {
        $data = Invoke-FinOpsAzureGet -Uri $uri -Token $Token
        $count = if ($data.value) { $data.value.Count } else { 0 }
        if ($count -gt 0) {
            New-FinOpsCheckResult -Name 'Reservations' -Success $true -Metrics @{ SampleCount = $count } -ApiVersion $apiVersion
        } else {
            New-FinOpsCheckResult -Name 'Reservations' -Success $false -ErrorDetail 'No reservations visible (might be none or missing permissions)' -ApiVersion $apiVersion
        }
    }
    catch {
        New-FinOpsCheckResult -Name 'Reservations' -Success $false -ErrorDetail $_.Exception.Message -ApiVersion $apiVersion
    }
}
