BeforeAll {
    $modulePath = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
    Import-Module "$modulePath\AzureFinOpsOnboarding.psd1" -Force
    
    # Import private functions for testing
    . "$modulePath\Private\Get-FinOpsCachedValue.ps1"
}

Describe 'Get-FinOpsCachedValue' {
    BeforeEach {
        # Clear cache before each test
        Clear-FinOpsCache
    }
    
    Context 'Basic caching behavior' {
        It 'Should execute scriptblock on cache miss' {
            $counter = 0
            $result = Get-FinOpsCachedValue -Key 'test1' -TTLSeconds 60 -ScriptBlock {
                $counter++
                "value-$counter"
            }
            
            $result | Should -Be 'value-1'
        }
        
        It 'Should return cached value on cache hit' {
            $script:counter = 0
            $scriptBlock = {
                $script:counter++
                "value-$($script:counter)"
            }
            
            # First call - cache miss
            $result1 = Get-FinOpsCachedValue -Key 'test2' -TTLSeconds 60 -ScriptBlock $scriptBlock
            
            # Second call - cache hit (counter should not increment)
            $result2 = Get-FinOpsCachedValue -Key 'test2' -TTLSeconds 60 -ScriptBlock $scriptBlock
            
            $result1 | Should -Be $result2
            $script:counter | Should -Be 1
        }
        
        It 'Should support different keys independently' {
            $result1 = Get-FinOpsCachedValue -Key 'keyA' -TTLSeconds 60 -ScriptBlock { 'valueA' }
            $result2 = Get-FinOpsCachedValue -Key 'keyB' -TTLSeconds 60 -ScriptBlock { 'valueB' }
            
            $result1 | Should -Be 'valueA'
            $result2 | Should -Be 'valueB'
        }
    }
    
    Context 'TTL expiration' {
        It 'Should expire cache after TTL' {
            $script:counter = 0
            $scriptBlock = {
                $script:counter++
                "value-$($script:counter)"
            }
            
            # First call with 1 second TTL
            $result1 = Get-FinOpsCachedValue -Key 'test3' -TTLSeconds 1 -ScriptBlock $scriptBlock
            $result1 | Should -Be 'value-1'
            
            # Wait for expiration
            Start-Sleep -Seconds 2
            
            # Second call - cache should be expired
            $result2 = Get-FinOpsCachedValue -Key 'test3' -TTLSeconds 1 -ScriptBlock $scriptBlock
            $result2 | Should -Be 'value-2'
            
            $script:counter | Should -Be 2
        }
        
        It 'Should not expire cache before TTL' {
            $script:counter = 0
            $scriptBlock = {
                $script:counter++
                "value-$($script:counter)"
            }
            
            # First call with 10 second TTL
            $result1 = Get-FinOpsCachedValue -Key 'test4' -TTLSeconds 10 -ScriptBlock $scriptBlock
            
            # Wait less than TTL
            Start-Sleep -Milliseconds 500
            
            # Second call - cache should still be valid
            $result2 = Get-FinOpsCachedValue -Key 'test4' -TTLSeconds 10 -ScriptBlock $scriptBlock
            
            $result1 | Should -Be $result2
            $script:counter | Should -Be 1
        }
    }
    
    Context 'Force refresh' {
        It 'Should refresh cache when Force is specified' {
            $script:counter = 0
            $scriptBlock = {
                $script:counter++
                "value-$($script:counter)"
            }
            
            # First call
            $result1 = Get-FinOpsCachedValue -Key 'test5' -TTLSeconds 60 -ScriptBlock $scriptBlock
            
            # Second call with Force
            $result2 = Get-FinOpsCachedValue -Key 'test5' -TTLSeconds 60 -ScriptBlock $scriptBlock -Force
            
            $result1 | Should -Be 'value-1'
            $result2 | Should -Be 'value-2'
            $script:counter | Should -Be 2
        }
    }
    
    Context 'Complex objects' {
        It 'Should cache complex objects (hashtables)' {
            $data = @{ Name = 'Test'; Value = 123 }
            $result = Get-FinOpsCachedValue -Key 'test6' -TTLSeconds 60 -ScriptBlock { $data }
            
            $result.Name | Should -Be 'Test'
            $result.Value | Should -Be 123
        }
        
        It 'Should cache arrays' {
            $array = @(1, 2, 3, 4, 5)
            $result = Get-FinOpsCachedValue -Key 'test7' -TTLSeconds 60 -ScriptBlock { $array }
            
            $result.Count | Should -Be 5
            $result[0] | Should -Be 1
            $result[4] | Should -Be 5
        }
    }
    
    Context 'Error handling' {
        It 'Should propagate scriptblock exceptions' {
            {
                Get-FinOpsCachedValue -Key 'test8' -TTLSeconds 60 -ScriptBlock {
                    throw 'Intentional error'
                }
            } | Should -Throw 'Intentional error'
        }
    }
}

