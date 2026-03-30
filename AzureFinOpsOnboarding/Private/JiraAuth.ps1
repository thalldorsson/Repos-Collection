# Internal Jira auth helpers and cached credential storage
# Script-level suppression for ConvertTo-SecureString usage
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Environment variable needs to be converted to SecureString for secure internal storage')]
param()

if (-not $script:AfoJiraUsername -and $env:AFO_JIRA_USERNAME) { $script:AfoJiraUsername = $env:AFO_JIRA_USERNAME }
if (-not $script:AfoJiraApiToken -and $env:AFO_JIRA_APITOKEN) {
    try {
        # Converting environment variable to SecureString - this is required for secure credential storage
        $script:AfoJiraApiToken = ConvertTo-SecureString -String $env:AFO_JIRA_APITOKEN -AsPlainText -Force
    }
    catch {
        Write-Warning "Failed to convert AFO_JIRA_APITOKEN environment variable to SecureString: $_"
    }
}

function New-FinOpsJiraAuthorizationHeaderInternal {
    # Internal function that returns a string value, does not change system state
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Function returns a string and does not modify system state')]
    param([string]$Username, [SecureString]$ApiToken)
    if ([string]::IsNullOrWhiteSpace($Username) -or -not $ApiToken) { return $null }
    try {
        $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ApiToken)
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally { if ($ptr) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) } }
    $userBytes = [System.Text.Encoding]::UTF8.GetBytes($Username)
    $colonByte = @(58) # ':'
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($plain)
    $bytes = New-Object byte[] ($userBytes.Length + 1 + $plainBytes.Length)
    [Array]::Copy($userBytes, 0, $bytes, 0, $userBytes.Length)
    [Array]::Copy($colonByte, 0, $bytes, $userBytes.Length, 1)
    [Array]::Copy($plainBytes, 0, $bytes, $userBytes.Length + 1, $plainBytes.Length)
    'Basic ' + [Convert]::ToBase64String($bytes)
}
function Get-FinOpsEffectiveJiraAuthInternal {
    param(
        [string]$Username,
        [SecureString]$ApiToken,
        [string]$AuthorizationHeader
    )
    if ($AuthorizationHeader) {
        # If user supplied explicit header we still allow Username/Token fallback for display only.
        $resolvedUser = if ($Username) { $Username } elseif ($script:AfoJiraUsername) { $script:AfoJiraUsername } else { $null }
        return [pscustomobject]@{ Username = $resolvedUser; ApiToken = $ApiToken; AuthorizationHeader = $AuthorizationHeader; FromCache = $false }
    }
    $u = if ($Username) { $Username } elseif ($script:AfoJiraUsername) { $script:AfoJiraUsername } else { $null }
    $t = if ($ApiToken) { $ApiToken } elseif ($script:AfoJiraApiToken) { $script:AfoJiraApiToken } else { $null }
    if (-not $u -or -not $t) { throw "Jira credentials not set. Provide -Username and -ApiToken or run Set-FinOpsJiraCredential first." }
    $hdr = New-FinOpsJiraAuthorizationHeaderInternal -Username $u -ApiToken $t
    [pscustomobject]@{ Username = $u; ApiToken = $t; AuthorizationHeader = $hdr; FromCache = -not $Username -and -not $ApiToken }
}
