function New-FinOpsAzGuestUserInvitation {
    <#
    .SYNOPSIS
        Invites external guest users to the Azure AD/Entra ID tenant.

    .DESCRIPTION
        Sends invitation emails to external users to join the tenant as guest users.
        Optionally adds them to specified groups after invitation.
        
        Requires Microsoft Graph API permissions:
        - User.Invite.All

    .PARAMETER EmailAddress
        The email address(es) of the user(s) to invite. If not provided, will prompt interactively.

    .PARAMETER DisplayName
        Display name for the guest user. If not provided, will prompt interactively or use email prefix.

    .PARAMETER InviteRedirectUrl
        The URL the user should be redirected to after accepting the invitation.
        Defaults to "https://portal.azure.com".

    .PARAMETER SendInvitationMessage
        Whether to send the invitation email. Default is $true.

    .PARAMETER CustomMessage
        Custom message to include in the invitation email. 
        Defaults to: "You have been invited to access our organization's resources."

    .PARAMETER AccessToken
        Optional Microsoft Graph access token. If not provided, will attempt to use
        the current Azure PowerShell context.

    .PARAMETER WhatIf
        Shows what would happen if the cmdlet runs without actually inviting users.

    .EXAMPLE
        New-FinOpsAzGuestUserInvitation
        
        Prompts for email address and display name, then invites the user.

    .EXAMPLE
        New-FinOpsAzGuestUserInvitation -EmailAddress "john.doe@contoso.com" -DisplayName "John Doe"
        
        Invites john.doe@contoso.com as "John Doe" with default settings.

    .EXAMPLE
        New-FinOpsAzGuestUserInvitation -EmailAddress "jane@fabrikam.com" -DisplayName "Jane Smith" -CustomMessage "Welcome to our FinOps portal!"
        
        Invites jane@fabrikam.com with a custom display name and message.

    .EXAMPLE
        "user1@domain.com", "user2@domain.com" | New-FinOpsAzGuestUserInvitation
        
        Invites multiple users via pipeline.

    .EXAMPLE
        New-FinOpsAzGuestUserInvitation -EmailAddress "admin@partner.com" -SendInvitationMessage $false
        
        Creates the guest user invitation without sending an email.

    .NOTES
        Author: Crayon FinOps
        Requires: Az.Accounts module (for authentication) or Microsoft Graph access token
        Graph API Permissions Required: User.Invite.All
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $false, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidatePattern('^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$')]
        [string[]]$EmailAddress,

        [Parameter(Mandatory = $false, ValueFromPipelineByPropertyName = $true)]
        [string[]]$DisplayName,

        [Parameter(Mandatory = $false)]
        [string]$InviteRedirectUrl = "https://portal.azure.com",

        [Parameter(Mandatory = $false)]
        [bool]$SendInvitationMessage = $true,

        [Parameter(Mandatory = $false)]
        [string]$CustomMessage = "You are invited to access FinOps Report for your organization.",

        [Parameter(Mandatory = $false)]
        [string]$AccessToken
    )

    begin {
        Write-Verbose "[New-FinOpsAzGuestUserInvitation] Starting guest user invitation process"
        
        # Ensure we have an access token
        if (-not $AccessToken) {
            Write-Verbose "[New-FinOpsAzGuestUserInvitation] No access token provided, attempting to get from Az context"
            try {
                $context = Get-AzContext -ErrorAction Stop
                if (-not $context) {
                    throw "No Azure context found. Please run Connect-AzAccount first."
                }
                
                $token = Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com" -ErrorAction Stop
                $AccessToken = $token.Token
                Write-Verbose "[New-FinOpsAzGuestUserInvitation] Successfully obtained access token from Az context"
            }
            catch {
                Write-Error "Failed to obtain Microsoft Graph access token. Please run Connect-AzAccount or provide an AccessToken parameter. Error: $_"
                return
            }
        }

        # If no email addresses provided, prompt interactively
        if (-not $EmailAddress) {
            Write-Host "`nEnter guest user details (press Enter with empty email to finish):" -ForegroundColor Cyan
            $emailList = @()
            $displayNameList = @()
            $index = 1

            do {
                $email = Read-Host "`nEmail Address [$index]"
                if (-not [string]::IsNullOrWhiteSpace($email)) {
                    # Validate email format
                    if ($email -notmatch '^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$') {
                        Write-Warning "Invalid email format: $email. Please try again."
                        continue
                    }
                    
                    $name = Read-Host "Display Name [$index]"
                    if ([string]::IsNullOrWhiteSpace($name)) {
                        $name = $email.Split('@')[0]
                        Write-Host "  Using email prefix as display name: $name" -ForegroundColor Yellow
                    }
                    
                    $emailList += $email
                    $displayNameList += $name
                    $index++
                }
            } while (-not [string]::IsNullOrWhiteSpace($email))

            if ($emailList.Count -eq 0) {
                Write-Warning "No email addresses provided. Exiting."
                return
            }

            $EmailAddress = $emailList
            $DisplayName = $displayNameList
            Write-Host "`nProcessing $($emailList.Count) guest user invitation(s)...`n" -ForegroundColor Green
        }
        # If DisplayName not provided but EmailAddress is, use email prefix as display name
        elseif (-not $DisplayName) {
            $DisplayName = $EmailAddress | ForEach-Object { $_.Split('@')[0] }
            Write-Verbose "[New-FinOpsAzGuestUserInvitation] No display names provided, using email prefixes"
        }
        # Ensure DisplayName and EmailAddress arrays are the same length
        elseif ($DisplayName.Count -ne $EmailAddress.Count) {
            Write-Error "The number of DisplayNames ($($DisplayName.Count)) must match the number of EmailAddresses ($($EmailAddress.Count))"
            return
        }

        $headers = @{
            'Authorization' = "Bearer $AccessToken"
            'Content-Type'  = 'application/json'
        }

        $results = @()
    }

    process {
        for ($i = 0; $i -lt $EmailAddress.Count; $i++) {
            try {
                $email = $EmailAddress[$i]
                $guestDisplayName = $DisplayName[$i]

                Write-Verbose "[New-FinOpsAzGuestUserInvitation] Processing invitation for: $email (Display Name: $guestDisplayName)"

                # Check if user already exists
                $checkUri = "https://graph.microsoft.com/v1.0/users?`$filter=mail eq '$email' or userPrincipalName eq '$email' or otherMails/any(x:x eq '$email')"
                
                Write-Verbose "[New-FinOpsAzGuestUserInvitation] Checking if user already exists..."
                $existingUsers = Invoke-RestMethod -Uri $checkUri -Headers $headers -Method Get -ErrorAction Stop

                if ($existingUsers.value -and $existingUsers.value.Count -gt 0) {
                    Write-Warning "User with email '$email' already exists in tenant (ID: $($existingUsers.value[0].id), Type: $($existingUsers.value[0].userType))"
                    
                    $result = [PSCustomObject]@{
                        Success         = $false
                        EmailAddress    = $email
                        DisplayName     = $guestDisplayName
                        UserId          = $existingUsers.value[0].id
                        UserType        = $existingUsers.value[0].userType
                        Message         = "User already exists in tenant"
                        AlreadyExists   = $true
                        InvitationSent  = $false
                    }
                    $results += $result
                    continue
                }

                # Prepare the invitation object
                $invitationObject = @{
                    invitedUserEmailAddress = $email
                    invitedUserDisplayName  = $guestDisplayName
                    inviteRedirectUrl       = $InviteRedirectUrl
                    sendInvitationMessage   = $SendInvitationMessage
                }

                # Always add the custom message (now has default value)
                $invitationObject['invitedUserMessageInfo'] = @{
                    customizedMessageBody = $CustomMessage
                }

                $body = $invitationObject | ConvertTo-Json -Depth 10

                if ($PSCmdlet.ShouldProcess($email, "Invite guest user to tenant")) {
                    Write-Verbose "[New-FinOpsAzGuestUserInvitation] Sending invitation via Microsoft Graph API..."
                    
                    $uri = "https://graph.microsoft.com/v1.0/invitations"
                    $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Post -Body $body -ErrorAction Stop

                    Write-Verbose "[New-FinOpsAzGuestUserInvitation] Successfully invited user: $($response.invitedUser.id)"
                    
                    $result = [PSCustomObject]@{
                        Success            = $true
                        EmailAddress       = $email
                        DisplayName        = $guestDisplayName
                        UserId             = $response.invitedUser.id
                        InviteRedeemUrl    = $response.inviteRedeemUrl
                        InvitationSent     = $SendInvitationMessage
                        Status             = $response.status
                        Message            = "Guest user invitation created successfully"
                    }

                    $results += $result
                }
                else {
                    Write-Verbose "[New-FinOpsAzGuestUserInvitation] WhatIf: Would invite guest user '$email' as '$guestDisplayName'"
                    $result = [PSCustomObject]@{
                        Success        = $true
                        EmailAddress   = $email
                        DisplayName    = $guestDisplayName
                        UserId         = "WhatIf-SimulatedId"
                        Message        = "WhatIf: User would be invited"
                        WhatIf         = $true
                    }
                    $results += $result
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
                
                Write-Error "Failed to invite guest user '$email': $errorMessage"
                
                $result = [PSCustomObject]@{
                    Success      = $false
                    EmailAddress = $email
                    DisplayName  = $guestDisplayName
                    Message      = "Failed to invite user: $errorMessage"
                    Error        = $errorMessage
                }
                $results += $result
            }
        }
    }

    end {
        Write-Verbose "[New-FinOpsAzGuestUserInvitation] Completed processing $($results.Count) invitation(s)"
        return $results
    }
}
