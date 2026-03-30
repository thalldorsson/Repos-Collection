Import-Module Pester

Describe 'Write-FinOpsManifest' {
    BeforeAll {
    }
    
    Context 'Parameter Validation' {
        It 'Should have mandatory parameters' {
            $cmd = Get-Command Write-FinOpsManifest
            $cmd.Parameters['Path'].Attributes.Mandatory | Should -Be $true
            $cmd.Parameters['OrchestratorObject'].Attributes.Mandatory | Should -Be $true
        }
    }
    
    Context 'Manifest Generation' {
        BeforeEach {
            $manifestPath = Join-Path -Path $TestDrive -ChildPath 'manifest.json'
            
            $mockOrchestrator = [PSCustomObject]@{
                SchemaVersion = '1.0'
                ToolVersion = 'v0.2.1'
                GeneratedAt = '2024-01-01T12:00:00Z'
                Customer = [PSCustomObject]@{
                    Name = 'Test Customer'
                    PrimaryDomain = 'test.com'
                    TenantId = '12345678-1234-1234-1234-123456789012'
                }
                Checks = @(
                    [PSCustomObject]@{
                        Name = 'Subscriptions'
                        Success = $true
                        Metrics = @{ Count = 5 }
                    }
                )
            }
        }
        
        It 'Should create manifest file' {
            Write-FinOpsManifest -Path $manifestPath -OrchestratorObject $mockOrchestrator
            Test-Path $manifestPath | Should -Be $true
        }
        
        It 'Should create valid JSON' {
            Write-FinOpsManifest -Path $manifestPath -OrchestratorObject $mockOrchestrator
            $content = Get-Content $manifestPath -Raw
            { $content | ConvertFrom-Json } | Should -Not -Throw
        }
        
        It 'Should include SchemaVersion in JSON' {
            Write-FinOpsManifest -Path $manifestPath -OrchestratorObject $mockOrchestrator
            $json = Get-Content $manifestPath -Raw | ConvertFrom-Json
            $json.SchemaVersion | Should -Be '1.0'
        }
        
        It 'Should include Customer information in JSON' {
            Write-FinOpsManifest -Path $manifestPath -OrchestratorObject $mockOrchestrator
            $json = Get-Content $manifestPath -Raw | ConvertFrom-Json
            $json.Customer.Name | Should -Be 'Test Customer'
            $json.Customer.PrimaryDomain | Should -Be 'test.com'
        }
        
        It 'Should include Checks array in JSON' {
            Write-FinOpsManifest -Path $manifestPath -OrchestratorObject $mockOrchestrator
            $json = Get-Content $manifestPath -Raw | ConvertFrom-Json
            (($json.Checks | Measure-Object).Count) | Should -Be 1
            $json.Checks[0].Name | Should -Be 'Subscriptions'
        }
        
        It 'Should create directory if it does not exist' {
            $nestedPath = Join-Path -Path $TestDrive -ChildPath 'nested/dir/manifest.json'
            Write-FinOpsManifest -Path $nestedPath -OrchestratorObject $mockOrchestrator
            Test-Path $nestedPath | Should -Be $true
        }
    }
}


