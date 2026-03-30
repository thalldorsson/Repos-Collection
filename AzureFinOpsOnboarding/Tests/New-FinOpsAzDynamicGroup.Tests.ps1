# Basic functionality tests for New-FinOpsAzDynamicGroup and New-FinOpsAzGuestUserInvitation
# Note: These are structural tests only. Full integration tests require Microsoft Graph API access.

# Import the module
$modulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\AzureFinOpsOnboarding.psd1'
Import-Module $modulePath -Force

Describe 'New-FinOpsAzDynamicGroup' {
    It 'Function should be exported' {
        $cmd = Get-Command New-FinOpsAzDynamicGroup -ErrorAction SilentlyContinue
        $cmd.Name | Should -Be 'New-FinOpsAzDynamicGroup'
    }

    It 'Should have required CustomerName parameter' {
        $cmd = Get-Command New-FinOpsAzDynamicGroup
        $cmd.Parameters.ContainsKey('CustomerName') | Should -Be $true
    }

    It 'Should have required EmailDomain parameter' {
        $cmd = Get-Command New-FinOpsAzDynamicGroup
        $cmd.Parameters.ContainsKey('EmailDomain') | Should -Be $true
    }

    It 'Should support WhatIf' {
        $cmd = Get-Command New-FinOpsAzDynamicGroup
        $cmd.Parameters.ContainsKey('WhatIf') | Should -Be $true
    }
}

Describe 'New-FinOpsAzGuestUserInvitation' {
    It 'Function should be exported' {
        $cmd = Get-Command New-FinOpsAzGuestUserInvitation -ErrorAction SilentlyContinue
        $cmd.Name | Should -Be 'New-FinOpsAzGuestUserInvitation'
    }

    It 'Should have required EmailAddress parameter' {
        $cmd = Get-Command New-FinOpsAzGuestUserInvitation
        $cmd.Parameters.ContainsKey('EmailAddress') | Should -Be $true
    }

    It 'Should support WhatIf' {
        $cmd = Get-Command New-FinOpsAzGuestUserInvitation
        $cmd.Parameters.ContainsKey('WhatIf') | Should -Be $true
    }

    It 'Should accept array of email addresses' {
        $cmd = Get-Command New-FinOpsAzGuestUserInvitation
        $param = $cmd.Parameters['EmailAddress']
        $param.ParameterType.FullName | Should -Be 'System.String[]'
    }
}

