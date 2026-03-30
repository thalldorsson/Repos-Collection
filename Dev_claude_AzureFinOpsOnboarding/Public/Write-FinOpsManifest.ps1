function Write-FinOpsManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$OrchestratorObject
    )
    $json = $OrchestratorObject | ConvertTo-Json -Depth 8
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json | Out-File -FilePath $Path -Encoding utf8
    Write-Verbose "Manifest written: $Path"
    return $Path
}
