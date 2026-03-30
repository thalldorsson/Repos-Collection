function Invoke-FinOpsAzTenantAccessByCustomerName {
    # Suppress PSScriptAnalyzer warning: Secret value is retrieved from Key Vault (secure source) and must be converted to SecureString
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Secret is retrieved from Azure Key Vault and needs to be converted to SecureString for use with Test-FinOpsAzTenantAccess')]
    <#
    .SYNOPSIS
        High-level wrapper: user supplies only CustomerName; function looks up credentials in SQL, fetches the client secret from Key Vault, and runs Test-FinOpsAzTenantAccess.

    .DESCRIPTION
        Workflow:
          1. Resolve customer row via Get-FinOpsAzCustomerAppCredential
          2. Determine Key Vault name (either passed explicitly or parsed from SecretName if pattern 'vaultName:secretName')
          3. Fetch the secret value from Key Vault using a data-plane token acquired via the same app (OR optionally a bootstrap identity if provided)
          4. Run Test-FinOpsAzTenantAccess using the looked-up TenantId/ApplicationId/client secret
          5. Return composite object with Lookup, SecretMetadata, AccessTest

        NOTE: This assumes that the "SecretName" column contains either the Key Vault secret name (and -VaultName parameter is supplied) or a combined token 'vaultName/secretName' or 'vaultName:secretName'.

    .PARAMETER CustomerName
        Name of the customer to look up.

    .PARAMETER ConnectionString
        SQL connection string (fallback to env:AFO_SQL_CONNECTION).

    .PARAMETER VaultName
        Explicit Key Vault name if SecretName does not embed vault identifier.

    .PARAMETER BootstrapTenantId / BootstrapApplicationId / BootstrapClientSecret
        Optional alternate app registration to use JUST for reading the secret if the target app's own secret cannot be retrieved without itself.

    .PARAMETER SecretNameOverride
        Force a secret name (bypass row.SecretName).

    .OUTPUTS
        PSCustomObject with: Customer, SecretRetrieved(bool), AccessTest(result), Errors[]
    .EXAMPLE
        # Full flow with bootstrap identity (recommended)
        $bootstrap = Read-Host 'Bootstrap secret' -AsSecureString
        Invoke-FinOpsAzTenantAccessByCustomerName -CustomerName 'gf forsikring' -BootstrapTenantId $tid -BootstrapApplicationId $bootstrapApp -BootstrapClientSecret $bootstrap
    .EXAMPLE
        # Provide vault explicitly when SecretName column stores only secret
        Invoke-FinOpsAzTenantAccessByCustomerName -CustomerName 'Contoso' -VaultName 'kv-acc-prd-we-001' -BootstrapTenantId $tid -BootstrapApplicationId $app -BootstrapClientSecret (Read-Host 'Secret' -AsSecureString)
    .EXAMPLE
        # Override secret name (ignoring DB value)
        Invoke-FinOpsAzTenantAccessByCustomerName -CustomerName 'Contoso' -SecretNameOverride 'kv-acc-prd-we-001:Contoso-AppSecret' -BootstrapTenantId $tid -BootstrapApplicationId $app -BootstrapClientSecret (Read-Host 'Secret' -AsSecureString)
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)][string]$CustomerName,
        [string]$ConnectionString,
        [string]$VaultName,
        [string]$SecretNameOverride,
        [string]$BootstrapTenantId,
        [string]$BootstrapApplicationId,
        [SecureString]$BootstrapClientSecret
    )

    $errors = New-Object System.Collections.Generic.List[string]

    $cust = Get-FinOpsAzCustomerAppCredential -CustomerName $CustomerName -ConnectionString $ConnectionString
    if (-not $cust) { throw "Customer '$CustomerName' not found in credential sources." }

    $rawSecretRef = if ($SecretNameOverride) { $SecretNameOverride } else { $cust.SecretName }
    if (-not $rawSecretRef) { throw 'No SecretName available in lookup row and none supplied via -SecretNameOverride.' }

    $resolvedVault = $VaultName
    $secretName = $rawSecretRef

    if (-not $resolvedVault) {
        if ($rawSecretRef -match '^[^:/]+[:/][^:/]+$') { # pattern vault:secret or vault/secret
            $parts = $rawSecretRef -split '[:/]'
            $resolvedVault = $parts[0]
            $secretName = $parts[1]
        }
    }
    if (-not $resolvedVault) { throw 'Unable to determine Key Vault name. Provide -VaultName or embed vault in SecretName as vault:secret.' }

    # Acquire token (bootstrap or target) for KV to retrieve secret value
    $kvScope = 'https://vault.azure.net/.default'
    try {
        if ($BootstrapTenantId -and $BootstrapApplicationId -and $BootstrapClientSecret) {
            $kvToken = Get-FinOpsBearerToken -TenantId $BootstrapTenantId -ApplicationId $BootstrapApplicationId -ClientSecret $BootstrapClientSecret -Scope $kvScope
        } else {
            # Assume we already have the client secret? We don't. We need to retrieve it. For that we need a bootstrap identity.
            # If no bootstrap provided, we cannot fetch secret value; record warning.
            $kvToken = $null
            $errors.Add('No bootstrap credentials provided; secret value will not be retrieved.')
        }
    } catch {
        $errors.Add("Failed to acquire KV token: $($_.Exception.Message)")
    }

    $secretValueSecure = $null
    $secretMeta = $null
    if ($kvToken) {
        try {
            $uri = "https://$resolvedVault.vault.azure.net/secrets/$secretName?api-version=7.4"
            $resp = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $kvToken" } -Method Get -ErrorAction Stop
            $secretMeta = [pscustomobject]@{
                Id = $resp.id
                Enabled = $resp.attributes.enabled
                Expiry = if ($resp.attributes.exp) { [DateTimeOffset]::FromUnixTimeSeconds([int64]$resp.attributes.exp).UtcDateTime } else { $null }
                Tags = $resp.tags
                Vault = $resolvedVault
                Name = $secretName
            }
            # Convert secret value to SecureString for Test-FinOpsAzTenantAccess call
            $secretValueSecure = ConvertTo-SecureString -String $resp.value -AsPlainText -Force
        } catch {
            $errors.Add("Failed to read secret '$secretName' from vault '$resolvedVault': $($_.Exception.Message)")
        }
    }

    $accessTest = $null
    if ($secretValueSecure) {
        try {
            $accessTest = Test-FinOpsAzTenantAccess -TenantId $cust.TenantId -ApplicationId $cust.ApplicationId -ClientSecret $secretValueSecure -TestVaultName $resolvedVault -TestSecretName $secretName
        } catch {
            $errors.Add("Tenant access test failed: $($_.Exception.Message)")
        }
    } else {
        $errors.Add('Skipping access test because secret value was not retrieved.')
    }

    [pscustomobject]@{
        Customer = $cust
        SecretMetadata = $secretMeta
        AccessTest = $accessTest
        SecretRetrieved = [bool]$secretValueSecure
        Errors = $errors.ToArray()
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}
