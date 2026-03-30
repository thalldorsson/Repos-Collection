function New-FinOpsCheckResult {
    # Internal function that returns a PSCustomObject, does not change system state
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Function returns an object and does not modify system state')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Success,
        $Data = $null,
        $Metrics = $null,
        $ErrorDetail = $null,
        [string]$ApiVersion = ''
    )
    [pscustomobject]@{
        Name = $Name
        Success = $Success
        Error = $ErrorDetail
        Metrics = $Metrics
        Data = $Data
        ApiVersion = $ApiVersion
        Timestamp = (Get-Date).ToUniversalTime().ToString('o')
    }
}
