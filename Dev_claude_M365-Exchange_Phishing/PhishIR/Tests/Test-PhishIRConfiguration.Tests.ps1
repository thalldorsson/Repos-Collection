#Requires -Module Pester

BeforeAll {
    # Import module
    $modulePath = Join-Path $PSScriptRoot '..' 'PhishIR.psd1'
    Import-Module $modulePath -Force
    
    # Create test config directory
    $script:TestConfigDir = Join-Path $TestDrive 'ConfigTests'
    New-Item -ItemType Directory -Path $script:TestConfigDir -Force | Out-Null
}

Describe 'Test-PhishIRConfiguration' {
    
    Context 'Config File Validation' {
        
        It 'Should fail when config file does not exist' {
            $result = Test-PhishIRConfiguration -ConfigPath 'C:\NonExistent\config.psd1'
            $result.Valid | Should -Be $false
            $result.Errors | Should -Contain 'Configuration file not found'
        }
        
        It 'Should fail when config file is not valid PowerShell data' {
            $badConfig = Join-Path $script:TestConfigDir 'bad.psd1'
            Set-Content -Path $badConfig -Value '@{ InvalidSyntax = '
            
            $result = Test-PhishIRConfiguration -ConfigPath $badConfig
            $result.Valid | Should -Be $false
            $result.ErrorCount | Should -BeGreaterThan 0
        }
        
        It 'Should pass when config file is valid' {
            $validConfig = Join-Path $script:TestConfigDir 'valid.psd1'
            $configContent = @'
@{
    ConfigVersion = '2.4.1'
    Storage = @{
        BasePath = 'C:\PhishIR'
        IncidentStore = @{ Path = 'incidents.jsonl'; MonthlyPartitioning = $false }
    }
    SignInTracking = @{
        DefaultDaysBack = 7
        BatchSize = 10
    }
    GraphAPI = @{
        RequiredScopes = @('AuditLog.Read.All')
        RequestsPerMinute = 120
    }
    IncidentLogging = @{
        Format = 'JSONL'
    }
}
'@
            Set-Content -Path $validConfig -Value $configContent
            
            $result = Test-PhishIRConfiguration -ConfigPath $validConfig
            $result.Valid | Should -Be $true
            $result.ErrorCount | Should -Be 0
        }
    }
    
    Context 'Required Sections Validation' {
        
        It 'Should fail when Storage section is missing' {
            $config = Join-Path $script:TestConfigDir 'no-storage.psd1'
            $configContent = @'
@{
    ConfigVersion = '2.4.1'
    SignInTracking = @{ DefaultDaysBack = 7 }
    GraphAPI = @{ RequiredScopes = @('AuditLog.Read.All') }
    IncidentLogging = @{ Format = 'JSONL' }
}
'@
            Set-Content -Path $config -Value $configContent
            
            $result = Test-PhishIRConfiguration -ConfigPath $config
            $result.Valid | Should -Be $false
            $result.Errors | Should -Contain 'Required section missing: Storage'
        }
        
        It 'Should fail when SignInTracking section is missing' {
            $config = Join-Path $script:TestConfigDir 'no-signin.psd1'
            $configContent = @'
@{
    ConfigVersion = '2.4.1'
    Storage = @{ BasePath = 'C:\PhishIR' }
    GraphAPI = @{ RequiredScopes = @('AuditLog.Read.All') }
    IncidentLogging = @{ Format = 'JSONL' }
}
'@
            Set-Content -Path $config -Value $configContent
            
            $result = Test-PhishIRConfiguration -ConfigPath $config
            $result.Valid | Should -Be $false
            $result.Errors | Should -Contain 'Required section missing: SignInTracking'
        }
    }
    
    Context 'Range Validation' {
        
        It 'Should fail when DefaultDaysBack is out of range (too low)' {
            $config = Join-Path $script:TestConfigDir 'daysback-low.psd1'
            $configContent = @'
@{
    ConfigVersion = '2.4.1'
    Storage = @{ BasePath = 'C:\PhishIR' }
    SignInTracking = @{ DefaultDaysBack = 0 }
    GraphAPI = @{ RequiredScopes = @('AuditLog.Read.All') }
    IncidentLogging = @{ Format = 'JSONL' }
}
'@
            Set-Content -Path $config -Value $configContent
            
            $result = Test-PhishIRConfiguration -ConfigPath $config
            $result.Valid | Should -Be $false
            $result.Errors | Should -Match 'DefaultDaysBack.*range 1-30'
        }
        
        It 'Should fail when BatchSize is out of range (too high)' {
            $config = Join-Path $script:TestConfigDir 'batchsize-high.psd1'
            $configContent = @'
@{
    ConfigVersion = '2.4.1'
    Storage = @{ BasePath = 'C:\PhishIR' }
    SignInTracking = @{ DefaultDaysBack = 7; BatchSize = 150 }
    GraphAPI = @{ RequiredScopes = @('AuditLog.Read.All') }
    IncidentLogging = @{ Format = 'JSONL' }
}
'@
            Set-Content -Path $config -Value $configContent
            
            $result = Test-PhishIRConfiguration -ConfigPath $config
            $result.Valid | Should -Be $false
            $result.Errors | Should -Match 'BatchSize.*range 1-100'
        }
    }
    
    Context 'SIEM Configuration Validation' {
        
        It 'Should fail when Sentinel is enabled but WorkspaceId is missing' {
            $config = Join-Path $script:TestConfigDir 'sentinel-incomplete.psd1'
            $configContent = @'
@{
    ConfigVersion = '2.4.1'
    Storage = @{ BasePath = 'C:\PhishIR' }
    SignInTracking = @{ DefaultDaysBack = 7 }
    GraphAPI = @{ RequiredScopes = @('AuditLog.Read.All') }
    IncidentLogging = @{ Format = 'JSONL' }
    SIEM = @{
        Sentinel = @{ Enabled = $true; WorkspaceId = ''; SharedKey = 'key123' }
    }
}
'@
            Set-Content -Path $config -Value $configContent
            
            $result = Test-PhishIRConfiguration -ConfigPath $config -CheckSIEM
            $result.Valid | Should -Be $false
            $result.Errors | Should -Match 'Sentinel.*WorkspaceId'
        }
        
        It 'Should fail when Splunk is enabled but HecToken is missing' {
            $config = Join-Path $script:TestConfigDir 'splunk-incomplete.psd1'
            $configContent = @'
@{
    ConfigVersion = '2.4.1'
    Storage = @{ BasePath = 'C:\PhishIR' }
    SignInTracking = @{ DefaultDaysBack = 7 }
    GraphAPI = @{ RequiredScopes = @('AuditLog.Read.All') }
    IncidentLogging = @{ Format = 'JSONL' }
    SIEM = @{
        Splunk = @{ Enabled = $true; HecEndpoint = 'https://splunk.local:8088'; HecToken = '' }
    }
}
'@
            Set-Content -Path $config -Value $configContent
            
            $result = Test-PhishIRConfiguration -ConfigPath $config -CheckSIEM
            $result.Valid | Should -Be $false
            $result.Errors | Should -Match 'Splunk.*HecToken'
        }
    }
    
    Context 'Path Validation' {
        
        It 'Should warn when BasePath does not exist' {
            $config = Join-Path $script:TestConfigDir 'path-missing.psd1'
            $configContent = @'
@{
    ConfigVersion = '2.4.1'
    Storage = @{ BasePath = 'C:\NonExistentPath\PhishIR' }
    SignInTracking = @{ DefaultDaysBack = 7 }
    GraphAPI = @{ RequiredScopes = @('AuditLog.Read.All') }
    IncidentLogging = @{ Format = 'JSONL' }
}
'@
            Set-Content -Path $config -Value $configContent
            
            $result = Test-PhishIRConfiguration -ConfigPath $config -CheckPaths
            $result.WarningCount | Should -BeGreaterThan 0
            $result.Warnings | Should -Match 'BasePath.*does not exist'
        }
    }
    
    Context 'Environment Variable Override Detection' {
        
        It 'Should detect PHISHIR_* environment variables' {
            $env:PHISHIR_STORAGE_PATH = 'C:\CustomPath'
            
            $config = Join-Path $script:TestConfigDir 'env-override.psd1'
            $configContent = @'
@{
    ConfigVersion = '2.4.1'
    Storage = @{ BasePath = 'C:\PhishIR' }
    SignInTracking = @{ DefaultDaysBack = 7 }
    GraphAPI = @{ RequiredScopes = @('AuditLog.Read.All') }
    IncidentLogging = @{ Format = 'JSONL' }
}
'@
            Set-Content -Path $config -Value $configContent
            
            $result = Test-PhishIRConfiguration -ConfigPath $config
            $result.InfoCount | Should -BeGreaterThan 0
            $result.Info | Should -Match 'PHISHIR_STORAGE_PATH'
            
            Remove-Item Env:\PHISHIR_STORAGE_PATH
        }
    }
    
    Context 'Detailed Mode' {
        
        It 'Should return individual check results when -Detailed is specified' {
            $config = Join-Path $script:TestConfigDir 'detailed.psd1'
            $configContent = @'
@{
    ConfigVersion = '2.4.1'
    Storage = @{ BasePath = 'C:\PhishIR' }
    SignInTracking = @{ DefaultDaysBack = 7 }
    GraphAPI = @{ RequiredScopes = @('AuditLog.Read.All') }
    IncidentLogging = @{ Format = 'JSONL' }
}
'@
            Set-Content -Path $config -Value $configContent
            
            $result = Test-PhishIRConfiguration -ConfigPath $config -Detailed
            $result.Checks | Should -Not -BeNullOrEmpty
            $result.Checks.Count | Should -BeGreaterThan 5
            $result.Checks[0].CheckName | Should -Not -BeNullOrEmpty
            $result.Checks[0].Status | Should -BeIn @('Pass', 'Warning', 'Fail')
        }
    }
}

AfterAll {
    # Cleanup
    if (Test-Path $script:TestConfigDir) {
        Remove-Item -Path $script:TestConfigDir -Recurse -Force
    }
}
