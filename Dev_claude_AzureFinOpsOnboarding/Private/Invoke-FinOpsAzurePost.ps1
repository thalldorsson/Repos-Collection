function Invoke-FinOpsAzurePost {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)]$Body
    )
    $headers = @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' }
    $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 6 }
    try {
        Invoke-RestMethod -Uri $Uri -Headers $headers -Method Post -Body $json -ErrorAction Stop
    }
    catch {
        throw [System.Exception]::new("POST failed: $Uri", $_.Exception)
    }
}
