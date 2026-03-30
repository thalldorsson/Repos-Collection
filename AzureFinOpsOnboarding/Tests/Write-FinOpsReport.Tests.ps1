Import-Module Pester

Describe 'Write-FinOpsReport' {
    BeforeAll {
    }
    
    Context 'Parameter Validation' {
        It 'Should have mandatory parameters' {
            $cmd = Get-Command Write-FinOpsReport
            $cmd.Parameters['Path'].Attributes.Mandatory | Should -Be $true
            $cmd.Parameters['OrchestratorObject'].Attributes.Mandatory | Should -Be $true
        }
    }
    
    Context 'Report Generation' {
        BeforeEach {
            $reportPath = Join-Path -Path $TestDrive -ChildPath 'report.md'
            
            $mockOrchestrator = [PSCustomObject]@{
                GeneratedAt = '2024-01-01T12:00:00Z'
                ToolVersion = 'v0.2.1'
                Customer = [PSCustomObject]@{
                    Name = 'Test Customer'
                    PrimaryDomain = 'test.com'
                    TenantId = '12345678-1234-1234-1234-123456789012'
                    ApplicationId = '87654321-4321-4321-4321-210987654321'
                    IsEA = $true
                    CompanyName = 'Test Company'
                    Country = 'US'
                    TenantName = 'Test Tenant'
                }
                Identifiers = [PSCustomObject]@{
                    EnrollmentId = 'EA123'
                    MCABillingId = 'MCA456'
                    SecretName = 'test-secret'
                    SecretExpiry = '2024-12-31'
                }
                Checks = @(
                    [PSCustomObject]@{
                        Name = 'Subscriptions'
                        Success = $true
                        Metrics = @{ Count = 5 }
                        Error = $null
                    },
                    [PSCustomObject]@{
                        Name = 'Costs'
                        Success = $false
                        Metrics = $null
                        Error = 'API call failed'
                    }
                )
            }
        }
        
        It 'Should create report file' {
            Write-FinOpsReport -Path $reportPath -OrchestratorObject $mockOrchestrator
            Test-Path $reportPath | Should -Be $true
        }
        
        It 'Should include customer name in report' {
            Write-FinOpsReport -Path $reportPath -OrchestratorObject $mockOrchestrator
            $content = Get-Content $reportPath -Raw
            $content | Should -Match 'Test Customer'
        }
        
        It 'Should include check summary table' {
            Write-FinOpsReport -Path $reportPath -OrchestratorObject $mockOrchestrator
            $content = Get-Content $reportPath -Raw
            $content | Should -Match 'Check Summary'
            $content | Should -Match 'Subscriptions'
            $content | Should -Match 'Costs'
        }
        
        It 'Should include status indicators for checks' {
            Write-FinOpsReport -Path $reportPath -OrchestratorObject $mockOrchestrator
            $content = Get-Content $reportPath -Raw
            # Table should have status column
            $content | Should -Match '\| Status \|'
        }
        
        It 'Should include failed check details' {
            Write-FinOpsReport -Path $reportPath -OrchestratorObject $mockOrchestrator
            $content = Get-Content $reportPath -Raw
            $content | Should -Match 'Failed Check Details'
            $content | Should -Match 'API call failed'
        }
        
        It 'Should create directory if it does not exist' {
            $nestedPath = Join-Path -Path $TestDrive -ChildPath 'nested/dir/report.md'
            Write-FinOpsReport -Path $nestedPath -OrchestratorObject $mockOrchestrator
            Test-Path $nestedPath | Should -Be $true
        }
    }
}

