Describe 'Grant-FinOpsPowerBIReportAccess' {
    BeforeAll {
        Import-Module "$PSScriptRoot/../AzureFinOpsOnboarding.psd1" -Force
    }

    It 'Is exported from the module' {
        $cmd = Get-Command Grant-FinOpsPowerBIReportAccess -ErrorAction SilentlyContinue
        $cmd | Should Not BeNullOrEmpty
        $cmd.CommandType | Should Be 'Function'
    }

    Context 'Grants access and returns share link (mocked)' {
        $graphAvailable = [bool](Get-Command Get-MgGroup -ErrorAction SilentlyContinue)
        $pbiAvailable = [bool](Get-Command Get-PowerBIAccessToken -ErrorAction SilentlyContinue)

        BeforeEach {
            if ($graphAvailable -and $pbiAvailable) {
                InModuleScope AzureFinOpsOnboarding {
                    # Mock Power BI auth and calls
                    Mock Get-PowerBIAccessToken { return 'hdr.eyJ0aWQiOiAiMDAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDAwIn0.sig' }
                    Mock Connect-PowerBIServiceAccount { }
                    Mock Get-PowerBIWorkspace { [PSCustomObject]@{ Id = '11111111-1111-1111-1111-111111111111'; Name='WS' } }
                    Mock Get-PowerBIReport { [PSCustomObject]@{ Id='22222222-2222-2222-2222-222222222222'; Name='RPT'; WorkspaceId='11111111-1111-1111-1111-111111111111' } }
                    Mock Invoke-PowerBIRestMethod { }

                    # Mock Graph group resolution
                    Mock Import-Module { }
                    Mock Get-MgContext { return @{ TenantId = '00000000-0000-0000-0000-000000000000' } }
                    Mock Connect-MgGraph { }
                    Mock Get-MgGroup { [PSCustomObject]@{ Id = '33333333-3333-3333-3333-333333333333'; DisplayName='FinOps-Customer-Australd2aa' } }
                }
            }
        }

        It 'Returns object with expected properties' -Skip:(!($graphAvailable -and $pbiAvailable)) {
            InModuleScope AzureFinOpsOnboarding {
                $res = Grant-FinOpsPowerBIReportAccess -ReportName 'RPT' -EntraGroup 'FinOps-Customer-Australd2aa' -AccessRight Read -PassThru
                $res | Should Not BeNullOrEmpty
                $res.ReportId | Should Be '22222222-2222-2222-2222-222222222222'
                $res.WorkspaceId | Should Be '11111111-1111-1111-1111-111111111111'
                $res.GrantedToId | Should Be '33333333-3333-3333-3333-333333333333'
                $res.ShareLink | Should Match 'https://app.powerbi.com/groups/11111111-1111-1111-1111-111111111111/reports/22222222-2222-2222-2222-222222222222'
            }
        }
    }
}
