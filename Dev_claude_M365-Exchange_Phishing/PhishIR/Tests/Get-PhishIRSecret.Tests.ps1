#Requires -Module Pester

BeforeAll {
    # Import module
    $moduleRoot = Join-Path -Path $PSScriptRoot -ChildPath '..'
    $modulePath = Join-Path -Path $moduleRoot -ChildPath 'PhishIR.psd1'
    Import-Module $modulePath -Force
    
    # Dot-source private function under test
    $privateDir = Join-Path -Path $moduleRoot -ChildPath 'Private'
    . (Join-Path -Path $privateDir -ChildPath 'Get-PhishIRSecret.ps1')
    
    # Create test config
    $script:TestConfigPath = Join-Path $TestDrive 'test-config.psd1'
}

Describe 'Get-PhishIRSecret' {
    
    BeforeEach {
        # Default local override for Get-PhishIRConfig (fallback secrets)
        function Get-PhishIRConfig { param($Section)
            if ($Section -eq 'Security') {
                return @{
                    UseKeyVault = $false
                    KeyVaultName = ''
                    UseManagedIdentity = $true
                    TenantId = ''
                    ClientId = ''
                    SecretNames = @{
                        SplunkHecToken     = 'phishir-splunk-hec-token'
                        SentinelSharedKey  = 'phishir-sentinel-shared-key'
                        AzureBlobSasToken  = 'phishir-blob-sas-token'
                        GraphAppSecret     = 'phishir-graph-app-secret'
                    }
                    Secrets = @{
                        SplunkHecToken     = 'test-splunk-token-123'
                        SentinelSharedKey  = 'test-sentinel-key-456'
                        AzureBlobSasToken  = 'test-blob-sas-789'
                        GraphAppSecret     = 'test-graph-secret-012'
                    }
                }
            }
        }

        # Clean environment variables
        Remove-Item Env:\PHISHIR_KV_NAME -ErrorAction SilentlyContinue
        Remove-Item Env:\PHISHIR_KV_TENANT -ErrorAction SilentlyContinue
        Remove-Item Env:\PHISHIR_KV_CLIENT -ErrorAction SilentlyContinue
    }
    
    Context 'Fallback Secret Retrieval (Config File)' {
        
        It 'Should retrieve secret from config fallback' {
            $secret = Get-PhishIRSecret -SecretName 'SplunkHecToken' -WarningAction SilentlyContinue
            
            $secret | Should -Be 'test-splunk-token-123'
        }
        
        It 'Should warn when using fallback secrets' {
            $warnings = @()
            Get-PhishIRSecret -SecretName 'SentinelSharedKey' -WarningVariable warnings | Out-Null
            
            $warnings | Should -Not -BeNullOrEmpty
            $warnings[0] | Should -Match 'NOT RECOMMENDED FOR PRODUCTION'
        }
        
        It 'Should retrieve all supported secret types' {
            $secretNames = @('SplunkHecToken', 'SentinelSharedKey', 'AzureBlobSasToken', 'GraphAppSecret')
            
            foreach ($name in $secretNames) {
                $secret = Get-PhishIRSecret -SecretName $name -WarningAction SilentlyContinue
                $secret | Should -Not -BeNullOrEmpty
            }
        }
        
        It 'Should return plain text by default' {
            $secret = Get-PhishIRSecret -SecretName 'SplunkHecToken' -WarningAction SilentlyContinue
            
            $secret | Should -BeOfType [string]
            $secret | Should -Be 'test-splunk-token-123'
        }
        
        It 'Should return SecureString when -AsSecureString specified' {
            $secret = Get-PhishIRSecret -SecretName 'SplunkHecToken' -AsSecureString -WarningAction SilentlyContinue
            
            $secret | Should -BeOfType [System.Security.SecureString]
        }
    }
    
    Context 'Azure Key Vault Integration' {

        BeforeEach {
            # Override local function to enable Key Vault in this context
            function Get-PhishIRConfig { param($Section)
                if ($Section -eq 'Security') {
                    return @{
                        UseKeyVault        = $true
                        KeyVaultName       = 'test-keyvault'
                        UseManagedIdentity = $true
                        TenantId           = 'tenant-guid'
                        ClientId           = 'client-guid'
                        SecretNames        = @{
                            SplunkHecToken    = 'phishir-splunk-hec-token'
                            SentinelSharedKey = 'phishir-sentinel-shared-key'
                        }
                    }
                }
            }

            # Mock Get-AzKeyVaultSecret
            Mock Get-AzKeyVaultSecret {
                param($VaultName, $Name)
                
                $secureValue = ConvertTo-SecureString -String "kv-secret-$Name" -AsPlainText -Force
                return [PSCustomObject]@{
                    Name = $Name
                    SecretValue = $secureValue
                }
            }
            
            # Mock Get-AzContext
            Mock Get-AzContext {
                return [PSCustomObject]@{
                    Account = @{ Id = 'user@test.com' }
                    Tenant = @{ Id = 'tenant-guid' }
                }
            }
            
            # Mock Get-Module for Az.KeyVault check
            Mock Get-Module {
                param($ListAvailable, $Name)
                if ($Name -eq 'Az.KeyVault') {
                    return [PSCustomObject]@{ Name = 'Az.KeyVault'; Version = '4.0.0' }
                }
            }
        }
        
        It 'Should retrieve secret from Azure Key Vault when enabled' {
            $secret = Get-PhishIRSecret -SecretName 'SplunkHecToken'
            
            Should -Invoke Get-AzKeyVaultSecret -Times 1 -Scope It
            $secret | Should -Be 'kv-secret-phishir-splunk-hec-token'
        }
        
        It 'Should use correct Key Vault name from config' {
            Get-PhishIRSecret -SecretName 'SplunkHecToken' | Out-Null
            
            Should -Invoke Get-AzKeyVaultSecret -ParameterFilter { $VaultName -eq 'test-keyvault' } -Times 1
        }
        
        It 'Should map secret name to Key Vault key' {
            Get-PhishIRSecret -SecretName 'SentinelSharedKey' | Out-Null
            
            Should -Invoke Get-AzKeyVaultSecret -ParameterFilter { $Name -eq 'phishir-sentinel-shared-key' } -Times 1
        }
        
        It 'Should return SecureString from Key Vault when -AsSecureString specified' {
            $secret = Get-PhishIRSecret -SecretName 'SplunkHecToken' -AsSecureString
            
            $secret | Should -BeOfType [System.Security.SecureString]
        }
    }
    
    Context 'Environment Variable Overrides' {
        
        It 'Should use PHISHIR_KV_NAME environment variable' {
            $env:PHISHIR_KV_NAME = 'override-keyvault'
            
            Mock -CommandName Get-PhishIRConfig -ModuleName PhishIR {
                return @{
                    UseKeyVault = $false
                    KeyVaultName = 'default-keyvault'
                }
            }
            
            Mock Get-AzKeyVaultSecret { return [PSCustomObject]@{ SecretValue = ConvertTo-SecureString 'test' -AsPlainText -Force } }
            Mock Get-AzContext { return [PSCustomObject]@{} }
            Mock Get-Module { return [PSCustomObject]@{ Name = 'Az.KeyVault' } }
            
            Get-PhishIRSecret -SecretName 'SplunkHecToken' -ErrorAction SilentlyContinue | Out-Null
            
            Should -Invoke Get-AzKeyVaultSecret -ParameterFilter { $VaultName -eq 'override-keyvault' } -Times 1
            
            Remove-Item Env:\PHISHIR_KV_NAME
        }
    }
    
    Context 'Error Handling' {

        It 'Should throw when secret not found in config' {
            function Get-PhishIRConfig { param($Section)
                if ($Section -eq 'Security') {
                    return @{
                        UseKeyVault = $false
                        Secrets     = @{}
                    }
                }
            }

            { Get-PhishIRSecret -SecretName 'SplunkHecToken' -ErrorAction Stop } | Should -Throw
        }

        It 'Should throw when Az.KeyVault module not installed' {
            function Get-PhishIRConfig { param($Section)
                if ($Section -eq 'Security') {
                    return @{
                        UseKeyVault  = $true
                        KeyVaultName = 'test-kv'
                        SecretNames  = @{ SplunkHecToken = 'test-secret' }
                    }
                }
            }

            Mock Get-Module { return $null }
            
            { Get-PhishIRSecret -SecretName 'SplunkHecToken' -ErrorAction Stop } | Should -Throw
        }
        
        It 'Should handle Key Vault access errors gracefully' {
            function Get-PhishIRConfig { param($Section)
                if ($Section -eq 'Security') {
                    return @{
                        UseKeyVault  = $true
                        KeyVaultName = 'test-kv'
                        SecretNames  = @{ SplunkHecToken = 'test-secret' }
                    }
                }
            }
            
            Mock Get-Module { return [PSCustomObject]@{ Name = 'Az.KeyVault' } }
            Mock Get-AzContext { return [PSCustomObject]@{} }
            Mock Get-AzKeyVaultSecret { throw 'Access denied' }
            
            { Get-PhishIRSecret -SecretName 'SplunkHecToken' -ErrorAction Stop } | Should -Throw
        }
    }
    
    Context 'Parameter Validation' {
        
        It 'Should only accept valid secret names' {
            $validNames = @('SplunkHecToken', 'SentinelSharedKey', 'AzureBlobSasToken', 'GraphAppSecret')
            
            foreach ($name in $validNames) {
                { Get-PhishIRSecret -SecretName $name -WarningAction SilentlyContinue } | Should -Not -Throw
            }
        }
        
        It 'Should reject invalid secret names' {
            { Get-PhishIRSecret -SecretName 'InvalidSecretName' } | Should -Throw
        }
    }
    
    Context 'Security Best Practices' {

        It 'Should not log secret values in verbose output' {
            $rawOutput = Get-PhishIRSecret -SecretName 'SplunkHecToken' -Verbose -WarningAction SilentlyContinue 4>&1
            # Keep only verbose records, drop the success output that contains the secret value
            $verboseOutput = $rawOutput | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } | ForEach-Object { $_.Message }

            $verboseOutput -join ' ' | Should -Not -Match 'test-splunk-token-123'
        }
        
        It 'Should warn about production use of config secrets' {
            $warnings = @()
            Get-PhishIRSecret -SecretName 'SplunkHecToken' -WarningVariable warnings | Out-Null

            ($warnings -join [Environment]::NewLine) | Should -Match 'Enable Azure Key Vault by setting Security.UseKeyVault = \$true in PhishIRConfig.psd1'
        }
    }
}

AfterAll {
    # Cleanup environment variables
    Remove-Item Env:\PHISHIR_KV_NAME -ErrorAction SilentlyContinue
    Remove-Item Env:\PHISHIR_KV_TENANT -ErrorAction SilentlyContinue
    Remove-Item Env:\PHISHIR_KV_CLIENT -ErrorAction SilentlyContinue
}
