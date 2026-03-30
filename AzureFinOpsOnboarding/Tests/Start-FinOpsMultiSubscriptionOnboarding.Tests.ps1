BeforeAll {
    $ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
    Import-Module (Join-Path $ModuleRoot 'AzureFinOpsOnboarding.psd1') -Force
    
    # Mock all the validation functions that the main function calls
    Mock -CommandName Get-FinOpsCostDateWindow -MockWith {
        return @{
            Start = (Get-Date).AddDays(-60)
            End = (Get-Date).AddDays(-30)
        }
    } -ModuleName AzureFinOpsOnboarding
    
    Mock -CommandName Test-FinOpsAzCosts -MockWith {
        return [PSCustomObject]@{
            Success = $true
            ErrorDetail = $null
            RawData = @()
        }
    } -ModuleName AzureFinOpsOnboarding
    
    Mock -CommandName Test-FinOpsAzEmissions -MockWith {
        return [PSCustomObject]@{
            Success = $true
            ErrorDetail = $null
            RawData = @()
        }
    } -ModuleName AzureFinOpsOnboarding
    
    Mock -CommandName Test-FinOpsAzReservations -MockWith {
        return [PSCustomObject]@{
            Success = $true
            ErrorDetail = $null
            RawData = @()
        }
    } -ModuleName AzureFinOpsOnboarding
    
    Mock -CommandName Write-Progress -MockWith { } -ModuleName AzureFinOpsOnboarding
    Mock -CommandName Write-Host -MockWith { } -ModuleName AzureFinOpsOnboarding
    Mock -CommandName Write-Warning -MockWith { } -ModuleName AzureFinOpsOnboarding
}

Describe 'Start-FinOpsMultiSubscriptionOnboarding' {
    
    Context 'Function Structure' {
        
        It 'Should be exported from the module' {
            $cmd = Get-Command Start-FinOpsMultiSubscriptionOnboarding -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty
        }
        
        It 'Should have SubscriptionIds parameter' {
            $cmd = Get-Command Start-FinOpsMultiSubscriptionOnboarding
            $cmd.Parameters.ContainsKey('SubscriptionIds') | Should -Be $true
        }
        
        It 'Should have Token parameter' {
            $cmd = Get-Command Start-FinOpsMultiSubscriptionOnboarding
            $cmd.Parameters.ContainsKey('Token') | Should -Be $true
        }
        
        It 'Should have ThrottleLimit parameter' {
            $cmd = Get-Command Start-FinOpsMultiSubscriptionOnboarding
            $cmd.Parameters.ContainsKey('ThrottleLimit') | Should -Be $true
        }
        
        It 'Should have CustomerName parameter' {
            $cmd = Get-Command Start-FinOpsMultiSubscriptionOnboarding
            $cmd.Parameters.ContainsKey('CustomerName') | Should -Be $true
        }
    }
    
    Context 'Basic Execution' {
        
        It 'Should execute successfully with minimum parameters' {
            { Start-FinOpsMultiSubscriptionOnboarding -SubscriptionIds @('test-sub-1') -Token 'test-token-123' } | Should -Not -Throw
        }
        
        It 'Should return an object with SubscriptionCount' {
            $result = Start-FinOpsMultiSubscriptionOnboarding -SubscriptionIds @('test-sub-2') -Token 'test-token-456'
            
            $result | Should -Not -BeNullOrEmpty
            $result.SubscriptionCount | Should -Be 1
        }
        
        It 'Should process multiple subscriptions' {
            $result = Start-FinOpsMultiSubscriptionOnboarding -SubscriptionIds @('sub-1', 'sub-2', 'sub-3') -Token 'test-token-789'
            $result.SubscriptionCount | Should -Be 3
        }
        
        It 'Should include PowerShell version' {
            $result = Start-FinOpsMultiSubscriptionOnboarding -SubscriptionIds @('test-sub-3') -Token 'test-token-abc'
            
            $result.PowerShellVersion | Should -Not -BeNullOrEmpty
            $result.PowerShellVersion | Should -Match '^\d+\.\d+'
        }
        
        It 'Should include ProcessingMode' {
            $result = Start-FinOpsMultiSubscriptionOnboarding -SubscriptionIds @('test-sub-4') -Token 'test-token-def'
            
            $result.ProcessingMode | Should -Not -BeNullOrEmpty
            $result.ProcessingMode | Should -BeIn @('Parallel', 'Sequential')
        }
    }
    
    Context 'Mock Invocation' {
        
        It 'Should call Get-FinOpsCostDateWindow once' {
            $null = Start-FinOpsMultiSubscriptionOnboarding -SubscriptionIds @('test-sub-5') -Token 'test-token-ghi'
            
            Should -Invoke -CommandName Get-FinOpsCostDateWindow -ModuleName AzureFinOpsOnboarding -Times 1 -Exactly
        }
        
        It 'Should process multiple subscriptions successfully' {
            # This test verifies the function works with multiple subscriptions without checking exact mock counts
            $result = Start-FinOpsMultiSubscriptionOnboarding -SubscriptionIds @('sub-a', 'sub-b') -Token 'test-token-jkl'
            
            $result | Should -Not -BeNullOrEmpty
            $result.SubscriptionCount | Should -Be 2
            $result.Results.Count | Should -Be 2
        }
        
        It 'Should skip costs when -SkipCosts specified' {
            $null = Start-FinOpsMultiSubscriptionOnboarding -SubscriptionIds @('test-sub-6') -Token 'test-token-mno' -SkipCosts
            
            Should -Invoke -CommandName Test-FinOpsAzCosts -ModuleName AzureFinOpsOnboarding -Times 0 -Exactly
        }
    }
}
