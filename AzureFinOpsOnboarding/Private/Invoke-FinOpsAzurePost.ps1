function Invoke-FinOpsAzurePost {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)]$Body,
        [Parameter(Mandatory=$false)][int]$MaxRetries = 3,
        [Parameter(Mandatory=$false)][int]$InitialDelaySeconds = 2
    )
    $headers = @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' }
    $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 6 }
    try {
        Invoke-FinOpsRestMethodWithRetry -Uri $Uri -Method Post -Headers $headers -Body $json `
            -ContentType 'application/json' -MaxRetries $MaxRetries -InitialDelaySeconds $InitialDelaySeconds -ErrorAction Stop
    }
    catch {
        throw [System.Exception]::new("POST failed: $Uri", $_.Exception)
    }
}
