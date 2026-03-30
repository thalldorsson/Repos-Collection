#Requires -Module Pester

BeforeAll {
    $moduleRoot = Join-Path -Path $PSScriptRoot -ChildPath '..'
    $modulePath = Join-Path -Path $moduleRoot -ChildPath 'PhishIR.psd1'
    Import-Module $modulePath -Force

    $samplesDir = Join-Path $moduleRoot '..' | Join-Path -ChildPath 'samples'
    $script:SamplePath = Join-Path $samplesDir 'tenants.sample.json'
}

Describe 'Update-PhishIRTenantRateLimits' {
    BeforeEach {
        # Create temporary telemetry file
        $script:TestTelemetryDir = Join-Path $TestDrive 'Telemetry'
        New-Item -ItemType Directory -Path $script:TestTelemetryDir -Force | Out-Null
        $script:TestTelemetryFile = Join-Path $script:TestTelemetryDir 'phishir-tenant-telemetry.jsonl'
    }

    Context 'Basic Functionality' {
        It 'Should return not adjusted when rate adaptation disabled' {
            $testTenant = [PSCustomObject]@{
                displayName = 'Test Tenant'
                tenantId = 'test-tenant-id'
                execution = [PSCustomObject]@{
                    concurrency = 4
                    baseConcurrency = 4
                }
                rateAdaptation = [PSCustomObject]@{
                    enabled = $false
                    telemetryWindow = 5
                    failureThreshold = 0.3
                    successBoostThreshold = 0.05
                    maxConcurrency = 8
                    minConcurrency = 1
                }
            }
            
            $result = Update-PhishIRTenantRateLimits -Tenant $testTenant
            
            $result.Adjusted | Should -Be $false
            $result.Reason | Should -Be 'Rate adaptation disabled'
        }

        It 'Should return not adjusted when telemetry file missing' {
            $testTenant = [PSCustomObject]@{
                displayName = 'Test Tenant'
                tenantId = 'test-tenant-id'
                execution = [PSCustomObject]@{
                    concurrency = 4
                    baseConcurrency = 4
                }
                rateAdaptation = [PSCustomObject]@{
                    enabled = $true
                    telemetryWindow = 5
                    failureThreshold = 0.3
                    successBoostThreshold = 0.05
                    maxConcurrency = 8
                    minConcurrency = 1
                }
            }
            
            $result = Update-PhishIRTenantRateLimits -Tenant $testTenant -TelemetryPath 'C:\NonExistent\telemetry.jsonl'
            
            $result.Adjusted | Should -Be $false
            $result.Reason | Should -Be 'Telemetry file not found'
        }

        It 'Should decrease concurrency on high failure ratio' {
            $testTenant = [PSCustomObject]@{
                displayName = 'Test Tenant'
                tenantId = 'test-tenant-id'
                execution = [PSCustomObject]@{
                    concurrency = 4
                    baseConcurrency = 4
                }
                rateAdaptation = [PSCustomObject]@{
                    enabled = $true
                    telemetryWindow = 5
                    failureThreshold = 0.3
                    successBoostThreshold = 0.05
                    maxConcurrency = 8
                    minConcurrency = 1
                }
            }
            
            # Create telemetry with high failure rate
            $telemetryRecords = @(
                @{ tenantId = 'test-tenant-id'; operationsAttempted = 100; operationsFailed = 40; timestamp = (Get-Date).ToString('o') }
                @{ tenantId = 'test-tenant-id'; operationsAttempted = 100; operationsFailed = 35; timestamp = (Get-Date).ToString('o') }
            )
            $telemetryRecords | ForEach-Object { $_ | ConvertTo-Json -Compress | Add-Content -Path $script:TestTelemetryFile }
            
            $result = Update-PhishIRTenantRateLimits -Tenant $testTenant -TelemetryPath $script:TestTelemetryFile
            
            $result.Adjusted | Should -Be $true
            $result.Action | Should -Be 'decrease'
            $result.OldConcurrency | Should -Be 4
            $result.NewConcurrency | Should -Be 3
            $testTenant.execution.concurrency | Should -Be 3
        }

        It 'Should increase concurrency on low failure ratio' {
            $testTenant = [PSCustomObject]@{
                displayName = 'Test Tenant'
                tenantId = 'test-tenant-id'
                execution = [PSCustomObject]@{
                    concurrency = 4
                    baseConcurrency = 4
                }
                rateAdaptation = [PSCustomObject]@{
                    enabled = $true
                    telemetryWindow = 5
                    failureThreshold = 0.3
                    successBoostThreshold = 0.05
                    maxConcurrency = 8
                    minConcurrency = 1
                }
            }
            
            # Create telemetry with low failure rate
            $telemetryRecords = @(
                @{ tenantId = 'test-tenant-id'; operationsAttempted = 100; operationsFailed = 2; timestamp = (Get-Date).ToString('o') }
                @{ tenantId = 'test-tenant-id'; operationsAttempted = 100; operationsFailed = 3; timestamp = (Get-Date).ToString('o') }
            )
            $telemetryRecords | ForEach-Object { $_ | ConvertTo-Json -Compress | Add-Content -Path $script:TestTelemetryFile }
            
            $result = Update-PhishIRTenantRateLimits -Tenant $testTenant -TelemetryPath $script:TestTelemetryFile
            
            $result.Adjusted | Should -Be $true
            $result.Action | Should -Be 'increase'
            $result.OldConcurrency | Should -Be 4
            $result.NewConcurrency | Should -Be 5
            $testTenant.execution.concurrency | Should -Be 5
        }

        It 'Should respect minimum concurrency limit' {
            $testTenant = [PSCustomObject]@{
                displayName = 'Test Tenant'
                tenantId = 'test-tenant-id'
                execution = [PSCustomObject]@{
                    concurrency = 1
                    baseConcurrency = 4
                }
                rateAdaptation = [PSCustomObject]@{
                    enabled = $true
                    telemetryWindow = 5
                    failureThreshold = 0.3
                    successBoostThreshold = 0.05
                    maxConcurrency = 8
                    minConcurrency = 1
                }
            }
            
            # Create telemetry with high failure rate
            $telemetryRecords = @(
                @{ tenantId = 'test-tenant-id'; operationsAttempted = 100; operationsFailed = 50; timestamp = (Get-Date).ToString('o') }
            )
            $telemetryRecords | ForEach-Object { $_ | ConvertTo-Json -Compress | Add-Content -Path $script:TestTelemetryFile }
            
            $result = Update-PhishIRTenantRateLimits -Tenant $testTenant -TelemetryPath $script:TestTelemetryFile
            
            # Should not decrease below minimum
            $testTenant.execution.concurrency | Should -Be 1
        }

        It 'Should respect maximum concurrency limit' {
            $testTenant = [PSCustomObject]@{
                displayName = 'Test Tenant'
                tenantId = 'test-tenant-id'
                execution = [PSCustomObject]@{
                    concurrency = 8
                    baseConcurrency = 4
                }
                rateAdaptation = [PSCustomObject]@{
                    enabled = $true
                    telemetryWindow = 5
                    failureThreshold = 0.3
                    successBoostThreshold = 0.05
                    maxConcurrency = 8
                    minConcurrency = 1
                }
            }
            
            # Create telemetry with low failure rate
            $telemetryRecords = @(
                @{ tenantId = 'test-tenant-id'; operationsAttempted = 100; operationsFailed = 1; timestamp = (Get-Date).ToString('o') }
            )
            $telemetryRecords | ForEach-Object { $_ | ConvertTo-Json -Compress | Add-Content -Path $script:TestTelemetryFile }
            
            $result = Update-PhishIRTenantRateLimits -Tenant $testTenant -TelemetryPath $script:TestTelemetryFile
            
            # Should not increase above maximum
            $result.Adjusted | Should -Be $false
        }
    }

    Context 'DryRun Mode' {
        It 'Should not modify tenant when DryRun specified' {
            $testTenant = [PSCustomObject]@{
                displayName = 'Test Tenant'
                tenantId = 'test-tenant-id'
                execution = [PSCustomObject]@{
                    concurrency = 4
                    baseConcurrency = 4
                }
                rateAdaptation = [PSCustomObject]@{
                    enabled = $true
                    telemetryWindow = 5
                    failureThreshold = 0.3
                    successBoostThreshold = 0.05
                    maxConcurrency = 8
                    minConcurrency = 1
                }
            }
            
            # Create telemetry with high failure rate
            $telemetryRecords = @(
                @{ tenantId = 'test-tenant-id'; operationsAttempted = 100; operationsFailed = 40; timestamp = (Get-Date).ToString('o') }
            )
            $telemetryRecords | ForEach-Object { $_ | ConvertTo-Json -Compress | Add-Content -Path $script:TestTelemetryFile }
            
            $result = Update-PhishIRTenantRateLimits -Tenant $testTenant -TelemetryPath $script:TestTelemetryFile -DryRun
            
            $result.DryRun | Should -Be $true
            $result.Adjusted | Should -Be $true
            $result.Action | Should -Be 'decrease'
            # Tenant should not be modified
            $testTenant.execution.concurrency | Should -Be 4
        }
    }

    Context 'Telemetry Window' {
        It 'Should only consider records within telemetry window' {
            $testTenant = [PSCustomObject]@{
                displayName = 'Test Tenant'
                tenantId = 'test-tenant-id'
                execution = [PSCustomObject]@{
                    concurrency = 4
                    baseConcurrency = 4
                }
                rateAdaptation = [PSCustomObject]@{
                    enabled = $true
                    telemetryWindow = 2  # Only last 2 records
                    failureThreshold = 0.3
                    successBoostThreshold = 0.05
                    maxConcurrency = 8
                    minConcurrency = 1
                }
            }
            
            # Create telemetry with mixed failure rates
            $telemetryRecords = @(
                @{ tenantId = 'test-tenant-id'; operationsAttempted = 100; operationsFailed = 50; timestamp = (Get-Date).AddHours(-3).ToString('o') }
                @{ tenantId = 'test-tenant-id'; operationsAttempted = 100; operationsFailed = 1; timestamp = (Get-Date).ToString('o') }
                @{ tenantId = 'test-tenant-id'; operationsAttempted = 100; operationsFailed = 2; timestamp = (Get-Date).ToString('o') }
            )
            $telemetryRecords | ForEach-Object { $_ | ConvertTo-Json -Compress | Add-Content -Path $script:TestTelemetryFile }
            
            $result = Update-PhishIRTenantRateLimits -Tenant $testTenant -TelemetryPath $script:TestTelemetryFile
            
            # Should only consider last 2 records (low failure rate)
            $result.Action | Should -Be 'increase'
        }
    }
}
