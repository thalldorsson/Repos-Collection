function Get-FinOpsBearerToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ApplicationId,
        [Parameter(Mandatory)][SecureString]$ClientSecret,
        [string]$Scope = 'https://management.azure.com/.default'
    )
    # NOTE: Scope can be e.g. https://management.azure.com/.default OR https://vault.azure.net/.default (Key Vault data-plane)
    $secPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ClientSecret)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secPtr)
        $body = @{
            scope = $Scope
            client_id = $ApplicationId
            client_secret = $plain
            grant_type = 'client_credentials'
        }
        $uri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
        Write-Verbose "Requesting token (scope: $Scope) for application $ApplicationId"
        $token = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
        return $token.access_token
    }
    catch {
        throw [System.Exception]::new("Failed to acquire bearer token (scope: $Scope)", $_.Exception)
    }
    finally {
        if ($secPtr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secPtr) }
    }
}
