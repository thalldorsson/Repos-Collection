Import-Module Pester

Describe 'Get-FinOpsJiraIssueSafe' {
    BeforeAll {
        Import-Module "$PSScriptRoot/../AzureFinOpsOnboarding.psd1" -Force
    }

    It 'returns visibility object when visibility check reports failure' {
        InModuleScope AzureFinOpsOnboarding {
            Mock Test-FinOpsJiraIssueVisibility { @{ Success = $false; Error = 'NotFound' } }
            Mock Get-FinOpsJiraIssue { throw 'Should not be called' }

            $res = Get-FinOpsJiraIssueSafe -BaseUrl 'https://example.atlassian.net' -IssueKey 'FOO-1' -Username 'x@x.com' -ApiToken (ConvertTo-SecureString 'x' -AsPlainText -Force)

            ($res -is [hashtable]) | Should -Be $true
            $res.Success | Should -Be $false
            $res.Error | Should -Be 'NotFound'
        }
    }

    It 'returns raw issue on success when MapToOnboarding not set' {
        InModuleScope AzureFinOpsOnboarding {
            Mock Test-FinOpsJiraIssueVisibility { @{ Success = $true } }
            Mock Get-FinOpsJiraIssue { @{ key = 'FOO-2'; fields = @{ summary = 'Test' } } }

            $res = Get-FinOpsJiraIssueSafe -BaseUrl 'https://example.atlassian.net' -IssueKey 'FOO-2' -Username 'x@x.com' -ApiToken (ConvertTo-SecureString 'x' -AsPlainText -Force)

            $res.key | Should -Be 'FOO-2'
            $res.fields.summary | Should -Be 'Test'
        }
    }

    It 'returns onboarding object when MapToOnboarding is set' {
        InModuleScope AzureFinOpsOnboarding {
            Mock Test-FinOpsJiraIssueVisibility { @{ Success = $true } }
            Mock Get-FinOpsOnboardingFromJiraIssue { @{ CustomerName = 'Acme'; TenantId = '1111' } }

            $res = Get-FinOpsJiraIssueSafe -BaseUrl 'https://example.atlassian.net' -IssueKey 'FOO-3' -Username 'x@x.com' -ApiToken (ConvertTo-SecureString 'x' -AsPlainText -Force) -MapToOnboarding

            $res.CustomerName | Should -Be 'Acme'
            $res.TenantId | Should -Be '1111'
        }
    }
}

