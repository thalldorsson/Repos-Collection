<#
.SYNOPSIS
    Retrieves secrets from Azure Key Vault or fallback configuration.

.DESCRIPTION
    Get-PhishIRSecret securely retrieves secrets from Azure Key Vault when
    configured, or falls back to config file storage (development only).
    
    Key features:
    - Azure Key Vault integration with Managed Identity or Service Principal
    - Automatic fallback to config file for local development
    - Security warnings when using non-production secret storage
    - Environment variable override support (PHISHIR_KV_NAME, etc.)

.PARAMETER SecretName
    The name of the secret to retrieve. Common values:
    - 'SplunkHecToken': Splunk HTTP Event Collector token
    - 'SentinelSharedKey': Azure Sentinel workspace shared key
    - 'AzureBlobSasToken': Azure Blob Storage SAS token
    - 'GraphAppSecret': Microsoft Graph app registration secret

.PARAMETER AsSecureString
    Return the secret as a SecureString instead of plain text.
    Recommended when passing to cmdlets that support SecureString parameters.

.EXAMPLE
    $splunkToken = Get-PhishIRSecret -SecretName 'SplunkHecToken'
    Send-SIEMEvent -HecToken $splunkToken

.EXAMPLE
    $secret = Get-PhishIRSecret -SecretName 'SentinelSharedKey' -AsSecureString
    Connect-AzMonitor -WorkspaceKey $secret

.NOTES
    Production Security:
    - Always use Azure Key Vault (UseKeyVault = $true)
    - Use Managed Identity when running on Azure resources (VMs, Functions, Automation)
    - For local development, use Service Principal with least privilege
    - Never commit secrets to config files in version control

    Environment Variables (override config):
    - PHISHIR_KV_NAME: Key Vault name
    - PHISHIR_KV_TENANT: Tenant ID
    - PHISHIR_KV_CLIENT: Client ID
#>
function Get-PhishIRSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet(
            'SplunkHecToken',
            'SentinelSharedKey', 
            'AzureBlobSasToken',
            'GraphAppSecret'
        )]
        [string]$SecretName,
        
        [Parameter(Mandatory = $false)]
        [switch]$AsSecureString
    )
    
    try {
        # Load security configuration
        $config = $null
        if (Get-Command Get-PhishIRConfig -ErrorAction SilentlyContinue) {
            $config = Get-PhishIRConfig -Section 'Security' -ErrorAction SilentlyContinue
        }
        
        # Fallback: Read config file directly if helper unavailable
        if (-not $config) {
            $moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
            $configPath = Join-Path $moduleRoot 'Config\PhishIRConfig.psd1'
            if (Test-Path $configPath) {
                $fullConfig = Import-PowerShellDataFile -Path $configPath
                $config = $fullConfig.Security
            }
        }
        
        # Environment variable overrides
        $useKeyVault = $config.UseKeyVault
        $keyVaultName = $config.KeyVaultName
        $useManagedIdentity = $config.UseManagedIdentity
        $tenantId = $config.TenantId
        $clientId = $config.ClientId
        
        if ($env:PHISHIR_KV_NAME) {
            $keyVaultName = $env:PHISHIR_KV_NAME
            $useKeyVault = $true
            Write-Verbose "Using Key Vault name from environment: $keyVaultName"
        }
        if ($env:PHISHIR_KV_TENANT) {
            $tenantId = $env:PHISHIR_KV_TENANT
            Write-Verbose "Using tenant ID from environment"
        }
        if ($env:PHISHIR_KV_CLIENT) {
            $clientId = $env:PHISHIR_KV_CLIENT
            Write-Verbose "Using client ID from environment"
        }
        
        # Azure Key Vault retrieval (production path)
        if ($useKeyVault -and $keyVaultName) {
            Write-Verbose "Retrieving secret '$SecretName' from Key Vault '$keyVaultName'"
            
            # Check for Az.KeyVault module
            if (-not (Get-Module -ListAvailable -Name 'Az.KeyVault')) {
                throw "Az.KeyVault module not installed. Install with: Install-Module Az.KeyVault -Scope CurrentUser"
            }
            
            # Map internal secret names to Key Vault keys
            $kvSecretName = $config.SecretNames.$SecretName
            if (-not $kvSecretName) {
                throw "Secret '$SecretName' not mapped in Security.SecretNames config"
            }
            
            # Authenticate if needed
            $context = Get-AzContext -ErrorAction SilentlyContinue
            if (-not $context) {
                if ($useManagedIdentity) {
                    Write-Verbose "Connecting using Managed Identity"
                    Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
                } elseif ($tenantId -and $clientId) {
                    Write-Verbose "Connecting using Service Principal (tenant: $tenantId)"
                    # Service Principal auth requires certificate or secret
                    # Assumes user has already authenticated via Connect-AzAccount
                    Write-Warning "Service Principal authentication requires pre-authentication. Run: Connect-AzAccount -ServicePrincipal -TenantId '$tenantId' -ApplicationId '$clientId'"
                } else {
                    Write-Warning "No Azure context found. Run: Connect-AzAccount"
                }
            }
            
            # Retrieve secret from Key Vault
            $kvSecret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $kvSecretName -ErrorAction Stop
            
            if ($AsSecureString) {
                return $kvSecret.SecretValue
            } else {
                # Convert SecureString to plain text
                $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($kvSecret.SecretValue)
                try {
                    return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
                } finally {
                    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
                }
            }
        }
        
        # Fallback: Config file secrets (development only)
        Write-Warning "Retrieving secret '$SecretName' from config file - NOT RECOMMENDED FOR PRODUCTION"
        Write-Warning 'Enable Azure Key Vault by setting Security.UseKeyVault = $true in PhishIRConfig.psd1'
        
        $secretValue = $config.Secrets.$SecretName
        
        if ([string]::IsNullOrWhiteSpace($secretValue)) {
            throw "Secret '$SecretName' not found in config fallback. Ensure Security.Secrets.$SecretName is set or use Azure Key Vault."
        }
        
        if ($AsSecureString) {
            return (ConvertTo-SecureString -String $secretValue -AsPlainText -Force)
        } else {
            return $secretValue
        }
        
    } catch {
        Write-Error "Failed to retrieve secret '$SecretName': $_"
        throw
    }
}
