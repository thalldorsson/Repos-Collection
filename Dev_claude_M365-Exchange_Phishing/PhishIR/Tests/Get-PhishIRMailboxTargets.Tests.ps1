#Requires -Module Pester

BeforeAll {
    $moduleRoot = Join-Path -Path $PSScriptRoot -ChildPath '..'
    $modulePath = Join-Path -Path $moduleRoot -ChildPath 'PhishIR.psd1'
    Import-Module $modulePath -Force

    $samplesDir = Join-Path $moduleRoot '..' | Join-Path -ChildPath 'samples'
    $script:SamplePath = Join-Path $samplesDir 'tenants.sample.json'
}

Describe 'Get-PhishIRMailboxTargets' {
    Context 'Basic Functionality' {
        It 'Should resolve mailboxes from tenant configuration' {
            $cfg = Get-PhishIRTenantConfig -Path $script:SamplePath -Validate
            $result = Get-PhishIRMailboxTargets -Tenant $cfg.tenants[0]
            
            $result | Should -Not -BeNullOrEmpty
            $result.TenantDisplayName | Should -Be 'Contoso Prod'
            $result.Total | Should -BeGreaterThan 0
            $result.ResolvedMailboxes | Should -Not -BeNullOrEmpty
        }

        It 'Should return source breakdown' {
            $cfg = Get-PhishIRTenantConfig -Path $script:SamplePath -Validate
            $result = Get-PhishIRMailboxTargets -Tenant $cfg.tenants[0]
            
            $result.SourceBreakdown | Should -Not -BeNullOrEmpty
            $result.SourceBreakdown.Explicit | Should -BeGreaterOrEqual 0
            $result.SourceBreakdown.Groups | Should -BeGreaterOrEqual 0
            $result.SourceBreakdown.Csv | Should -BeGreaterOrEqual 0
            $result.SourceBreakdown.GraphQuery | Should -BeGreaterOrEqual 0
            $result.SourceBreakdown.Excluded | Should -BeGreaterOrEqual 0
        }

        It 'Should include query metrics' {
            $cfg = Get-PhishIRTenantConfig -Path $script:SamplePath -Validate
            $result = Get-PhishIRMailboxTargets -Tenant $cfg.tenants[0]
            
            $result.QueryMetrics | Should -Not -BeNullOrEmpty
            $result.QueryMetrics.GraphQueryExecuted | Should -BeIn @($true, $false)
            $result.QueryMetrics.GraphResultCount | Should -BeGreaterOrEqual 0
            $result.QueryMetrics.GraphPagesRetrieved | Should -BeGreaterOrEqual 0
            $result.QueryMetrics.GraphQueryDurationMs | Should -BeGreaterOrEqual 0
        }
    }

    Context 'Graph Filter Override' {
        It 'Should accept custom GraphFilter parameter' {
            $cfg = Get-PhishIRTenantConfig -Path $script:SamplePath -Validate
            $tenant = $cfg.tenants[0]
            
            # This will fail without Graph connection, but should accept parameter
            { Get-PhishIRMailboxTargets -Tenant $tenant -GraphFilter "accountEnabled eq true" -ErrorAction SilentlyContinue } | Should -Not -Throw
        }

        It 'Should support PageSize parameter' {
            $cfg = Get-PhishIRTenantConfig -Path $script:SamplePath -Validate
            $tenant = $cfg.tenants[0]
            
            { Get-PhishIRMailboxTargets -Tenant $tenant -PageSize 500 -ErrorAction SilentlyContinue } | Should -Not -Throw
        }

        It 'Should validate PageSize range' {
            $cfg = Get-PhishIRTenantConfig -Path $script:SamplePath -Validate
            $tenant = $cfg.tenants[0]
            
            { Get-PhishIRMailboxTargets -Tenant $tenant -PageSize 0 } | Should -Throw
            { Get-PhishIRMailboxTargets -Tenant $tenant -PageSize 1000 } | Should -Throw
        }
    }

    Context 'Exclusions' {
        It 'Should apply exclusions from tenant configuration' {
            # Create test tenant with exclusions
            $testTenant = [PSCustomObject]@{
                displayName = 'Test Tenant'
                tenantId = 'test-tenant-id'
                tenantDomain = 'test.com'
                targeting = [PSCustomObject]@{
                    includeMailboxes = @('user1@test.com', 'user2@test.com', 'user3@test.com')
                    excludeMailboxes = @('user2@test.com')
                    groups = @()
                    csvPath = $null
                    query = $null
                }
                resolvedMailboxes = @()
            }
            
            $result = Get-PhishIRMailboxTargets -Tenant $testTenant
            
            $result.ResolvedMailboxes | Should -Contain 'user1@test.com'
            $result.ResolvedMailboxes | Should -Not -Contain 'user2@test.com'
            $result.ResolvedMailboxes | Should -Contain 'user3@test.com'
            $result.SourceBreakdown.Excluded | Should -Be 1
        }
    }

    Context 'Deduplication' {
        It 'Should deduplicate mailboxes from multiple sources' {
            # Create test tenant with duplicate entries
            $testTenant = [PSCustomObject]@{
                displayName = 'Test Tenant'
                tenantId = 'test-tenant-id'
                tenantDomain = 'test.com'
                targeting = [PSCustomObject]@{
                    includeMailboxes = @('user1@test.com', 'user1@test.com', 'user2@test.com')
                    excludeMailboxes = @()
                    groups = @()
                    csvPath = $null
                    query = $null
                }
                resolvedMailboxes = @()
            }
            
            $result = Get-PhishIRMailboxTargets -Tenant $testTenant
            
            # Should have only unique mailboxes
            $result.Total | Should -Be 2
            $result.ResolvedMailboxes.Count | Should -Be 2
        }
    }

    Context 'Error Handling' {
        It 'Should handle missing tenant object gracefully' {
            { Get-PhishIRMailboxTargets -Tenant $null } | Should -Throw
        }

        It 'Should warn on invalid CSV path' {
            $testTenant = [PSCustomObject]@{
                displayName = 'Test Tenant'
                tenantId = 'test-tenant-id'
                tenantDomain = 'test.com'
                targeting = [PSCustomObject]@{
                    includeMailboxes = @()
                    excludeMailboxes = @()
                    groups = @()
                    csvPath = 'C:\NonExistent\Path\mailboxes.csv'
                    query = $null
                }
                resolvedMailboxes = @()
            }
            
            # Should not throw, but continue with empty results
            { Get-PhishIRMailboxTargets -Tenant $testTenant -WarningAction SilentlyContinue } | Should -Not -Throw
        }
    }

    Context 'IncludeDisabled Switch' {
        It 'Should accept IncludeDisabled parameter' {
            $cfg = Get-PhishIRTenantConfig -Path $script:SamplePath -Validate
            $tenant = $cfg.tenants[0]
            
            { Get-PhishIRMailboxTargets -Tenant $tenant -IncludeDisabled } | Should -Not -Throw
        }
    }
}
