BeforeAll {
    $ModulePath = "$PSScriptRoot\..\..\Scripts\Modules\LogAnalyticsIngestion.psm1"
    Import-Module $ModulePath -Force
}

Describe "LogAnalyticsIngestion Module" {
    Context "Send-ToLogAnalytics" {
        It "Should construct authorization and send request" {
            $workspaceId = '00000000-0000-0000-0000-000000000000'
            $workspaceKey = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('unit-test-key-material'))
            $data = [pscustomobject]@{
                ComputerName = 'TEST-PC'
                Timestamp = (Get-Date).ToString('o')
                Severity = 'Critical'
            }

            Mock -CommandName Invoke-RestMethod -ModuleName LogAnalyticsIngestion -MockWith { @{ status = 'ok' } }
            Mock -CommandName Start-Sleep -ModuleName LogAnalyticsIngestion -MockWith {}

            { Send-ToLogAnalytics -Data $data -WorkspaceId $workspaceId -WorkspaceKey $workspaceKey -RetryCount 1 -Verbose } | Should -Not -Throw

            Should -Invoke -CommandName Invoke-RestMethod -ModuleName LogAnalyticsIngestion -Times 1 -ParameterFilter {
                $Method -eq 'POST' -and
                $Headers.Authorization -like "SharedKey $workspaceId:*" -and
                $Headers.'Log-Type' -eq 'WinREHealth' -and
                $Uri -like "https://$workspaceId.ods.opinsights.azure.com/*"
            }
        }

        It "Should throw for malformed workspace key" {
            $data = [pscustomobject]@{ ComputerName = 'TEST-PC'; Timestamp = (Get-Date).ToString('o') }

            { Send-ToLogAnalytics -Data $data -WorkspaceId 'workspace' -WorkspaceKey 'not-base64' -RetryCount 1 } | Should -Throw
        }
    }

    Context "Test-LogAnalyticsConnectivity" {
        It "Should return false for invalid base64 key" {
            $result = Test-LogAnalyticsConnectivity -WorkspaceId 'workspace' -WorkspaceKey 'invalid-base64' -SkipEndpointTest
            $result | Should -BeFalse
        }

        It "Should pass key format check for valid base64 key" {
            $workspaceKey = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('unit-test-key-material'))
            $result = Test-LogAnalyticsConnectivity -WorkspaceId 'workspace' -WorkspaceKey $workspaceKey -SkipEndpointTest
            $result | Should -BeTrue
        }
    }
}

AfterAll {
    Remove-Module LogAnalyticsIngestion -Force -ErrorAction SilentlyContinue
}
