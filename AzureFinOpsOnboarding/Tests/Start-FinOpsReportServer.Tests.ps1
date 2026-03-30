Describe 'Start-FinOpsReportServer' {
    BeforeAll {
        Import-Module "$PSScriptRoot/../AzureFinOpsOnboarding.psd1" -Force
    }

    It 'Is exported from the module' {
        $cmd = Get-Command Start-FinOpsReportServer -ErrorAction SilentlyContinue
        $cmd | Should -Not -BeNullOrEmpty
        $cmd.CommandType | Should -Be 'Function'
    }

    Context 'Parameter Validation' {
        It 'Should have Port parameter with valid range' {
            $cmd = Get-Command Start-FinOpsReportServer
            $portParam = $cmd.Parameters['Port']
            $portParam | Should -Not -BeNullOrEmpty
            $portParam.ParameterType.Name | Should -Be 'Int32'
        }

        It 'Should have AutoOpen switch parameter' {
            $cmd = Get-Command Start-FinOpsReportServer
            $autoOpenParam = $cmd.Parameters['AutoOpen']
            $autoOpenParam | Should -Not -BeNullOrEmpty
            $autoOpenParam.SwitchParameter | Should -Be $true
        }

        It 'Should accept OrchestratorObject from pipeline' {
            $cmd = Get-Command Start-FinOpsReportServer
            $objParam = $cmd.Parameters['OrchestratorObject']
            $objParam | Should -Not -BeNullOrEmpty
            $objParam.Attributes.ValueFromPipeline | Should -Contain $true
        }
    }

    Context 'Pode Module Handling' {
        It 'Should check for Pode module availability' {
            InModuleScope AzureFinOpsOnboarding {
                Mock Get-Module -ParameterFilter { $ListAvailable -and $Name -eq 'Pode' } { $null }
                Mock Install-Module { }
                Mock Import-Module { }
                Mock Start-PodeServer { }
                
                # Should not throw when Pode is missing (installs it)
                { Start-FinOpsReportServer -Port 8081 -ErrorAction Stop } | Should -Not -Throw
            }
        }

        It 'Should import Pode module if already installed' {
            InModuleScope AzureFinOpsOnboarding {
                Mock Get-Module -ParameterFilter { $ListAvailable -and $Name -eq 'Pode' } { 
                    [PSCustomObject]@{ Name = 'Pode'; Version = '2.0.0' }
                }
                Mock Import-Module { }
                Mock Start-PodeServer { }
                
                { Start-FinOpsReportServer -Port 8082 -ErrorAction Stop } | Should -Not -Throw
                Should -Invoke Import-Module -Times 1
            }
        }
    }

    Context 'Server Instance' {
        It 'Should return server object with expected properties' {
            InModuleScope AzureFinOpsOnboarding {
                Mock Get-Module -ParameterFilter { $ListAvailable -and $Name -eq 'Pode' } { 
                    [PSCustomObject]@{ Name = 'Pode' }
                }
                Mock Import-Module { }
                Mock Start-PodeServer {
                    return [PSCustomObject]@{ State = 'Running' }
                }
                Mock Start-Process { }
                
                $mockReport = [PSCustomObject]@{
                    Customer = @{ Name = 'Test'; PrimaryDomain = 'test.com' }
                    Identifiers = @{ TenantId = '00000000-0000-0000-0000-000000000000'; SubscriptionCount = 2 }
                    Checks = @()
                    ModuleVersion = '1.2.0'
                }
                
                $result = Start-FinOpsReportServer -OrchestratorObject $mockReport -Port 8083
                
                $result | Should -Not -BeNullOrEmpty
                $result.Url | Should -Match 'http://localhost:\d+'
                $result.Port | Should -Be 8083
                $result.Stop | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'Auto-Open Browser' {
        It 'Should open browser when AutoOpen is specified' {
            InModuleScope AzureFinOpsOnboarding {
                Mock Get-Module -ParameterFilter { $ListAvailable -and $Name -eq 'Pode' } { 
                    [PSCustomObject]@{ Name = 'Pode' }
                }
                Mock Import-Module { }
                Mock Start-PodeServer { }
                Mock Start-Process { } -Verifiable
                
                $mockReport = [PSCustomObject]@{
                    Customer = @{ Name = 'Test'; PrimaryDomain = 'test.com' }
                    Identifiers = @{ TenantId = '00000000-0000-0000-0000-000000000000' }
                    Checks = @()
                }
                
                Start-FinOpsReportServer -OrchestratorObject $mockReport -Port 8084 -AutoOpen
                
                Should -Invoke Start-Process -Times 1
            }
        }

        It 'Should not open browser when AutoOpen is not specified' {
            InModuleScope AzureFinOpsOnboarding {
                Mock Get-Module -ParameterFilter { $ListAvailable -and $Name -eq 'Pode' } { 
                    [PSCustomObject]@{ Name = 'Pode' }
                }
                Mock Import-Module { }
                Mock Start-PodeServer { }
                Mock Start-Process { }
                
                $mockReport = [PSCustomObject]@{
                    Customer = @{ Name = 'Test'; PrimaryDomain = 'test.com' }
                    Identifiers = @{ TenantId = '00000000-0000-0000-0000-000000000000' }
                    Checks = @()
                }
                
                Start-FinOpsReportServer -OrchestratorObject $mockReport -Port 8085
                
                Should -Invoke Start-Process -Times 0
            }
        }
    }
}
