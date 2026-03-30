Param(
    [int]$ThresholdKB = 100
)

$threshold = $ThresholdKB * 1KB
git ls-files | ForEach-Object {
    try {
        $item = Get-Item $_ -ErrorAction Stop
        if ($item.Length -gt $threshold) {
            "{0} {1}KB" -f $_, ([math]::Round($item.Length/1KB,1))
        }
    } catch {
        # ignore
    }
}
