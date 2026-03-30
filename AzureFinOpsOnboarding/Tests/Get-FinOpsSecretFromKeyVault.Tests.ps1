Describe 'Get-FinOpsSecretFromKeyVault' {
    BeforeAll {
        Import-Module "$PSScriptRoot/../AzureFinOpsOnboarding.psd1" -Force
    }

    It 'Is exported from the module' {
        $cmd = Get-Command Get-FinOpsSecretFromKeyVault -ErrorAction SilentlyContinue
        $cmd | Should -Not -BeNullOrEmpty
        $cmd.CommandType | Should -Be 'Function'
    }

    Context 'Parameter Validation' {
        It 'Should have mandatory KeyVaultName parameter' {
            $cmd = Get-Command Get-FinOpsSecretFromKeyVault
            $param = $cmd.Parameters['KeyVaultName']
            $param | Should -Not -BeNullOrEmpty
            $param.Attributes.Mandatory | Should -Contain $true
        }

        It 'Should have mandatory SecretName parameter' {
            $cmd = Get-Command Get-FinOpsSecretFromKeyVault
            $param = $cmd.Parameters['SecretName']
            $param | Should -Not -BeNullOrEmpty
            $param.Attributes.Mandatory | Should -Contain $true
        }

        It 'Should validate TenantId as GUID format' {
            $cmd = Get-Command Get-FinOpsSecretFromKeyVault
            $param = $cmd.Parameters['TenantId']
            $param | Should -Not -BeNullOrEmpty
            $param.Attributes.RegexPattern | Should -Match 'fA-F.*0-9'
        }

        It 'Should validate ApplicationId as GUID format' {
            $cmd = Get-Command Get-FinOpsSecretFromKeyVault
            $param = $cmd.Parameters['ApplicationId']
            $param | Should -Not -BeNullOrEmpty
            $param.Attributes.RegexPattern | Should -Match 'fA-F.*0-9'
        }

        It 'Should have AsPlainText switch parameter' {
            $cmd = Get-Command Get-FinOpsSecretFromKeyVault
            $param = $cmd.Parameters['AsPlainText']
            $param | Should -Not -BeNullOrEmpty
            $param.SwitchParameter | Should -Be $true
        }
    }

    Context 'Managed Identity Authentication' {
        It 'Should use Managed Identity when UseManagedIdentity is specified' {
            InModuleScope AzureFinOpsOnboarding {
                Mock Get-Module { [PSCustomObject]@{ Name = 'Az.KeyVault' } }
                Mock Import-Module { }
                Mock Get-AzContext { $null }
                Mock Connect-AzAccount { [PSCustomObject]@{ Account = @{ Type = 'ManagedService' } } }
                Mock Get-AzKeyVaultSecret {
                    [PSCustomObject]@{
                        SecretValue = (ConvertTo-SecureString 'test-secret-value' -AsPlainText -Force)
                    }
                }
                
                $result = Get-FinOpsSecretFromKeyVault `
                    -KeyVaultName 'test-vault' `
                    -SecretName 'test-secret' `
                    -UseManagedIdentity
                
                $result | Should -Not -BeNullOrEmpty
                $result.GetType().Name | Should -Be 'SecureString'
                Assert-MockCalled Connect-AzAccount -Times 1
            }
        }

        It 'Should skip connection if already authenticated with Managed Identity' {
            InModuleScope AzureFinOpsOnboarding {
                Mock Get-Module { [PSCustomObject]@{ Name = 'Az.KeyVault' } }
                Mock Import-Module { }
                Mock Get-AzContext {
                    [PSCustomObject]@{
                        Account = @{ Type = 'ManagedService'; Id = 'system-assigned-id' }
                    }
                }
                Mock Connect-AzAccount { }
                Mock Get-AzKeyVaultSecret {
                    [PSCustomObject]@{
                        SecretValue = (ConvertTo-SecureString 'test-value' -AsPlainText -Force)
                    }
                }
                
                Get-FinOpsSecretFromKeyVault `
                    -KeyVaultName 'test-vault' `
                    -SecretName 'test-secret' `
                    -UseManagedIdentity
                
                Assert-MockCalled Connect-AzAccount -Times 0
            }
        }
    }

    Context 'Service Principal Authentication' {
        It 'Should use Service Principal credentials when provided' {
            InModuleScope AzureFinOpsOnboarding {
                Mock Get-Module { [PSCustomObject]@{ Name = 'Az.KeyVault' } }
                Mock Import-Module { }
                Mock Get-AzContext { $null }
                Mock Connect-AzAccount { [PSCustomObject]@{ Account = @{ Id = '11111111-1111-1111-1111-111111111111' } } }
                Mock Get-AzKeyVaultSecret {
                    [PSCustomObject]@{
                        SecretValue = (ConvertTo-SecureString 'sp-secret-value' -AsPlainText -Force)
                    }
                }
                
                $clientSecret = ConvertTo-SecureString 'client-secret' -AsPlainText -Force
                
                $result = Get-FinOpsSecretFromKeyVault `
                    -KeyVaultName 'test-vault' `
                    -SecretName 'test-secret' `
                    -TenantId '00000000-0000-0000-0000-000000000000' `
                    -ApplicationId '11111111-1111-1111-1111-111111111111' `
                    -ClientSecret $clientSecret
                
                $result | Should -Not -BeNullOrEmpty
                Assert-MockCalled Connect-AzAccount -Times 1
            }
        }
    }

    Context 'Secret Retrieval' {
        It 'Should return SecureString by default' {
            InModuleScope AzureFinOpsOnboarding {
                Mock Get-Module { [PSCustomObject]@{ Name = 'Az.KeyVault' } }
                Mock Import-Module { }
                Mock Get-AzContext { [PSCustomObject]@{ Account = @{ Type = 'ManagedService' } } }
                Mock Get-AzKeyVaultSecret {
                    [PSCustomObject]@{
                        SecretValue = (ConvertTo-SecureString 'secure-value' -AsPlainText -Force)
                    }
                }
                
                $result = Get-FinOpsSecretFromKeyVault `
                    -KeyVaultName 'vault1' `
                    -SecretName 'secret1' `
                    -UseManagedIdentity
                
                $result | Should -Not -BeNullOrEmpty
                $result.GetType().Name | Should -Be 'SecureString'
            }
        }

        It 'Should return plain text when AsPlainText is specified' {
            InModuleScope AzureFinOpsOnboarding {
                Mock Get-Module { [PSCustomObject]@{ Name = 'Az.KeyVault' } }
                Mock Import-Module { }
                Mock Get-AzContext { [PSCustomObject]@{ Account = @{ Type = 'ManagedService' } } }
                Mock Get-AzKeyVaultSecret {
                    [PSCustomObject]@{
                        SecretValue = (ConvertTo-SecureString 'plain-text-value' -AsPlainText -Force)
                    }
                }
                
                $result = Get-FinOpsSecretFromKeyVault `
                    -KeyVaultName 'vault1' `
                    -SecretName 'secret1' `
                    -UseManagedIdentity `
                    -AsPlainText
                
                $result | Should -Not -BeNullOrEmpty
                $result.GetType().Name | Should -Be 'String'
                $result | Should -Be 'plain-text-value'
            }
        }

        It 'Should return null and write error when secret not found' {
            InModuleScope AzureFinOpsOnboarding {
                Mock Get-Module { [PSCustomObject]@{ Name = 'Az.KeyVault' } }
                Mock Import-Module { }
                Mock Get-AzContext { [PSCustomObject]@{ Account = @{ Type = 'ManagedService' } } }
                Mock Get-AzKeyVaultSecret { $null }
                Mock Write-Error { }
                
                $result = Get-FinOpsSecretFromKeyVault `
                    -KeyVaultName 'vault1' `
                    -SecretName 'nonexistent' `
                    -UseManagedIdentity `
                    -ErrorAction SilentlyContinue
                
                $result | Should -BeNullOrEmpty
                Assert-MockCalled Write-Error -Times 1
            }
        }
    }

    Context 'Module Installation' {
        It 'Should install Az.KeyVault if not available' {
            InModuleScope AzureFinOpsOnboarding {
                Mock Get-Module -ParameterFilter { $ListAvailable -and $Name -eq 'Az.KeyVault' } { $null }
                Mock Install-Module { }
                Mock Import-Module { }
                Mock Get-AzContext { [PSCustomObject]@{ Account = @{ Type = 'ManagedService' } } }
                Mock Get-AzKeyVaultSecret {
                    [PSCustomObject]@{
                        SecretValue = (ConvertTo-SecureString 'value' -AsPlainText -Force)
                    }
                }
                
                Get-FinOpsSecretFromKeyVault `
                    -KeyVaultName 'vault1' `
                    -SecretName 'secret1' `
                    -UseManagedIdentity
                
                Should -Invoke Install-Module -Times 1
            }
        }

        It 'Should not install Az.KeyVault if already available' {
            InModuleScope AzureFinOpsOnboarding {
                Mock Get-Module -ParameterFilter { $ListAvailable -and $Name -eq 'Az.KeyVault' } { 
                    [PSCustomObject]@{ Name = 'Az.KeyVault'; Version = '4.0.0' }
                }
                Mock Install-Module { }
                Mock Import-Module { }
                Mock Get-AzContext { [PSCustomObject]@{ Account = @{ Type = 'ManagedService' } } }
                Mock Get-AzKeyVaultSecret {
                    [PSCustomObject]@{
                        SecretValue = (ConvertTo-SecureString 'value' -AsPlainText -Force)
                    }
                }
                
                Get-FinOpsSecretFromKeyVault `
                    -KeyVaultName 'vault1' `
                    -SecretName 'secret1' `
                    -UseManagedIdentity
                
                Should -Invoke Install-Module -Times 0
            }
        }
    }
}
