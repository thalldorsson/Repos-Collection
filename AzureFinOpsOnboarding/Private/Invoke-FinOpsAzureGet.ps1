function Invoke-FinOpsAzureGet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory=$false)][int]$MaxRetries = 3,
        [Parameter(Mandatory=$false)][int]$InitialDelaySeconds = 2
    )
    $headers = @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' }
    try {
        Invoke-FinOpsRestMethodWithRetry -Uri $Uri -Method Get -Headers $headers `
            -MaxRetries $MaxRetries -InitialDelaySeconds $InitialDelaySeconds -ErrorAction Stop
    }
    catch {
        throw [System.Exception]::new("GET failed: $Uri", $_.Exception)
    }
}
