Describe 'Test-FinOpsConfiguration' {
    BeforeAll {
        Import-Module "$PSScriptRoot/../AzureFinOpsOnboarding.psd1" -Force
        
        # Create a temp directory for test configs - accessible within InModuleScope
        $global:testConfigDir = Join-Path $TestDrive 'config-tests'
        New-Item -Path $global:testConfigDir -ItemType Directory -Force | Out-Null
    }
    
    AfterAll {
        Remove-Variable -Name testConfigDir -Scope Global -ErrorAction SilentlyContinue
    }

    Context 'File existence validation' {
        It 'Should fail when config file does not exist' {
            InModuleScope AzureFinOpsOnboarding {
                $result = Test-FinOpsConfiguration -ConfigPath "$($global:testConfigDir)\nonexistent.json"
                $result | Should -Be $false
            }
        }

        It 'Should pass when config file exists and is valid JSON' {
            InModuleScope AzureFinOpsOnboarding {
                $configPath = Join-Path $global:testConfigDir 'valid-minimal.json'
                @{
                    defaultTenantId = '12345678-1234-1234-1234-123456789012'
                } | ConvertTo-Json | Set-Content -Path $configPath
                
                $result = Test-FinOpsConfiguration -ConfigPath $configPath
                $result | Should -Be $true
            }
        }

        It 'Should fail when config file contains invalid JSON' {
            InModuleScope AzureFinOpsOnboarding {
                $configPath = Join-Path $global:testConfigDir 'invalid.json'
                '{ "key": "value" INVALID }' | Set-Content -Path $configPath
                
                $result = Test-FinOpsConfiguration -ConfigPath $configPath
                $result | Should -Be $false
            }
        }
    }

    Context 'GUID validation' {
        It 'Should pass with valid tenant ID GUID' {
            InModuleScope AzureFinOpsOnboarding {
                $configPath = Join-Path $global:testConfigDir 'valid-guid.json'
                @{
                    defaultTenantId = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
                } | ConvertTo-Json | Set-Content -Path $configPath
                
                $result = Test-FinOpsConfiguration -ConfigPath $configPath
                $result | Should -Be $true
            }
        }

        It 'Should fail with invalid tenant ID format' {
            InModuleScope AzureFinOpsOnboarding {
                $configPath = Join-Path $global:testConfigDir 'invalid-guid.json'
                @{
                    defaultTenantId = 'not-a-valid-guid'
                } | ConvertTo-Json | Set-Content -Path $configPath
                
                $result = Test-FinOpsConfiguration -ConfigPath $configPath
                $result | Should -Be $false
            }
        }
    }

    Context 'Output directory validation' {
        It 'Should pass with existing parent directory' {
            InModuleScope AzureFinOpsOnboarding {
                $configPath = Join-Path $global:testConfigDir 'valid-output-dir.json'
                $existingDir = $global:testConfigDir
                @{
                    defaultTenantId = '12345678-1234-1234-1234-123456789012'
                    outputDirectory = "$existingDir\output"
                } | ConvertTo-Json | Set-Content -Path $configPath
                
                $result = Test-FinOpsConfiguration -ConfigPath $configPath
                $result | Should -Be $true
            }
        }

        It 'Should pass with relative path' {
            InModuleScope AzureFinOpsOnboarding {
                $configPath = Join-Path $global:testConfigDir 'relative-output.json'
                @{
                    defaultTenantId = '12345678-1234-1234-1234-123456789012'
                    outputDirectory = '.\output'
                } | ConvertTo-Json | Set-Content -Path $configPath
                
                $result = Test-FinOpsConfiguration -ConfigPath $configPath
                $result | Should -Be $true
            }
        }
    }

    Context 'Cost lookback validation' {
        It 'Should pass with valid positive integer' {
            InModuleScope AzureFinOpsOnboarding {
                $configPath = Join-Path $global:testConfigDir 'valid-lookback.json'
                @{
                    defaultTenantId = '12345678-1234-1234-1234-123456789012'
                    costLookback = @{ months = 6 }
                } | ConvertTo-Json | Set-Content -Path $configPath
                
                $result = Test-FinOpsConfiguration -ConfigPath $configPath
                $result | Should -Be $true
            }
        }

        It 'Should fail with non-integer months value' {
            InModuleScope AzureFinOpsOnboarding {
                $configPath = Join-Path $global:testConfigDir 'invalid-lookback.json'
                @{
                    defaultTenantId = '12345678-1234-1234-1234-123456789012'
                    costLookback = @{ months = 'six' }
                } | ConvertTo-Json | Set-Content -Path $configPath
                
                $result = Test-FinOpsConfiguration -ConfigPath $configPath
                $result | Should -Be $false
            }
        }
    }

    Context 'Jira URL validation' {
        It 'Should pass with valid HTTPS URL' {
            InModuleScope AzureFinOpsOnboarding {
                $configPath = Join-Path $global:testConfigDir 'valid-jira-https.json'
                @{
                    defaultTenantId = '12345678-1234-1234-1234-123456789012'
                    jiraBaseUrl = 'https://jira.example.com'
                } | ConvertTo-Json | Set-Content -Path $configPath
                
                $result = Test-FinOpsConfiguration -ConfigPath $configPath
                $result | Should -Be $true
            }
        }

        It 'Should pass with valid HTTP URL' {
            InModuleScope AzureFinOpsOnboarding {
                $configPath = Join-Path $global:testConfigDir 'valid-jira-http.json'
                @{
                    defaultTenantId = '12345678-1234-1234-1234-123456789012'
                    jiraBaseUrl = 'http://jira.internal.local'
                } | ConvertTo-Json | Set-Content -Path $configPath
                
                $result = Test-FinOpsConfiguration -ConfigPath $configPath
                $result | Should -Be $true
            }
        }

        It 'Should fail with invalid URL format' {
            InModuleScope AzureFinOpsOnboarding {
                $configPath = Join-Path $global:testConfigDir 'invalid-jira-url.json'
                @{
                    defaultTenantId = '12345678-1234-1234-1234-123456789012'
                    jiraBaseUrl = 'jira.example.com'
                } | ConvertTo-Json | Set-Content -Path $configPath
                
                $result = Test-FinOpsConfiguration -ConfigPath $configPath
                $result | Should -Be $false
            }
        }
    }

    Context 'Key Vault name validation' {
        It 'Should pass with valid Key Vault name' {
            InModuleScope AzureFinOpsOnboarding {
                $configPath = Join-Path $global:testConfigDir 'valid-keyvault.json'
                @{
                    defaultTenantId = '12345678-1234-1234-1234-123456789012'
                    keyVaultName = 'my-keyvault-123'
                } | ConvertTo-Json | Set-Content -Path $configPath
                
                $result = Test-FinOpsConfiguration -ConfigPath $configPath
                $result | Should -Be $true
            }
        }

        It 'Should fail with Key Vault name too short' {
            InModuleScope AzureFinOpsOnboarding {
                $configPath = Join-Path $global:testConfigDir 'keyvault-too-short.json'
                @{
                    defaultTenantId = '12345678-1234-1234-1234-123456789012'
                    keyVaultName = 'kv'
                } | ConvertTo-Json | Set-Content -Path $configPath
                
                $result = Test-FinOpsConfiguration -ConfigPath $configPath
                $result | Should -Be $false
            }
        }

        It 'Should fail with Key Vault name too long' {
            InModuleScope AzureFinOpsOnboarding {
                $configPath = Join-Path $global:testConfigDir 'keyvault-too-long.json'
                @{
                    defaultTenantId = '12345678-1234-1234-1234-123456789012'
                    keyVaultName = 'this-key-vault-name-is-way-too-long-to-be-valid'
                } | ConvertTo-Json | Set-Content -Path $configPath
                
                $result = Test-FinOpsConfiguration -ConfigPath $configPath
                $result | Should -Be $false
            }
        }

        It 'Should fail with Key Vault name containing invalid characters' {
            InModuleScope AzureFinOpsOnboarding {
                $configPath = Join-Path $global:testConfigDir 'keyvault-invalid-chars.json'
                @{
                    defaultTenantId = '12345678-1234-1234-1234-123456789012'
                    keyVaultName = 'my_keyvault'
                } | ConvertTo-Json | Set-Content -Path $configPath
                
                $result = Test-FinOpsConfiguration -ConfigPath $configPath
                $result | Should -Be $false
            }
        }
    }

    Context 'Comprehensive validation' {
        It 'Should pass with complete valid configuration' {
            InModuleScope AzureFinOpsOnboarding {
                $configPath = Join-Path $global:testConfigDir 'complete-valid.json'
                @{
                    defaultTenantId = '12345678-1234-1234-1234-123456789012'
                    outputDirectory = '.\output'
                    costLookback = @{ months = 6 }
                    jiraBaseUrl = 'https://jira.example.com'
                    keyVaultName = 'finops-keyvault'
                    secrets = @{
                        powerBiTenantId = 'secret-ref-1'
                        powerBiApplicationId = 'secret-ref-2'
                        powerBiClientSecret = 'secret-ref-3'
                        jiraApiToken = 'secret-ref-4'
                    }
                } | ConvertTo-Json | Set-Content -Path $configPath
                
                $result = Test-FinOpsConfiguration -ConfigPath $configPath
                $result | Should -Be $true
            }
        }

        It 'Should fail with multiple validation errors' {
            InModuleScope AzureFinOpsOnboarding {
                $configPath = Join-Path $global:testConfigDir 'multiple-errors.json'
                @{
                    defaultTenantId = 'invalid-guid'
                    costLookback = @{ months = 'six' }
                    jiraBaseUrl = 'not-a-url'
                    keyVaultName = 'kv'
                } | ConvertTo-Json | Set-Content -Path $configPath
                
                $result = Test-FinOpsConfiguration -ConfigPath $configPath
                $result | Should -Be $false
            }
        }
    }

    Context 'Connectivity validation' {
        It 'Should attempt Azure connectivity check when switch is provided' {
            InModuleScope AzureFinOpsOnboarding {
                Mock Get-AzContext { return $null }
                
                $configPath = Join-Path $global:testConfigDir 'connectivity-test.json'
                @{
                    defaultTenantId = '12345678-1234-1234-1234-123456789012'
                } | ConvertTo-Json | Set-Content -Path $configPath
                
                $result = Test-FinOpsConfiguration -ConfigPath $configPath -ValidateConnectivity
                
                # Should still pass structure validation even if not connected
                $result | Should -Be $true
                Assert-MockCalled Get-AzContext -Exactly 1
            }
        }

        It 'Should not check connectivity without switch' {
            InModuleScope AzureFinOpsOnboarding {
                Mock Get-AzContext { return $null }
                
                $configPath = Join-Path $global:testConfigDir 'no-connectivity-test.json'
                @{
                    defaultTenantId = '12345678-1234-1234-1234-123456789012'
                } | ConvertTo-Json | Set-Content -Path $configPath
                
                $result = Test-FinOpsConfiguration -ConfigPath $configPath
                
                $result | Should -Be $true
                Assert-MockCalled Get-AzContext -Exactly 0
            }
        }
    }
}

