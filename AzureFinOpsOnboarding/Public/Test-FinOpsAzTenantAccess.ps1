function Test-FinOpsAzTenantAccess {
    <#
    .SYNOPSIS
        Validates that a tenant App Registration (client credential) can obtain tokens for ARM & Key Vault and (optionally) read a secret.

    .DESCRIPTION
        Performs these steps:
          1. Acquire token for https://management.azure.com/.default
          2. Call /tenants?api-version=2020-01-01 to confirm basic graph/ARM access (list tenants for account) OR /subscriptions to verify scope.
          3. Acquire token for https://vault.azure.net/.default
          4. (Optional) GET a specified Key Vault secret to ensure data-plane permission.
        Returns a consolidated result object with granular step detail.

    .PARAMETER TenantId
        Directory (tenant) ID.

    .PARAMETER ApplicationId
        Client (app registration) ID.

    .PARAMETER ClientSecret
        Client secret (SecureString).

    .PARAMETER TestVaultName
        Optional Key Vault name to test secret retrieval.

    .PARAMETER TestSecretName
        Secret name inside the Key Vault to attempt to read (requires TestVaultName).

    .PARAMETER TimeoutSeconds
        Overall timeout per REST call (default 30).

    .OUTPUTS
        PSCustomObject with: Success, Steps[], ArmTokenAcquired, KvTokenAcquired, SecretRead (nullable), Errors[]

    .EXAMPLE
        Test-FinOpsAzTenantAccess -TenantId $tid -ApplicationId $appId -ClientSecret $sec -TestVaultName myvault -TestSecretName FinOpsOnboarding
    .EXAMPLE
        # Basic token acquisition only (no Key Vault)
        Test-FinOpsAzTenantAccess -TenantId $tid -ApplicationId $appId -ClientSecret $sec
    .EXAMPLE
        # Increase timeout for slow network and inspect step timings
        $r = Test-FinOpsAzTenantAccess -TenantId $tid -ApplicationId $appId -ClientSecret $sec -TestVaultName myvault -TestSecretName FinOpsOnboarding -TimeoutSeconds 60
        $r.Steps | Sort DurationMs -Descending | Select Name,Success,DurationMs
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ApplicationId,
        [Parameter(Mandatory)][SecureString]$ClientSecret,
        [string]$TestVaultName,
        [string]$TestSecretName,
        [int]$TimeoutSeconds = 30
    )

    $steps = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]
    $armToken = $null; $kvToken = $null

    # Helper to time/record a step
    function _recordStep {
        param($Name, $Action)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $ok = $false; $detail = $null
        try {
            $detail = & $Action
            $ok = $true
        } catch {
            $errors.Add(("{0}: {1}" -f $Name, $_.Exception.Message))
        } finally {
            $sw.Stop()
            $steps.Add([pscustomobject]@{ Name = $Name; Success = $ok; DurationMs = $sw.ElapsedMilliseconds; Detail = $detail })
        }
        return $detail
    }

    # 1. ARM token
    $armToken = _recordStep -Name 'AcquireArmToken' -Action { Get-FinOpsBearerToken -TenantId $TenantId -ApplicationId $ApplicationId -ClientSecret $ClientSecret -Scope 'https://management.azure.com/.default' }

    # 2. Basic ARM call (subscriptions)
    if ($armToken) {
        _recordStep -Name 'ListSubscriptions' -Action {
            $uri = 'https://management.azure.com/subscriptions?api-version=2022-12-01'
            Invoke-FinOpsRestMethodWithRetry -Uri $uri -Headers @{ Authorization = "Bearer $armToken" } -TimeoutSeconds $TimeoutSeconds -Method Get -ErrorAction Stop | Select-Object -Property value, nextLink
        } | Out-Null
    }

    # 3. KV token
    $kvToken = _recordStep -Name 'AcquireKvToken' -Action { Get-FinOpsBearerToken -TenantId $TenantId -ApplicationId $ApplicationId -ClientSecret $ClientSecret -Scope 'https://vault.azure.net/.default' }

    # 4. Secret read (optional)
    $secretRead = $null
    if ($kvToken -and $TestVaultName -and $TestSecretName) {
        _recordStep -Name 'GetSecret' -Action {
            $uri = "https://$TestVaultName.vault.azure.net/secrets/$TestSecretName?api-version=7.4"
            $resp = Invoke-FinOpsRestMethodWithRetry -Uri $uri -Headers @{ Authorization = "Bearer $kvToken" } -TimeoutSeconds $TimeoutSeconds -Method Get -ErrorAction Stop
            $secretRead = $true
            return @{ Name = $resp.id; Enabled = $resp.attributes.enabled; Expiry = $resp.attributes.exp; Tags = $resp.tags }
        } | Out-Null
    }

    $success = ($errors.Count -eq 0)
    # Touch variable to satisfy static analyzers complaining about 'assigned but never used'
    $null = $secretRead

    [pscustomobject]@{
        Success = $success
        ArmTokenAcquired = [bool]$armToken
        KvTokenAcquired = [bool]$kvToken
        SecretRead = $secretRead
        Steps = $steps.ToArray()
        Errors = $errors.ToArray()
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}
