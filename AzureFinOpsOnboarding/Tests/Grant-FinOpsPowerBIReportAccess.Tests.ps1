Describe 'Grant-FinOpsPowerBIReportAccess' {
    BeforeAll {
        Import-Module "$PSScriptRoot/../AzureFinOpsOnboarding.psd1" -Force
    }

    It 'Is exported from the module' {
        $cmd = Get-Command Grant-FinOpsPowerBIReportAccess -ErrorAction SilentlyContinue
        $cmd | Should -Not -BeNullOrEmpty
        $cmd.CommandType | Should -Be 'Function'
    }

    Context 'Grants access and returns share link (mocked)' {
        It 'Returns object with expected properties' {
            InModuleScope AzureFinOpsOnboarding {
                # Mock all external dependencies to prevent any real calls
                Mock Install-Module { }
                Mock Import-Module { }
                Mock Get-Module { 
                    param($ListAvailable, $Name)
                    # Return module objects for any module check
                    [PSCustomObject]@{ Name = if ($Name) { $Name } else { 'MicrosoftPowerBIMgmt' } }
                }
                
                # Mock Power BI auth and calls - ensure token returns value to prevent Connect prompt
                Mock Get-PowerBIAccessToken { 'hdr.eyJ0aWQiOiAiMDAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDAwIn0.sig' }
                Mock Connect-PowerBIServiceAccount { }
                Mock Get-PowerBIWorkspace { [PSCustomObject]@{ Id = '11111111-1111-1111-1111-111111111111'; Name='WS' } }
                Mock Get-PowerBIReport { 
                    @([PSCustomObject]@{ 
                        Id='22222222-2222-2222-2222-222222222222'
                        Name='RPT'
                        WorkspaceId='11111111-1111-1111-1111-111111111111'
                    })
                }
                Mock Invoke-PowerBIRestMethod { 
                    param($Url,$Method,$Body,$ContentType)
                    if ($Url -like 'admin/groups*') {
                        return '{"value":[{"id":"11111111-1111-1111-1111-111111111111","name":"WS","reports":[{"id":"22222222-2222-2222-2222-222222222222"}]}]}'
                    }
                    # Return empty for POST to users endpoint
                    return $null
                }

                # Mock Graph group resolution - ensure context exists to prevent Connect prompt
                Mock Get-MgContext { @{ TenantId = '00000000-0000-0000-0000-000000000000'; Account = 'test@contoso.com' } }
                Mock Connect-MgGraph { }
                Mock Get-MgGroup { 
                    [PSCustomObject]@{ Id = '33333333-3333-3333-3333-333333333333'; DisplayName='FinOps-Customer-Australd2aa' }
                } -ModuleName 'Microsoft.Graph.Groups'
                
                $res = Grant-FinOpsPowerBIReportAccess -ReportName 'RPT' -EntraGroup 'FinOps-Customer-Australd2aa' -AccessRight Read -PassThru
                $res | Should -Not -BeNullOrEmpty
                $res.ReportId | Should -Be '22222222-2222-2222-2222-222222222222'
                $res.WorkspaceId | Should -Be '11111111-1111-1111-1111-111111111111'
                $res.GrantedToId | Should -Be '33333333-3333-3333-3333-333333333333'
                $res.ShareLink | Should -Match 'https://app.powerbi.com/groups/11111111-1111-1111-1111-111111111111/reports/22222222-2222-2222-2222-222222222222'
            }
        }
    }
}

