function Get-FinOpsCostDateWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$StartOffsetDays,
        [Parameter(Mandatory)][int]$EndOffsetDays
    )
    if ($StartOffsetDays -le $EndOffsetDays) { throw 'StartOffsetDays must be greater (further in the past) than EndOffsetDays' }
    $start = (Get-Date).AddDays(-1 * $StartOffsetDays).ToString('yyyy-MM-01')
    $end = (Get-Date).AddDays(-1 * $EndOffsetDays).ToString('yyyy-MM-01')
    [pscustomobject]@{ Start = $start; End = $end }
}
