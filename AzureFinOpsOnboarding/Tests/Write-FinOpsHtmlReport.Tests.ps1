Import-Module Pester

Describe 'Write-FinOpsHtmlReport' {
    BeforeAll {
    }
    
    Context 'Parameter Validation' {
        It 'Should have mandatory parameters' {
            $cmd = Get-Command Write-FinOpsHtmlReport
            $cmd.Parameters['Path'].Attributes.Mandatory | Should -Be $true
            $cmd.Parameters['OrchestratorObject'].Attributes.Mandatory | Should -Be $true
        }
    }
    
    Context 'HTML Report Generation' {
        BeforeEach {
            $reportPath = Join-Path -Path $TestDrive -ChildPath 'report.html'
            
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
        
        It 'Should create HTML report file' {
            Write-FinOpsHtmlReport -Path $reportPath -OrchestratorObject $mockOrchestrator
            Test-Path $reportPath | Should -Be $true
        }
        
        It 'Should create valid HTML with DOCTYPE' {
            Write-FinOpsHtmlReport -Path $reportPath -OrchestratorObject $mockOrchestrator
            $content = Get-Content $reportPath -Raw
            $content | Should -Match '<!DOCTYPE html>'
        }
        
        It 'Should include customer name in HTML' {
            Write-FinOpsHtmlReport -Path $reportPath -OrchestratorObject $mockOrchestrator
            $content = Get-Content $reportPath -Raw
            $content | Should -Match 'Test Customer'
        }
        
        It 'Should include check results table' {
            Write-FinOpsHtmlReport -Path $reportPath -OrchestratorObject $mockOrchestrator
            $content = Get-Content $reportPath -Raw
            $content | Should -Match '<table>'
            $content | Should -Match 'Subscriptions'
            $content | Should -Match 'Costs'
        }
        
        It 'Should include CSS styling' {
            Write-FinOpsHtmlReport -Path $reportPath -OrchestratorObject $mockOrchestrator
            $content = Get-Content $reportPath -Raw
            $content | Should -Match '<style>'
            $content | Should -Match 'font-family'
        }
        
        It 'Should include status badges' {
            Write-FinOpsHtmlReport -Path $reportPath -OrchestratorObject $mockOrchestrator
            $content = Get-Content $reportPath -Raw
            $content | Should -Match 'badge'
        }
        
        It 'Should include failed check details section when there are failures' {
            Write-FinOpsHtmlReport -Path $reportPath -OrchestratorObject $mockOrchestrator
            $content = Get-Content $reportPath -Raw
            $content | Should -Match 'Failed Check Details'
            $content | Should -Match 'API call failed'
        }
        
        It 'Should create directory if it does not exist' {
            $nestedPath = Join-Path -Path $TestDrive -ChildPath 'nested/dir/report.html'
            Write-FinOpsHtmlReport -Path $nestedPath -OrchestratorObject $mockOrchestrator
            Test-Path $nestedPath | Should -Be $true
        }
        
        It 'Should include all customer information fields' {
            Write-FinOpsHtmlReport -Path $reportPath -OrchestratorObject $mockOrchestrator
            $content = Get-Content $reportPath -Raw
            $content | Should -Match 'Primary Domain'
            $content | Should -Match 'Tenant ID'
            $content | Should -Match 'Application ID'
        }
    }
}

