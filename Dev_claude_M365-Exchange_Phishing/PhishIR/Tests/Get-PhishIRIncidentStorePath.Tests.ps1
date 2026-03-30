#Requires -Module Pester

BeforeAll {
    # Import module
    $modulePath = Join-Path $PSScriptRoot '..' 'PhishIR.psd1'
    Import-Module $modulePath -Force
    
    # Create test directory
    $script:TestStorageDir = Join-Path $TestDrive 'IncidentStore'
}

Describe 'Get-PhishIRIncidentStorePath' {
    
    BeforeEach {
        # Mock Get-PhishIRConfig
        Mock Get-PhishIRConfig {
            return @{
                BasePath = $script:TestStorageDir
                IncidentStore = @{
                    Path = 'incidents.jsonl'
                    MonthlyPartitioning = $false
                }
            }
        }
    }
    
    Context 'Single File Mode (Partitioning Disabled)' {
        
        It 'Should return single incidents.jsonl path when partitioning disabled' {
            $result = Get-PhishIRIncidentStorePath
            
            $result | Should -BeLike '*incidents.jsonl'
            $result | Should -Not -Match '\d{4}-\d{2}'
        }
        
        It 'Should use timestamp parameter even when partitioning disabled' {
            $timestamp = Get-Date '2025-10-15'
            $result = Get-PhishIRIncidentStorePath -Timestamp $timestamp
            
            # Should still return single file (partitioning disabled)
            $result | Should -BeLike '*incidents.jsonl'
            $result | Should -Not -Match '2025-10'
        }
    }
    
    Context 'Monthly Partitioning Mode' {
        
        BeforeEach {
            Mock Get-PhishIRConfig {
                return @{
                    BasePath = $script:TestStorageDir
                    IncidentStore = @{
                        Path = 'incidents.jsonl'
                        MonthlyPartitioning = $true
                    }
                }
            }
        }
        
        It 'Should return partitioned path with current month' {
            $result = Get-PhishIRIncidentStorePath
            
            $currentMonth = (Get-Date).ToString('yyyy-MM')
            $result | Should -BeLike "*incidents-$currentMonth.jsonl"
        }
        
        It 'Should return partitioned path for specific timestamp' {
            $timestamp = Get-Date '2025-10-15'
            $result = Get-PhishIRIncidentStorePath -Timestamp $timestamp
            
            $result | Should -BeLike '*incidents-2025-10.jsonl'
        }
        
        It 'Should return different paths for different months' {
            $oct = Get-Date '2025-10-15'
            $nov = Get-Date '2025-11-15'
            
            $octPath = Get-PhishIRIncidentStorePath -Timestamp $oct
            $novPath = Get-PhishIRIncidentStorePath -Timestamp $nov
            
            $octPath | Should -Not -Be $novPath
            $octPath | Should -BeLike '*2025-10.jsonl'
            $novPath | Should -BeLike '*2025-11.jsonl'
        }
        
        It 'Should handle year boundary correctly' {
            $dec2024 = Get-Date '2024-12-31'
            $jan2025 = Get-Date '2025-01-01'
            
            $decPath = Get-PhishIRIncidentStorePath -Timestamp $dec2024
            $janPath = Get-PhishIRIncidentStorePath -Timestamp $jan2025
            
            $decPath | Should -BeLike '*2024-12.jsonl'
            $janPath | Should -BeLike '*2025-01.jsonl'
        }
    }
    
    Context 'Directory Creation' {
        
        BeforeEach {
            # Clean test directory
            if (Test-Path $script:TestStorageDir) {
                Remove-Item -Path $script:TestStorageDir -Recurse -Force
            }
        }
        
        It 'Should create directory when -CreateIfMissing is specified' {
            Mock Get-PhishIRConfig {
                return @{
                    BasePath = $script:TestStorageDir
                    IncidentStore = @{
                        Path = 'incidents.jsonl'
                        MonthlyPartitioning = $false
                    }
                }
            }
            
            Test-Path $script:TestStorageDir | Should -Be $false
            
            $result = Get-PhishIRIncidentStorePath -CreateIfMissing
            
            Test-Path $script:TestStorageDir | Should -Be $true
        }
        
        It 'Should not create directory by default' {
            Test-Path $script:TestStorageDir | Should -Be $false
            
            $result = Get-PhishIRIncidentStorePath
            
            Test-Path $script:TestStorageDir | Should -Be $false
        }
    }
    
    Context 'Fallback Behavior' {
        
        It 'Should use fallback path when config unavailable' {
            Mock Get-PhishIRConfig { throw 'Config not found' }
            
            $result = Get-PhishIRIncidentStorePath
            
            # Should return hard-coded fallback path
            $result | Should -Not -BeNullOrEmpty
            $result | Should -BeLike '*incidents.jsonl'
        }
    }
    
    Context 'Path Construction' {
        
        BeforeEach {
            Mock Get-PhishIRConfig {
                return @{
                    BasePath = 'C:\PhishIR'
                    IncidentStore = @{
                        Path = 'incidents.jsonl'
                        MonthlyPartitioning = $true
                    }
                }
            }
        }
        
        It 'Should construct absolute path correctly' {
            $result = Get-PhishIRIncidentStorePath
            
            $result | Should -Match '^[A-Z]:\\'
            $result | Should -BeLike 'C:\PhishIR\*'
        }
        
        It 'Should use correct filename format for partitioned files' {
            $timestamp = Get-Date '2025-11-19'
            $result = Get-PhishIRIncidentStorePath -Timestamp $timestamp
            
            $result | Should -Match 'incidents-\d{4}-\d{2}\.jsonl$'
        }
    }
    
    Context 'Integration with Add-PhishIRIncidentRecord' {
        
        It 'Should provide consistent paths for same month' {
            Mock Get-PhishIRConfig {
                return @{
                    BasePath = $script:TestStorageDir
                    IncidentStore = @{
                        Path = 'incidents.jsonl'
                        MonthlyPartitioning = $true
                    }
                }
            }
            
            $timestamp1 = Get-Date '2025-11-01 10:00'
            $timestamp2 = Get-Date '2025-11-30 23:59'
            
            $path1 = Get-PhishIRIncidentStorePath -Timestamp $timestamp1
            $path2 = Get-PhishIRIncidentStorePath -Timestamp $timestamp2
            
            # Both should point to same November file
            $path1 | Should -Be $path2
        }
    }
}

AfterAll {
    # Cleanup
    if (Test-Path $script:TestStorageDir) {
        Remove-Item -Path $script:TestStorageDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
