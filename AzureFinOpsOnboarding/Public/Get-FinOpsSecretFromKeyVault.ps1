function Get-FinOpsSecretFromKeyVault {
    <#
    .SYNOPSIS
    Retrieves secrets from Azure Key Vault using Managed Identity or service principal authentication.

    .DESCRIPTION
    Provides secure secret retrieval from Azure Key Vault for use with FinOps onboarding functions.
    Supports both Managed Identity (recommended for Azure-hosted scenarios) and service principal authentication.
    Secrets are returned as SecureString objects for secure handling.

    .PARAMETER KeyVaultName
    Name of the Azure Key Vault (not the full URL).

    .PARAMETER SecretName
    Name of the secret to retrieve from the Key Vault.

    .PARAMETER UseManagedIdentity
    Use Azure Managed Identity for authentication. Recommended when running on Azure VMs, App Services, or Azure Automation.

    .PARAMETER TenantId
    Azure AD Tenant ID. Required when using service principal authentication.

    .PARAMETER ApplicationId
    Application (client) ID for service principal authentication.

    .PARAMETER ClientSecret
    Client secret for service principal authentication. Should be a SecureString.

    .PARAMETER AsPlainText
    Return the secret as plain text string instead of SecureString. Use with caution.

    .EXAMPLE
    # Using Managed Identity (recommended for Azure VMs/App Services)
    $secret = Get-FinOpsSecretFromKeyVault -KeyVaultName "finops-vault" -SecretName "JiraApiToken" -UseManagedIdentity

    .EXAMPLE
    # Using service principal
    $clientSecret = Read-Host "Client Secret" -AsSecureString
    $secret = Get-FinOpsSecretFromKeyVault `
        -KeyVaultName "finops-vault" `
        -SecretName "PowerBISecret" `
        -TenantId "00000000-0000-0000-0000-000000000000" `
        -ApplicationId "11111111-1111-1111-1111-111111111111" `
        -ClientSecret $clientSecret

    .EXAMPLE
    # Get plain text (use with caution in secure contexts only)
    $apiKey = <REDACTED> -KeyVaultName "finops-vault" -SecretName "ApiKey" -UseManagedIdentity -AsPlainText

    .OUTPUTS
    SecureString or String (if -AsPlainText is specified)
    #>
    [CmdletBinding(DefaultParameterSetName = 'ManagedIdentity')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ManagedIdentity')]
        [Parameter(Mandatory, ParameterSetName = 'ServicePrincipal')]
        [ValidateNotNullOrEmpty()]
        [string]$KeyVaultName,

        [Parameter(Mandatory, ParameterSetName = 'ManagedIdentity')]
        [Parameter(Mandatory, ParameterSetName = 'ServicePrincipal')]
        [ValidateNotNullOrEmpty()]
        [string]$SecretName,

        [Parameter(Mandatory, ParameterSetName = 'ManagedIdentity')]
        [switch]$UseManagedIdentity,

        [Parameter(Mandatory, ParameterSetName = 'ServicePrincipal')]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string]$TenantId,

        [Parameter(Mandatory, ParameterSetName = 'ServicePrincipal')]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string]$ApplicationId,

        [Parameter(Mandatory, ParameterSetName = 'ServicePrincipal')]
        [SecureString]$ClientSecret,

        [Parameter()]
        [switch]$AsPlainText
    )

    try {
        # Ensure Az.KeyVault module is available
        if (-not (Get-Module -ListAvailable -Name Az.KeyVault)) {
            Write-Verbose "Az.KeyVault module not found. Installing..."
            Install-Module -Name Az.KeyVault -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            Write-Verbose "Az.KeyVault installed successfully"
        }
        Import-Module Az.KeyVault -ErrorAction Stop

        # Check if already connected to Azure
        $context = Get-AzContext -ErrorAction SilentlyContinue
        
        if ($UseManagedIdentity) {
            Write-Verbose "Authenticating with Managed Identity..."
            
            if (-not $context -or $context.Account.Type -ne 'ManagedService') {
                try {
                    Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
                    Write-Verbose "Connected to Azure using Managed Identity"
                } catch {
                    throw "Failed to authenticate with Managed Identity. Ensure Managed Identity is enabled and has Key Vault access. Error: $_"
                }
            } else {
                Write-Verbose "Already authenticated with Managed Identity"
            }
        } else {
            # Service Principal authentication
            Write-Verbose "Authenticating with Service Principal..."
            
            if (-not $context -or $context.Account.Id -ne $ApplicationId) {
                $credential = New-Object System.Management.Automation.PSCredential($ApplicationId, $ClientSecret)
                try {
                    Connect-AzAccount -ServicePrincipal -Tenant $TenantId -Credential $credential -ErrorAction Stop | Out-Null
                    Write-Verbose "Connected to Azure using Service Principal"
                } catch {
                    throw "Failed to authenticate with Service Principal. Verify TenantId, ApplicationId, and ClientSecret are correct. Error: $_"
                }
            } else {
                Write-Verbose "Already authenticated with matching Service Principal"
            }
        }

        # Retrieve secret from Key Vault
        Write-Verbose "Retrieving secret '$SecretName' from Key Vault '$KeyVaultName'..."
        
        try {
            $secretObject = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $SecretName -ErrorAction Stop
            
            if (-not $secretObject) {
                throw "Secret '$SecretName' not found in Key Vault '$KeyVaultName'"
            }

            Write-Verbose "Secret retrieved successfully"

            if ($AsPlainText) {
                # Convert SecureString to plain text
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secretObject.SecretValue)
                try {
                    $plainText = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                    return $plainText
                } finally {
                    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                }
            } else {
                # Return as SecureString
                return $secretObject.SecretValue
            }

        } catch {
            if ($_.Exception.Message -like "*does not have secrets get permission*") {
                $currentUser = (Get-AzContext).Account.Id
                throw @"
Access Denied: The identity '$currentUser' does not have 'Get' permission for secrets in Key Vault '$KeyVaultName'.

To resolve:
1. In Azure Portal, navigate to Key Vault '$KeyVaultName'
2. Go to 'Access policies' or 'Access control (IAM)'
3. Add access policy with 'Get' permission for secrets
4. Assign to: $currentUser

Or use Azure CLI:
az keyvault set-policy --name $KeyVaultName --object-id <object-id> --secret-permissions get

Original error: $_
"@
            }
            
            if ($_.Exception.Message -like "*Could not find the Key Vault*") {
                throw "Key Vault '$KeyVaultName' not found. Verify the name is correct and you have access. Error: $_"
            }

            throw "Failed to retrieve secret from Key Vault: $_"
        }

    } catch {
        Write-Error $_
        return $null
    }
}

