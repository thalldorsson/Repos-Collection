function New-FinOpsAzManagedIdentityForKeyVault {
    <#
    .SYNOPSIS
        Creates an Azure User-Assigned Managed Identity with Key Vault Secrets User role assignment.
        Designed for execution from Atlassian Jira or other automation platforms.

    .DESCRIPTION
        Creates a user-assigned managed identity in Azure and assigns it the "Key Vault Secrets User" role
        for a specified Key Vault. This enables secure, credential-free access to Key Vault secrets.
        
        Uses Azure REST APIs directly - no Az modules required.
        
        Security features:
        - No hardcoded credentials - uses service principal authentication
        - RBAC-based Key Vault access (recommended over legacy access policies)
        - Audit trail via output object
        - Retry logic for transient failures
        
        Integration with FinOps workflow:
        - Can be called from Jira automation rules
        - Returns structured output for logging/tracking
        - Compatible with existing FinOps authentication patterns

    .PARAMETER TenantId
        Azure AD/Entra ID tenant ID.

    .PARAMETER ApplicationId
        Service Principal (App Registration) client ID with permissions to:
        - Create managed identities (Managed Identity Contributor role)
        - Assign RBAC roles (User Access Administrator or Owner role)

    .PARAMETER ClientSecret
        Service Principal client secret (SecureString).

    .PARAMETER SubscriptionId
        Azure subscription ID where the managed identity will be created.

    .PARAMETER ResourceGroupName
        Resource group name where the managed identity will be created.

    .PARAMETER IdentityName
        Name for the new user-assigned managed identity.

    .PARAMETER KeyVaultName
        Name of the Key Vault to grant access to.

    .PARAMETER Location
        Azure region for the managed identity (e.g., 'westeurope', 'eastus').

    .PARAMETER RoleDefinitionName
        Azure built-in role to assign. Default: 'Key Vault Secrets User'
        Other options: 'Key Vault Reader', 'Key Vault Crypto User', etc.

    .PARAMETER Tags
        Optional hashtable of tags to apply to the managed identity.

    .PARAMETER JiraIssueKey
        Optional Jira issue key for audit/tracking purposes.

    .PARAMETER Token
        Optional pre-fetched bearer token. If not provided, one will be requested.

    .OUTPUTS
        PSCustomObject with:
        - Success: Boolean
        - ManagedIdentity: Created identity details (principalId, clientId, resourceId)
        - RoleAssignment: Role assignment details
        - KeyVault: Target Key Vault information
        - Error: Error details if failed
        - Timestamp: Creation timestamp
        - JiraIssueKey: Associated Jira issue (if provided)

    .EXAMPLE
        # Basic usage with service principal
        $secret = Read-Host "Client Secret" -AsSecureString
        $result = New-FinOpsAzManagedIdentityForKeyVault `
            -TenantId "12345678-1234-1234-1234-123456789012" `
            -ApplicationId "87654321-4321-4321-4321-210987654321" `
            -ClientSecret $secret `
            -SubscriptionId "11111111-1111-1111-1111-111111111111" `
            -ResourceGroupName "rg-finops-prd-we-001" `
            -IdentityName "id-finops-keyvault-access" `
            -KeyVaultName "kv-acc-prd-we-001" `
            -Location "westeurope" `
            -Verbose

    .EXAMPLE
        # Usage from Jira automation with tracking
        $result = New-FinOpsAzManagedIdentityForKeyVault `
            -TenantId $env:AZURE_TENANT_ID `
            -ApplicationId $env:AZURE_CLIENT_ID `
            -ClientSecret (ConvertTo-SecureString $env:AZURE_CLIENT_SECRET -AsPlainText -Force) `
            -SubscriptionId $env:AZURE_SUBSCRIPTION_ID `
            -ResourceGroupName "rg-finops-automation" `
            -IdentityName "id-finops-jira-automation-$(Get-Date -Format 'yyyyMMdd')" `
            -KeyVaultName "kv-acc-prd-we-001" `
            -Location "westeurope" `
            -JiraIssueKey "FINOPS-123" `
            -Tags @{ 
                Purpose = "FinOps Automation"
                CreatedBy = "Jira"
                IssueKey = "FINOPS-123"
            }

    .EXAMPLE
        # Grant additional Key Vault access with different role
        $result = New-FinOpsAzManagedIdentityForKeyVault `
            -TenantId $tid `
            -ApplicationId $appId `
            -ClientSecret $secret `
            -SubscriptionId $subId `
            -ResourceGroupName "rg-security" `
            -IdentityName "id-keyvault-crypto-operations" `
            -KeyVaultName "kv-security-prd" `
            -Location "eastus" `
            -RoleDefinitionName "Key Vault Crypto User"

    .NOTES
        Prerequisites:
        1. Service Principal must have:
           - "Managed Identity Contributor" role on resource group/subscription
           - "User Access Administrator" or "Owner" role on Key Vault
        
        2. Key Vault must be configured for Azure RBAC (not legacy access policies)
           To check: Key Vault > Access configuration > Permission model = "Azure role-based access control"
        
        3. Network access: If Key Vault has network restrictions, ensure service principal can access it
        
        Best Practices Applied:
        - Uses RBAC instead of legacy access policies (more secure, auditable)
        - Managed Identity preferred over service principals for application access
        - Tags for governance and cost tracking
        - Structured error handling with retry logic
        - No credential exposure in logs or output

    .LINK
        https://learn.microsoft.com/en-us/azure/active-directory/managed-identities-azure-resources/overview
        
    .LINK
        https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TenantId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ApplicationId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [SecureString]$ClientSecret,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$IdentityName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$KeyVaultName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Location,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Key Vault Reader', 'Key Vault Secrets User', 'Key Vault Crypto User', 
                     'Key Vault Secrets Officer', 'Key Vault Crypto Officer')]
        [string]$RoleDefinitionName = 'Key Vault Secrets User',

        [Parameter(Mandatory = $false)]
        [hashtable]$Tags = @{},

        [Parameter(Mandatory = $false)]
        [string]$JiraIssueKey,

        [Parameter(Mandatory = $false)]
        [string]$Token,

        [Parameter(Mandatory = $false)]
        [int]$MaxRetries = 3,

        [Parameter(Mandatory = $false)]
        [int]$InitialDelaySeconds = 2
    )

    BEGIN {
        $ErrorActionPreference = 'Stop'
        $timestamp = (Get-Date).ToUniversalTime()
        
        # Initialize result object
        $result = [PSCustomObject]@{
            Success          = $false
            ManagedIdentity  = $null
            RoleAssignment   = $null
            KeyVault         = @{
                Name         = $KeyVaultName
                ResourceId   = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.KeyVault/vaults/$KeyVaultName"
            }
            Error            = $null
            Timestamp        = $timestamp.ToString('o')
            JiraIssueKey     = $JiraIssueKey
            ExecutionContext = @{
                Location         = $Location
                ResourceGroup    = $ResourceGroupName
                SubscriptionId   = $SubscriptionId
            }
        }

        # Helper function for retry logic
        function Invoke-RestMethodWithRetry {
            param(
                [string]$Uri,
                [string]$Method,
                [hashtable]$Headers,
                [string]$Body,
                [int]$MaxRetries,
                [int]$InitialDelay
            )

            $attempt = 0
            while ($attempt -le $MaxRetries) {
                try {
                    $attempt++
                    Write-Verbose "[$Method] Attempt $attempt of $($MaxRetries + 1): $Uri"
                    
                    $params = @{
                        Uri         = $Uri
                        Method      = $Method
                        Headers     = $Headers
                        ErrorAction = 'Stop'
                    }
                    
                    if ($Body) {
                        $params.Body = $Body
                    }

                    return Invoke-RestMethod @params
                }
                catch {
                    $statusCode = $_.Exception.Response.StatusCode.Value__ 2>$null
                    $isTransient = $statusCode -in 429, 500, 502, 503, 504
                    
                    if ($attempt -le $MaxRetries -and $isTransient) {
                        $delay = [Math]::Pow(2, ($attempt - 1)) * $InitialDelay
                        Write-Warning "Transient error ($statusCode). Retrying in $delay seconds..."
                        Start-Sleep -Seconds $delay
                    }
                    else {
                        throw
                    }
                }
            }
        }
    }

    PROCESS {
        try {
            # Step 0: Validate and acquire token
            if (-not $PSCmdlet.ShouldProcess("Subscription: $SubscriptionId, Identity: $IdentityName", "Create Managed Identity with Key Vault Access")) {
                return $result
            }

            Write-Verbose "=== Creating Managed Identity with Key Vault Access ==="
            Write-Verbose "Tenant: $TenantId"
            Write-Verbose "Subscription: $SubscriptionId"
            Write-Verbose "Resource Group: $ResourceGroupName"
            Write-Verbose "Identity Name: $IdentityName"
            Write-Verbose "Key Vault: $KeyVaultName"
            Write-Verbose "Location: $Location"
            Write-Verbose "Role: $RoleDefinitionName"
            if ($JiraIssueKey) {
                Write-Verbose "Jira Issue: $JiraIssueKey"
            }

            # Acquire Azure Resource Manager token
            if (-not $Token) {
                Write-Verbose "Acquiring Azure Resource Manager token..."
                $Token = Get-FinOpsBearerToken -TenantId $TenantId `
                                                -ApplicationId $ApplicationId `
                                                -ClientSecret $ClientSecret `
                                                -Scope 'https://management.azure.com/.default'
            }

            $headers = @{
                'Authorization' = "Bearer $Token"
                'Content-Type'  = 'application/json'
            }

            # Step 1: Create User-Assigned Managed Identity
            Write-Verbose "`n--- Step 1: Creating User-Assigned Managed Identity ---"
            $identityResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$IdentityName"
            $identityUri = "https://management.azure.com$identityResourceId`?api-version=2023-01-31"

            $identityBody = @{
                location = $Location
                tags     = $Tags
            } | ConvertTo-Json -Depth 10

            Write-Verbose "Creating managed identity at: $identityUri"
            $identity = Invoke-RestMethodWithRetry -Uri $identityUri `
                                                    -Method 'Put' `
                                                    -Headers $headers `
                                                    -Body $identityBody `
                                                    -MaxRetries $MaxRetries `
                                                    -InitialDelay $InitialDelaySeconds

            Write-Host "✓ Managed Identity created successfully" -ForegroundColor Green
            Write-Verbose "Principal ID: $($identity.properties.principalId)"
            Write-Verbose "Client ID: $($identity.properties.clientId)"

            $result.ManagedIdentity = @{
                Name         = $identity.name
                ResourceId   = $identity.id
                PrincipalId  = $identity.properties.principalId
                ClientId     = $identity.properties.clientId
                Location     = $identity.location
                Tags         = $identity.tags
            }

            # Step 2: Wait for identity propagation (Azure AD replication)
            Write-Verbose "`n--- Step 2: Waiting for identity propagation ---"
            Write-Verbose "Waiting 10 seconds for Azure AD replication..."
            Start-Sleep -Seconds 10

            # Step 3: Get Key Vault resource ID
            Write-Verbose "`n--- Step 3: Resolving Key Vault resource ---"
            $kvResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.KeyVault/vaults/$KeyVaultName"
            $kvUri = "https://management.azure.com$kvResourceId`?api-version=2023-02-01"

            Write-Verbose "Retrieving Key Vault details: $kvUri"
            $keyVault = Invoke-RestMethodWithRetry -Uri $kvUri `
                                                     -Method 'Get' `
                                                     -Headers $headers `
                                                     -MaxRetries $MaxRetries `
                                                     -InitialDelay $InitialDelaySeconds

            Write-Host "✓ Key Vault found: $($keyVault.name)" -ForegroundColor Green
            Write-Verbose "Key Vault URI: $($keyVault.properties.vaultUri)"

            # Verify RBAC is enabled
            $permissionModel = $keyVault.properties.enableRbacAuthorization
            if (-not $permissionModel) {
                Write-Warning "Key Vault '$KeyVaultName' may not have RBAC enabled. Consider enabling it for better security."
                Write-Warning "Check: Key Vault > Access configuration > Permission model"
            }

            # Step 4: Get Role Definition ID
            Write-Verbose "`n--- Step 4: Resolving role definition ---"
            $roleDefsUri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleDefinitions?api-version=2022-04-01&`$filter=roleName eq '$RoleDefinitionName'"
            
            Write-Verbose "Querying role definitions for: $RoleDefinitionName"
            $roleDefs = Invoke-RestMethodWithRetry -Uri $roleDefsUri `
                                                     -Method 'Get' `
                                                     -Headers $headers `
                                                     -MaxRetries $MaxRetries `
                                                     -InitialDelay $InitialDelaySeconds

            if ($roleDefs.value.Count -eq 0) {
                throw "Role definition '$RoleDefinitionName' not found"
            }

            $roleDefinitionId = $roleDefs.value[0].id
            Write-Host "✓ Role definition found: $RoleDefinitionName" -ForegroundColor Green
            Write-Verbose "Role Definition ID: $roleDefinitionId"

            # Step 5: Create Role Assignment
            Write-Verbose "`n--- Step 5: Creating role assignment ---"
            $roleAssignmentName = [guid]::NewGuid().ToString()
            $roleAssignmentScope = $kvResourceId
            $roleAssignmentUri = "https://management.azure.com$roleAssignmentScope/providers/Microsoft.Authorization/roleAssignments/$roleAssignmentName`?api-version=2022-04-01"

            $roleAssignmentBody = @{
                properties = @{
                    roleDefinitionId = $roleDefinitionId
                    principalId      = $identity.properties.principalId
                    principalType    = "ServicePrincipal"
                }
            } | ConvertTo-Json -Depth 10

            Write-Verbose "Assigning role '$RoleDefinitionName' to managed identity on Key Vault"
            Write-Verbose "Role Assignment URI: $roleAssignmentUri"
            
            $roleAssignment = Invoke-RestMethodWithRetry -Uri $roleAssignmentUri `
                                                          -Method 'Put' `
                                                          -Headers $headers `
                                                          -Body $roleAssignmentBody `
                                                          -MaxRetries $MaxRetries `
                                                          -InitialDelay $InitialDelaySeconds

            Write-Host "✓ Role assignment created successfully" -ForegroundColor Green
            Write-Verbose "Role Assignment ID: $($roleAssignment.id)"

            $result.RoleAssignment = @{
                Id               = $roleAssignment.id
                Name             = $roleAssignment.name
                RoleDefinitionId = $roleAssignment.properties.roleDefinitionId
                PrincipalId      = $roleAssignment.properties.principalId
                Scope            = $roleAssignment.properties.scope
                RoleName         = $RoleDefinitionName
            }

            # Success
            $result.Success = $true
            Write-Host "`n=== SUCCESS ===" -ForegroundColor Green
            Write-Host "Managed Identity: $($result.ManagedIdentity.Name)" -ForegroundColor Cyan
            Write-Host "Principal ID: $($result.ManagedIdentity.PrincipalId)" -ForegroundColor Cyan
            Write-Host "Client ID: $($result.ManagedIdentity.ClientId)" -ForegroundColor Cyan
            Write-Host "Key Vault Access: $RoleDefinitionName on $KeyVaultName" -ForegroundColor Cyan
            
            if ($JiraIssueKey) {
                Write-Host "Jira Issue: $JiraIssueKey" -ForegroundColor Cyan
            }
        }
        catch {
            $result.Success = $false
            $result.Error = @{
                Message    = $_.Exception.Message
                Type       = $_.Exception.GetType().FullName
                StackTrace = $_.ScriptStackTrace
                StatusCode = $_.Exception.Response.StatusCode.Value__ 2>$null
            }

            Write-Error "Failed to create managed identity with Key Vault access: $($_.Exception.Message)"
            Write-Verbose "Error details: $($result.Error | ConvertTo-Json -Depth 10)"
        }
    }

    END {
        return $result
    }
}