Describe 'Clear-FinOpsCache' {
    BeforeEach {
        # Populate cache with test data
        Get-FinOpsCachedValue -Key 'key1' -TTLSeconds 60 -ScriptBlock { 'value1' }
        Get-FinOpsCachedValue -Key 'key2' -TTLSeconds 60 -ScriptBlock { 'value2' }
        Get-FinOpsCachedValue -Key 'key3' -TTLSeconds 60 -ScriptBlock { 'value3' }
    }
    
    Context 'Clear specific key' {
        It 'Should remove specific cache entry' {
            Clear-FinOpsCache -Key 'key1'
            
            $stats = Get-FinOpsCacheStats
            $stats.Key | Should -Not -Contain 'key1'
            $stats.Key | Should -Contain 'key2'
            $stats.Key | Should -Contain 'key3'
        }
    }
    
    Context 'Clear all cache' {
        It 'Should remove all cache entries' {
            Clear-FinOpsCache
            
            $stats = Get-FinOpsCacheStats
            $stats.Count | Should -Be 0
        }
    }
}

Describe 'Get-FinOpsCacheStats' {
    BeforeEach {
        Clear-FinOpsCache
    }
    
    Context 'Cache statistics' {
        It 'Should return empty array when cache is empty' {
            $stats = Get-FinOpsCacheStats
            $stats.Count | Should -Be 0
        }
        
        It 'Should return stats for cached entries' {
            Get-FinOpsCachedValue -Key 'stat1' -TTLSeconds 60 -ScriptBlock { 'value1' }
            Get-FinOpsCachedValue -Key 'stat2' -TTLSeconds 120 -ScriptBlock { 'value2' }
            
            $stats = Get-FinOpsCacheStats
            $stats.Count | Should -Be 2
            
            $stat1 = $stats | Where-Object { $_.Key -eq 'stat1' }
            $stat1.TTLSeconds | Should -Be 60
            $stat1.Expired | Should -Be $false
            
            $stat2 = $stats | Where-Object { $_.Key -eq 'stat2' }
            $stat2.TTLSeconds | Should -Be 120
            $stat2.Expired | Should -Be $false
        }
        
        It 'Should detect expired entries' {
            Get-FinOpsCachedValue -Key 'exptest' -TTLSeconds 1 -ScriptBlock { 'value' }
            Start-Sleep -Seconds 2
            
            $stats = Get-FinOpsCacheStats
            $stats[0].Expired | Should -Be $true
        }
        
        It 'Should include AgeSeconds in stats' {
            Get-FinOpsCachedValue -Key 'agetest' -TTLSeconds 60 -ScriptBlock { 'value' }
            Start-Sleep -Milliseconds 500
            
            $stats = Get-FinOpsCacheStats
            $stats[0].AgeSeconds | Should -BeGreaterThan 0
            $stats[0].AgeSeconds | Should -BeLessThan 60
        }
    }
}
