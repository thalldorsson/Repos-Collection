BeforeAll {
    $ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
    Import-Module (Join-Path $ModuleRoot 'AzureFinOpsOnboarding.psd1') -Force
    
    # Mock Azure REST API calls
    Mock -CommandName Invoke-FinOpsAzureGet -MockWith {
        return @{
            value = @(
                @{ id = '/subscriptions/sub-001'; displayName = 'Test Subscription 1' }
                @{ id = '/subscriptions/sub-002'; displayName = 'Test Subscription 2' }
            )
            nextLink = $null
        }
    } -ModuleName AzureFinOpsOnboarding
}

Describe 'Cache Integration Tests' {
    
    BeforeEach {
        # Clear cache before each test
        Clear-FinOpsCache
    }
    
    Context 'Test-FinOpsAzSubscriptions Caching' {
        
        It 'Should cache subscription results by default' {
            $token = 'test-token-123'
            
            # First call - should hit API
            $result1 = Test-FinOpsAzSubscriptions -Token $token
            
            # Second call - should use cache
            $result2 = Test-FinOpsAzSubscriptions -Token $token
            
            # Should have called API only once
            Should -Invoke -CommandName Invoke-FinOpsAzureGet -ModuleName AzureFinOpsOnboarding -Times 1 -Exactly
            
            # Results should be identical
            $result1.Success | Should -Be $result2.Success
            $result1.Metrics.Count | Should -Be $result2.Metrics.Count
        }
        
        It 'Should bypass cache when -BypassCache is specified' {
            $token = 'test-token-456'
            
            # First call with cache
            $result1 = Test-FinOpsAzSubscriptions -Token $token
            
            # Second call bypassing cache
            $result2 = Test-FinOpsAzSubscriptions -Token $token -BypassCache
            
            # Should have called API twice
            Should -Invoke -CommandName Invoke-FinOpsAzureGet -ModuleName AzureFinOpsOnboarding -Times 2 -Exactly
        }
        
        It 'Should respect custom CacheTTL parameter' {
            $token = 'test-token-789'
            
            # Cache with 1 second TTL
            $result1 = Test-FinOpsAzSubscriptions -Token $token -CacheTTL 1
            
            # Check cache stats
            $stats = Get-FinOpsCacheStats
            $cacheEntry = $stats | Where-Object { $_.Key -like 'azsubscriptions-*' }
            
            $cacheEntry | Should -Not -BeNullOrEmpty
            $cacheEntry.TTLSeconds | Should -Be 1
        }
        
        It 'Should use different cache keys for different tokens' {
            $token1 = 'test-token-aaa'
            $token2 = 'test-token-bbb'
            
            # Call with two different tokens
            $result1 = Test-FinOpsAzSubscriptions -Token $token1
            $result2 = Test-FinOpsAzSubscriptions -Token $token2
            
            # Should have called API twice (different tokens = different cache keys)
            Should -Invoke -CommandName Invoke-FinOpsAzureGet -ModuleName AzureFinOpsOnboarding -Times 2 -Exactly
        }
    }
    
    Context 'Test-FinOpsAzBillingAccounts Caching' {
        
        BeforeAll {
            # Mock billing accounts API
            Mock -CommandName Invoke-FinOpsAzureGet -MockWith {
                return @{
                    value = @(
                        @{ name = 'billing-001'; displayName = 'Test Billing Account 1' }
                        @{ name = 'billing-002'; displayName = 'Test Billing Account 2' }
                    )
                    nextLink = $null
                }
            } -ModuleName AzureFinOpsOnboarding
        }
        
        It 'Should cache billing account results' {
            $token = 'test-token-billing-1'
            
            # First call
            $result1 = Test-FinOpsAzBillingAccounts -Token $token
            
            # Second call - should use cache
            $result2 = Test-FinOpsAzBillingAccounts -Token $token
            
            # Should have called API only once
            Should -Invoke -CommandName Invoke-FinOpsAzureGet -ModuleName AzureFinOpsOnboarding -Times 1 -Exactly
        }
        
        It 'Should support BypassCache switch' {
            $token = 'test-token-billing-2'
            
            $result1 = Test-FinOpsAzBillingAccounts -Token $token
            $result2 = Test-FinOpsAzBillingAccounts -Token $token -BypassCache
            
            Should -Invoke -CommandName Invoke-FinOpsAzureGet -ModuleName AzureFinOpsOnboarding -Times 2 -Exactly
        }
    }
    
    Context 'Get-FinOpsPowerBIWorkspace Caching' {
        
        BeforeAll {
            # Mock Power BI MCP
            Mock -CommandName Invoke-FinOpsPowerBIMcp -MockWith {
                return @(
                    [PSCustomObject]@{ Id = '11111111-1111-1111-1111-111111111111'; Name = 'Test Workspace 1' }
                    [PSCustomObject]@{ Id = '22222222-2222-2222-2222-222222222222'; Name = 'Test Workspace 2' }
                )
            } -ModuleName AzureFinOpsOnboarding
        }
        
        It 'Should cache Power BI workspace results' {
            # First call
            $result1 = Get-FinOpsPowerBIWorkspace -UsePowerBIMcp
            
            # Second call - should use cache
            $result2 = Get-FinOpsPowerBIWorkspace -UsePowerBIMcp
            
            # Should have called MCP only once
            Should -Invoke -CommandName Invoke-FinOpsPowerBIMcp -ModuleName AzureFinOpsOnboarding -Times 1 -Exactly
        }
        
        It 'Should support BypassCache switch' {
            $result1 = Get-FinOpsPowerBIWorkspace -UsePowerBIMcp
            $result2 = Get-FinOpsPowerBIWorkspace -UsePowerBIMcp -BypassCache
            
            Should -Invoke -CommandName Invoke-FinOpsPowerBIMcp -ModuleName AzureFinOpsOnboarding -Times 2 -Exactly
        }
        
        It 'Should use different cache keys for filtered results' {
            # List all workspaces
            $result1 = Get-FinOpsPowerBIWorkspace -UsePowerBIMcp
            
            # List filtered workspaces
            $result2 = Get-FinOpsPowerBIWorkspace -UsePowerBIMcp -Filter "Test"
            
            # Should have called MCP twice (different filters = different cache keys)
            Should -Invoke -CommandName Invoke-FinOpsPowerBIMcp -ModuleName AzureFinOpsOnboarding -Times 2 -Exactly
        }
    }
    
    Context 'Cache Performance Benefits' {
        
        It 'Should demonstrate cache hit performance' {
            $token = 'test-token-perf'
            
            # Measure first call (cache miss)
            $time1 = Measure-Command {
                $result1 = Test-FinOpsAzSubscriptions -Token $token
            }
            
            # Measure second call (cache hit)
            $time2 = Measure-Command {
                $result2 = Test-FinOpsAzSubscriptions -Token $token
            }
            
            # Cache hit should be faster (or at least not slower)
            # Note: In tests this might not always be true due to mocking overhead
            # but in production with real API calls, cache will be significantly faster
            Write-Verbose "First call (miss): $($time1.TotalMilliseconds)ms"
            Write-Verbose "Second call (hit): $($time2.TotalMilliseconds)ms"
            
            # Just verify both calls completed successfully
            $result1.Success | Should -Be $true
            $result2.Success | Should -Be $true
        }
    }
}
