function Resolve-FinOpsOutputPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseDirectory,
        [Parameter(Mandatory)][string]$CustomerName
    )
    if (-not (Test-Path -Path $BaseDirectory)) { New-Item -ItemType Directory -Path $BaseDirectory -Force | Out-Null }
    $safe = ($CustomerName -replace '\W', '')
    $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $root = Join-Path $BaseDirectory "$safe-$timestamp"
    [pscustomobject]@{
        Json = $root + '.json'
        Markdown = $root + '.md'
    }
}
