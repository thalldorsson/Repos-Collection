function Set-FinOpsAzKeyVaultSecret {
    <#
    .SYNOPSIS
        Creates or updates a secret in Azure Key Vault using direct REST calls (no Az modules required).

    .DESCRIPTION
        Acquires (or reuses) a bearer token scoped to https://vault.azure.net/.default and performs a PUT on the Key Vault secret data-plane endpoint.
        Implements simple retry logic for transient errors (HTTP 429 / 5xx). Secret value is never written to disk or echoed to output.

    .PARAMETER TenantId
        Azure AD Tenant (Directory) ID.

    .PARAMETER ApplicationId
        App registration (client) ID with at least "set" permission on the Key Vault (Data Plane: Secrets/Set).

    .PARAMETER ClientSecret
        Client secret for the app registration (SecureString).

    .PARAMETER VaultName
        Name of the target Key Vault (DNS prefix, not FQDN).

    .PARAMETER SecretName
        Name of the secret to create/update.

    .PARAMETER SecretValue
        The value to store (SecureString). Will be marshaled only in-memory for the REST call and cleared afterward.

    .PARAMETER ContentType
        Optional content type metadata for the secret.

    .PARAMETER Enabled
        Whether the secret should be enabled (default: $true).

    .PARAMETER ExpiryUtc
        Optional expiration DateTime (UTC) to set on the secret.

    .PARAMETER NotBeforeUtc
        Optional not-before DateTime (UTC).

    .PARAMETER Tags
        Hashtable of tags to attach.

    .PARAMETER Token
        Optional pre-fetched bearer token for https://vault.azure.net/.default. If not supplied, one will be requested.

    .OUTPUTS
        PSCustomObject with: Name, Vault, Success, StatusCode, Uri, Error (if any), Timestamp

    .EXAMPLE
        $result = Set-FinOpsAzKeyVaultSecret -TenantId $tid -ApplicationId $appId -ClientSecret $sec `
            -VaultName 'myvault' -SecretName 'FinOpsOnboardingSecret' -SecretValue $secretValue -Tags @{ purpose='finops-onboarding' }
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ApplicationId,
        [Parameter(Mandatory)][SecureString]$ClientSecret,
        [Parameter(Mandatory)][string]$VaultName,
        [Parameter(Mandatory)][string]$SecretName,
        [Parameter(Mandatory)][SecureString]$SecretValue,
        [string]$ContentType,
        [bool]$Enabled = $true,
        [DateTime]$ExpiryUtc,
        [DateTime]$NotBeforeUtc,
        [hashtable]$Tags,
        [string]$Token,
        [int]$MaxRetries = 3,
        [int]$InitialDelaySeconds = 2
    )

    if (-not $PSCmdlet.ShouldProcess("$VaultName/$SecretName", "Set Key Vault Secret")) {
        return
    }

    $scope = 'https://vault.azure.net/.default'
    if (-not $Token) {
        $Token = Get-FinOpsBearerToken -TenantId $TenantId -ApplicationId $ApplicationId -ClientSecret $ClientSecret -Scope $scope
    }

    $secPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecretValue)
    $plain = $null
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secPtr)
        $uri = "https://$VaultName.vault.azure.net/secrets/$SecretName?api-version=7.4"
        $body = @{ value = $plain }
        $attr = @{}
        if ($ContentType) { $body.contentType = $ContentType }
        $attr.enabled = $Enabled
        if ($ExpiryUtc) { $attr.exp = [int][double]::Parse(([DateTimeOffset]$ExpiryUtc).ToUnixTimeSeconds()) }
        if ($NotBeforeUtc) { $attr.nbf = [int][double]::Parse(([DateTimeOffset]$NotBeforeUtc).ToUnixTimeSeconds()) }
        if ($attr.Keys.Count -gt 0) { $body.attributes = $attr }
        if ($Tags) { $body.tags = $Tags }
        $json = $body | ConvertTo-Json -Depth 6

        $headers = @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' }

        try {
            Write-Verbose "PUT secret $VaultName/$SecretName"
            Invoke-FinOpsRestMethodWithRetry -Uri $uri -Method Put -Headers $headers -Body $json -ContentType 'application/json' -MaxRetries $MaxRetries -InitialDelaySeconds $InitialDelaySeconds -ErrorAction Stop | Out-Null
        }
        catch {
            $status = $_.Exception.Response.StatusCode.Value__ 2>$null
            return [pscustomobject]@{
                Name = $SecretName
                Vault = $VaultName
                Success = $false
                StatusCode = $status
                Uri = $uri
                Error = $_.Exception.Message
                Timestamp = (Get-Date).ToUniversalTime().ToString('o')
            }
        }

        [pscustomobject]@{
            Name = $SecretName
            Vault = $VaultName
            Success = $true
            StatusCode = 200
            Uri = $uri
            Error = $null
            Timestamp = (Get-Date).ToUniversalTime().ToString('o')
        }
    }
    finally {
        if ($secPtr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secPtr) }
        $plain = $null
    }
}
