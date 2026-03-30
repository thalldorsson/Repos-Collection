function Invoke-FinOpsAzureGet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Token
    )
    $headers = @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' }
    try {
        Invoke-RestMethod -Uri $Uri -Headers $headers -Method Get -ErrorAction Stop
    }
    catch {
        throw [System.Exception]::new("GET failed: $Uri", $_.Exception)
    }
}
