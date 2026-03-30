<#
.SYNOPSIS
    Example script demonstrating dynamic group creation and guest user invitation.

.DESCRIPTION
    This script shows how to use the New-FinOpsAzDynamicGroup and 
    New-FinOpsAzGuestUserInvitation functions for customer onboarding.

.NOTES
    Author: Crayon FinOps
    Requirements:
    - Az.Accounts module installed
    - Connected to Azure (Connect-AzAccount)
    - Microsoft Graph API permissions:
      * Group.ReadWrite.All (for dynamic groups)
      * User.Invite.All (for guest invitations)
      * GroupMember.ReadWrite.All (optional, for adding guests to groups)
#>

# Import the module
Import-Module .\AzureFinOpsOnboarding.psd1 -Force

# Optional: Configure default tenant (dynamic group creation will auto-connect)
# Set-FinOpsTenantId -TenantId "12345678-1234-1234-1234-123456789012"

# Or connect manually to Azure
# Connect-AzAccount

# Example 1: Create a dynamic group for a customer
Write-Host "`n=== Example 1: Creating Dynamic Group ===" -ForegroundColor Cyan

$dynamicGroupParams = @{
    CustomerName = "Contoso"
    EmailDomain  = "contoso.com"
    Description  = "FinOps dynamic group for Contoso - Auto-populated based on UPN domain"
    Verbose      = $true
}

$groupResult = New-FinOpsAzDynamicGroup @dynamicGroupParams

if ($groupResult.Success) {
    Write-Host "✓ Dynamic group created successfully!" -ForegroundColor Green
    Write-Host "  Group Name: $($groupResult.GroupName)" -ForegroundColor Gray
    Write-Host "  Group ID: $($groupResult.GroupId)" -ForegroundColor Gray
    Write-Host "  Membership Rule: $($groupResult.MembershipRule)" -ForegroundColor Gray
} else {
    Write-Host "✗ Failed to create group: $($groupResult.Message)" -ForegroundColor Red
}

# Example 2A: Invite guest users interactively (will prompt for emails and display names)
Write-Host "`n=== Example 2A: Inviting Guest Users (Interactive) ===" -ForegroundColor Cyan

$invitationResults = New-FinOpsAzGuestUserInvitation -Verbose
# Will prompt:
#   Enter guest user email address (or press Enter to finish):
#   Enter display name for user@domain.com (or press Enter to use 'user'):

# Example 2B: Invite guest users with parameters
Write-Host "`n=== Example 2B: Inviting Guest Users (With Parameters) ===" -ForegroundColor Cyan

$guestInvites = @(
    "john.doe@contoso.com"
    "jane.smith@contoso.com"
)

$displayNames = @(
    "John Doe"
    "Jane Smith"
)

$invitationParams = @{
    EmailAddress          = $guestInvites
    DisplayName           = $displayNames
    InviteRedirectUrl     = "https://portal.azure.com"
    SendInvitationMessage = $true
    CustomMessage         = "Welcome to our FinOps portal! You've been invited to collaborate on Azure cost management."
    Verbose               = $true
}

$invitationResults = New-FinOpsAzGuestUserInvitation @invitationParams

foreach ($result in $invitationResults) {
    if ($result.Success) {
        Write-Host "✓ Invited: $($result.DisplayName) ($($result.EmailAddress))" -ForegroundColor Green
        Write-Host "  User ID: $($result.UserId)" -ForegroundColor Gray
        Write-Host "  Redeem URL: $($result.InviteRedeemUrl)" -ForegroundColor Gray
    } elseif ($result.AlreadyExists) {
        Write-Host "⚠ Already exists: $($result.DisplayName) ($($result.EmailAddress))" -ForegroundColor Yellow
    } else {
        Write-Host "✗ Failed: $($result.DisplayName) ($($result.EmailAddress)) - $($result.Message)" -ForegroundColor Red
    }
}

# Example 3: Create group and invite users
Write-Host "`n=== Example 3: Combined Workflow ===" -ForegroundColor Cyan

# Step 1: Create dynamic group
$groupResult = New-FinOpsAzDynamicGroup -CustomerName "Fabrikam" -EmailDomain "fabrikam.com" -Verbose

if ($groupResult.Success -and -not $groupResult.AlreadyExists) {
    Write-Host "✓ Created group: $($groupResult.GroupName)" -ForegroundColor Green
    
    # Step 2: Invite guest users (they will be automatically added to the group if their UPN matches)
    $guestEmails = @("partner1@fabrikam.com", "partner2@fabrikam.com")
    $guestNames = @("Partner One", "Partner Two")
    
    $results = New-FinOpsAzGuestUserInvitation -EmailAddress $guestEmails `
        -DisplayName $guestNames `
        -CustomMessage "Welcome! You've been invited to collaborate on FinOps." `
        -Verbose
    
    $successCount = ($results | Where-Object { $_.Success }).Count
    Write-Host "✓ Successfully invited $successCount out of $($guestEmails.Count) users" -ForegroundColor Green
    Write-Host "ℹ Users will be automatically added to the dynamic group when their UPN matches the rule" -ForegroundColor Cyan
}

# Example 4: Using WhatIf to preview changes
Write-Host "`n=== Example 4: Using WhatIf ===" -ForegroundColor Cyan

New-FinOpsAzDynamicGroup -CustomerName "TestCustomer" -EmailDomain "test.com" -WhatIf
New-FinOpsAzGuestUserInvitation -EmailAddress "test@example.com" -DisplayName "Test User" -WhatIf

Write-Host "`n=== Examples Complete ===" -ForegroundColor Cyan
