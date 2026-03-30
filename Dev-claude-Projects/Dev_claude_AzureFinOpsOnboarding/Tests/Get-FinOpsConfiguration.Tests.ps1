Import-Module Pester

Describe 'Get-FinOpsConfiguration' {
    BeforeAll {
        $testConfigPath = Join-Path -Path $TestDrive -ChildPath 'test-config.json'
    }
    
    Context 'Parameter Validation' {
        It 'Should accept a Path parameter' {
            { Get-FinOpsConfiguration -Path $testConfigPath -ErrorAction SilentlyContinue } | Should Not Throw
        }
    }
    
    Context 'File Not Found' {
        It 'Should return null and warning when config file does not exist' {
            $result = Get-FinOpsConfiguration -Path $testConfigPath -WarningAction SilentlyContinue
            $result | Should BeNullOrEmpty
        }
    }
    
    Context 'Valid Configuration' {
        BeforeEach {
            $validConfig = @{
                defaultTenantId = '12345678-1234-1234-1234-123456789012'
                outputDirectory = './Reports'
                costLookbackStartDays = 60
                costLookbackEndDays = 30
            } | ConvertTo-Json
            
            Set-Content -Path $testConfigPath -Value $validConfig
        }
        
        It 'Should load valid JSON configuration' {
            $result = Get-FinOpsConfiguration -Path $testConfigPath
            $result | Should Not BeNullOrEmpty
            $result.defaultTenantId | Should Be '12345678-1234-1234-1234-123456789012'
            $result.outputDirectory | Should Be './Reports'
        }
        
        It 'Should return object with expected properties' {
            $result = Get-FinOpsConfiguration -Path $testConfigPath
            (($result.PSObject.Properties.Name -contains 'defaultTenantId')) | Should Be $true
            (($result.PSObject.Properties.Name -contains 'outputDirectory')) | Should Be $true
        }
    }
    
    Context 'Invalid JSON' {
        BeforeEach {
            Set-Content -Path $testConfigPath -Value 'This is not valid JSON'
        }
        
        It 'Should handle invalid JSON gracefully' {
            $result = Get-FinOpsConfiguration -Path $testConfigPath -ErrorAction SilentlyContinue
            $result | Should BeNullOrEmpty
        }
    }
}
