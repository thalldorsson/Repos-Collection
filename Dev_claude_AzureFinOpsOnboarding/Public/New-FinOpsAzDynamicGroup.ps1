function New-FinOpsAzDynamicGroup {
    <#
    .SYNOPSIS
        Creates a dynamic security group in Azure AD/Entra ID for FinOps customer onboarding.

    .DESCRIPTION
        Creates a dynamic membership group named "FinOps-Customer-{CustomerName}" with a membership
        rule that automatically includes users whose UPN contains the specified email domain.
        
        Requires Microsoft Graph API permissions:
        - Group.ReadWrite.All or Directory.ReadWrite.All

    .PARAMETER CustomerName
        The customer name to include in the group name (e.g., "Contoso").
        Will be used to create group named "FinOps-Customer-Contoso".

    .PARAMETER EmailDomain
        The email domain to use in the dynamic membership rule (e.g., "contoso.com").
        Users with UPNs containing this domain will be automatically added to the group.

    .PARAMETER Description
        Optional description for the group. Defaults to a standard FinOps description.

    .PARAMETER AccessToken
        Optional Microsoft Graph access token. If not provided, will attempt to use
        the current Azure PowerShell context.

    .PARAMETER WhatIf
        Shows what would happen if the cmdlet runs without actually creating the group.

    .EXAMPLE
        New-FinOpsAzDynamicGroup -CustomerName "Contoso" -EmailDomain "contoso.com"
        
        Creates a dynamic group "FinOps-Customer-Contoso" that includes users with
        UPNs containing "contoso.com".

    .EXAMPLE
        New-FinOpsAzDynamicGroup -CustomerName "Fabrikam" -EmailDomain "fabrikam.com" -Description "Custom description" -WhatIf
        
        Shows what would be created without actually creating the group.

    .NOTES
        Author: Crayon FinOps
        Requires: Az.Accounts module (for authentication) or Microsoft Graph access token
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$CustomerName,

        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EmailDomain,

        [Parameter(Mandatory = $false)]
        [string]$Description,

        [Parameter(Mandatory = $false)]
        [string]$AccessToken
    )

    begin {
        Write-Verbose "[New-FinOpsAzDynamicGroup] Starting dynamic group creation process"
        
        # Check for configured tenant ID
        $configuredTenantId = Get-FinOpsTenantId
        if ($configuredTenantId) {
            Write-Verbose "[New-FinOpsAzDynamicGroup] Using configured tenant ID: $configuredTenantId"
        }
        
        # Ensure we have an access token
        if (-not $AccessToken) {
            Write-Verbose "[New-FinOpsAzDynamicGroup] No access token provided, attempting to get from Az context"
            try {
                # Connect to the configured tenant if available
                if ($configuredTenantId) {
                    $context = Get-AzContext -ErrorAction SilentlyContinue
                    if (-not $context -or $context.Tenant.Id -ne $configuredTenantId) {
                        Write-Verbose "[New-FinOpsAzDynamicGroup] Connecting to tenant: $configuredTenantId"
                        Connect-AzAccount -TenantId $configuredTenantId -ErrorAction Stop | Out-Null
                    }
                } else {
                    $context = Get-AzContext -ErrorAction Stop
                    if (-not $context) {
                        throw "No Azure context found. Please run Connect-AzAccount first or configure a tenant with Set-FinOpsTenantId."
                    }
                }
                
                $token = Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com" -ErrorAction Stop
                $AccessToken = $token.Token
                Write-Verbose "[New-FinOpsAzDynamicGroup] Successfully obtained access token from Az context"
            }
            catch {
                Write-Error "Failed to obtain Microsoft Graph access token. Please run Connect-AzAccount or provide an AccessToken parameter. Error: $_"
                return
            }
        }
    }

    process {
        try {
            # Sanitize customer name for group name (remove special characters)
            $sanitizedCustomerName = $CustomerName -replace '[^\w\s-]', ''
            $groupName = "FinOps-Customer-$sanitizedCustomerName"
            
            # Set default description if not provided
            if (-not $Description) {
                $Description = "FinOps dynamic group for $CustomerName - Auto-populated based on email domain $EmailDomain"
            }

            # Build the dynamic membership rule
            # Format: (user.userPrincipalName -contains "domain.com")
            $membershipRule = "(user.userPrincipalName -contains `"$EmailDomain`")"
            
            Write-Verbose "[New-FinOpsAzDynamicGroup] Group Name: $groupName"
            Write-Verbose "[New-FinOpsAzDynamicGroup] Membership Rule: $membershipRule"
            Write-Verbose "[New-FinOpsAzDynamicGroup] Description: $Description"

            # Check if group already exists
            $checkUri = "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$groupName'"
            $headers = @{
                'Authorization' = "Bearer $AccessToken"
                'Content-Type'  = 'application/json'
            }

            Write-Verbose "[New-FinOpsAzDynamicGroup] Checking if group already exists..."
            $existingGroups = Invoke-RestMethod -Uri $checkUri -Headers $headers -Method Get -ErrorAction Stop

            if ($existingGroups.value -and $existingGroups.value.Count -gt 0) {
                Write-Warning "Group '$groupName' already exists (ID: $($existingGroups.value[0].id))"
                return [PSCustomObject]@{
                    Success     = $false
                    GroupName   = $groupName
                    GroupId     = $existingGroups.value[0].id
                    Message     = "Group already exists"
                    AlreadyExists = $true
                }
            }

            # Prepare the group object
            $groupObject = @{
                displayName                   = $groupName
                description                   = $Description
                mailEnabled                   = $false
                mailNickname                  = $groupName -replace '[^\w]', ''
                securityEnabled               = $true
                groupTypes                    = @("DynamicMembership")
                membershipRule                = $membershipRule
                membershipRuleProcessingState = "On"
            }

            $body = $groupObject | ConvertTo-Json -Depth 10

            if ($PSCmdlet.ShouldProcess($groupName, "Create dynamic Azure AD group")) {
                Write-Verbose "[New-FinOpsAzDynamicGroup] Creating dynamic group via Microsoft Graph API..."
                
                $uri = "https://graph.microsoft.com/v1.0/groups"
                $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Post -Body $body -ErrorAction Stop

                Write-Verbose "[New-FinOpsAzDynamicGroup] Successfully created group: $($response.id)"
                
                return [PSCustomObject]@{
                    Success          = $true
                    GroupName        = $response.displayName
                    GroupId          = $response.id
                    MembershipRule   = $response.membershipRule
                    Description      = $response.description
                    GroupTypes       = $response.groupTypes
                    CreatedDateTime  = $response.createdDateTime
                    Message          = "Dynamic group created successfully"
                }
            }
            else {
                Write-Verbose "[New-FinOpsAzDynamicGroup] WhatIf: Would create group '$groupName' with rule: $membershipRule"
                return [PSCustomObject]@{
                    Success        = $true
                    GroupName      = $groupName
                    MembershipRule = $membershipRule
                    Description    = $Description
                    Message        = "WhatIf: Group would be created"
                    WhatIf         = $true
                }
            }
        }
        catch {
            $errorMessage = $_.Exception.Message
            if ($_.Exception.Response) {
                try {
                    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                    $reader.BaseStream.Position = 0
                    $responseBody = $reader.ReadToEnd()
                    $errorDetails = $responseBody | ConvertFrom-Json
                    $errorMessage = "$errorMessage - $($errorDetails.error.message)"
                }
                catch {
                    # If we can't read the response, just use the original error
                }
            }
            
            Write-Error "Failed to create dynamic group '$groupName': $errorMessage"
            
            return [PSCustomObject]@{
                Success   = $false
                GroupName = $groupName
                Message   = "Failed to create group: $errorMessage"
                Error     = $errorMessage
            }
        }
    }
}
