function Get-FinOpsSecretExpiryKey {
    [CmdletBinding()]
    param(
        [int]$YearsAhead = 2
    )
    (Get-Date).AddYears($YearsAhead).ToString('yyyyMMdd')
}
