Import-Module Pester

# Use a relative path to the wrapper to avoid encoding issues with absolute paths
$wrapperPath = Join-Path -Path $PSScriptRoot -ChildPath '..\Public\Get-FinOpsJiraIssueSafe.ps1'

Describe 'Get-FinOpsJiraIssueSafe' {
    It 'returns visibility object when visibility check reports failure' {
    . $wrapperPath
        function Test-FinOpsJiraIssueVisibility { param($BaseUrl,$IssueKey,$Username,$ApiToken) @{ Success = $false; Error = 'NotFound' } }
        function Get-FinOpsJiraIssue { throw 'Should not be called' }

        $res = Get-FinOpsJiraIssueSafe -BaseUrl 'https://example.atlassian.net' -IssueKey 'FOO-1' -Username 'x@x.com' -ApiToken (ConvertTo-SecureString 'x' -AsPlainText -Force)

    ($res -is [hashtable]) | Should Be $true
    $res.Success | Should Be $false
    $res.Error | Should Be 'NotFound'
    }

    It 'returns raw issue on success when MapToOnboarding not set' {
    . $wrapperPath
        function Test-FinOpsJiraIssueVisibility { param($BaseUrl,$IssueKey,$Username,$ApiToken) @{ Success = $true } }
        function Get-FinOpsJiraIssue { param($BaseUrl,$IssueKey,$Username,$ApiToken) @{ key = 'FOO-2'; fields = @{ summary = 'Test' } } }

        $res = Get-FinOpsJiraIssueSafe -BaseUrl 'https://example.atlassian.net' -IssueKey 'FOO-2' -Username 'x@x.com' -ApiToken (ConvertTo-SecureString 'x' -AsPlainText -Force)

    $res.key | Should Be 'FOO-2'
    $res.fields.summary | Should Be 'Test'
    }

    It 'returns onboarding object when MapToOnboarding is set' {
    . $wrapperPath
        function Test-FinOpsJiraIssueVisibility { param($BaseUrl,$IssueKey,$Username,$ApiToken) @{ Success = $true } }
        function Get-FinOpsOnboardingFromJiraIssue { param($BaseUrl,$IssueKey,$Username,$ApiToken) @{ CustomerName = 'Acme'; TenantId = '1111' } }

        $res = Get-FinOpsJiraIssueSafe -BaseUrl 'https://example.atlassian.net' -IssueKey 'FOO-3' -Username 'x@x.com' -ApiToken (ConvertTo-SecureString 'x' -AsPlainText -Force) -MapToOnboarding

    $res.CustomerName | Should Be 'Acme'
    $res.TenantId | Should Be '1111'
    }
}
