BeforeAll {
    $ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
    Import-Module (Join-Path $ModuleRoot 'AzureFinOpsOnboarding.psd1') -Force
    
    # Mock ImportExcel module functions
    Mock -CommandName Get-Module -MockWith {
        return [PSCustomObject]@{ Name = 'ImportExcel'; Version = '7.8.0' }
    } -ParameterFilter { $Name -eq 'ImportExcel' -and $ListAvailable } -ModuleName AzureFinOpsOnboarding
    
    Mock -CommandName Import-Module -MockWith { } -ParameterFilter { $Name -eq 'ImportExcel' } -ModuleName AzureFinOpsOnboarding
    
    Mock -CommandName Export-Excel -MockWith { } -ModuleName AzureFinOpsOnboarding
    
    Mock -CommandName New-ConditionalText -MockWith {
        return [PSCustomObject]@{ Text = $Text; BackgroundColor = $BackgroundColor }
    } -ModuleName AzureFinOpsOnboarding
    
    Mock -CommandName Open-ExcelPackage -MockWith {
        # Create a mock cells collection that returns a cell object for any index
        $mockCells = New-Object PSObject
        $mockCells | Add-Member -MemberType ScriptMethod -Name Item -Value {
            param($index)
            # Return a mock cell that can accept Value assignments
            $cell = New-Object PSObject
            $cell | Add-Member -MemberType NoteProperty -Name Value -Value $null
            return $cell
        }
        # Add PowerShell-style indexer support
        $mockCells.PSObject.Methods.Add([psscriptmethod]::new('get_Item', {
            param($index)
            $cell = New-Object PSObject
            $cell | Add-Member -MemberType NoteProperty -Name Value -Value $null
            return $cell
        }))
        
        return [PSCustomObject]@{
            Workbook = [PSCustomObject]@{
                Worksheets = @{
                    Summary = [PSCustomObject]@{
                        Cells = $mockCells
                        Drawings = [PSCustomObject]@{
                            AddChart = { 
                                param($name, $type) 
                                return [PSCustomObject]@{ 
                                    Title = [PSCustomObject]@{ Text = "" }
                                    Series = [PSCustomObject]@{ 
                                        Add = { 
                                            param($a, $b) 
                                            return [PSCustomObject]@{ Header = "" } 
                                        } 
                                    }
                                    SetPosition = { param($a, $b, $c, $d) }
                                    SetSize = { param($a, $b) }
                                } 
                            }
                        }
                    }
                }
            }
        }
    } -ModuleName AzureFinOpsOnboarding
    
    Mock -CommandName Close-ExcelPackage -MockWith { } -ModuleName AzureFinOpsOnboarding
    
    Mock -CommandName Test-Path -MockWith { return $false } -ModuleName AzureFinOpsOnboarding
    
    Mock -CommandName Start-Process -MockWith { } -ModuleName AzureFinOpsOnboarding
}

Describe 'Export-FinOpsReportToExcel' {
    
    Context 'Function Structure' {
        
        It 'Should be exported from module' {
            $cmd = Get-Command Export-FinOpsReportToExcel -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty
        }
        
        It 'Should have required parameters' {
            $cmd = Get-Command Export-FinOpsReportToExcel
            $cmd.Parameters.ContainsKey('Path') | Should -Be $true
            $cmd.Parameters.ContainsKey('OrchestratorObject') | Should -Be $true
        }
        
        It 'Should have optional switches' {
            $cmd = Get-Command Export-FinOpsReportToExcel
            $cmd.Parameters.ContainsKey('IncludeCharts') | Should -Be $true
            $cmd.Parameters.ContainsKey('AutoOpen') | Should -Be $true
        }
    }
    
    Context 'Single Subscription Export' {
        
        BeforeAll {
            $script:mockResult = [PSCustomObject]@{
                CustomerName = "Test Customer"
                TenantId = "12345678-1234-1234-1234-123456789012"
                CheckResults = @(
                    [PSCustomObject]@{ Name = "Costs"; Success = $true; ErrorDetail = $null }
                    [PSCustomObject]@{ Name = "Emissions"; Success = $false; ErrorDetail = "API Error" }
                )
            }
        }
        
        It 'Should execute without errors' {
            { Export-FinOpsReportToExcel -Path "test1.xlsx" -OrchestratorObject $script:mockResult } | Should -Not -Throw
        }
        
        It 'Should call Export-Excel for Summary worksheet' {
            $null = Export-FinOpsReportToExcel -Path "test2.xlsx" -OrchestratorObject $script:mockResult
            
            Should -Invoke -CommandName Export-Excel -ModuleName AzureFinOpsOnboarding -ParameterFilter {
                $WorksheetName -eq "Summary"
            }
        }
        
        It 'Should call Export-Excel for Validation worksheet' {
            $null = Export-FinOpsReportToExcel -Path "test3.xlsx" -OrchestratorObject $script:mockResult
            
            Should -Invoke -CommandName Export-Excel -ModuleName AzureFinOpsOnboarding -ParameterFilter {
                $WorksheetName -eq "Validation"
            }
        }
        
        It 'Should return success result object' {
            $result = Export-FinOpsReportToExcel -Path "test4.xlsx" -OrchestratorObject $script:mockResult
            
            $result | Should -Not -BeNullOrEmpty
            $result.Success | Should -Be $true
            $result.Path | Should -Be "test4.xlsx"
            $result.WorksheetsCreated | Should -Contain "Summary"
        }
    }
    
    Context 'Multi-Subscription Export' {
        
        BeforeAll {
            $script:mockMultiResult = [PSCustomObject]@{
                CustomerName = "Multi Customer"
                TenantId = "12345678-1234-1234-1234-123456789012"
                ProcessingMode = "Parallel"
                PowerShellVersion = "7.4.6"
                SubscriptionCount = 3
                SuccessCount = 2
                FailureCount = 1
                TotalDurationSeconds = 45.5
                AvgSecondsPerSubscription = 15.17
                Results = @(
                    [PSCustomObject]@{
                        SubscriptionId = "sub-001"
                        Success = $true
                        DurationSeconds = 12.3
                        Errors = @()
                        Checks = @{
                            Costs = [PSCustomObject]@{ Success = $true; ErrorDetail = $null }
                            Emissions = [PSCustomObject]@{ Success = $true; ErrorDetail = $null }
                        }
                    }
                    [PSCustomObject]@{
                        SubscriptionId = "sub-002"
                        Success = $true
                        DurationSeconds = 14.1
                        Errors = @()
                        Checks = @{
                            Costs = [PSCustomObject]@{ Success = $true; ErrorDetail = $null }
                            Emissions = [PSCustomObject]@{ Success = $true; ErrorDetail = $null }
                        }
                    }
                    [PSCustomObject]@{
                        SubscriptionId = "sub-003"
                        Success = $false
                        DurationSeconds = 19.1
                        Errors = @("Cost check failed", "Network timeout")
                        Checks = @{
                            Costs = [PSCustomObject]@{ Success = $false; ErrorDetail = "API Error" }
                            Emissions = [PSCustomObject]@{ Success = $false; ErrorDetail = "Timeout" }
                        }
                    }
                )
            }
        }
        
        It 'Should export Summary worksheet with performance metrics' {
            $null = Export-FinOpsReportToExcel -Path "test5.xlsx" -OrchestratorObject $script:mockMultiResult
            
            Should -Invoke -CommandName Export-Excel -ModuleName AzureFinOpsOnboarding -ParameterFilter {
                $WorksheetName -eq "Summary"
            }
        }
        
        It 'Should export Subscriptions worksheet' {
            $null = Export-FinOpsReportToExcel -Path "test6.xlsx" -OrchestratorObject $script:mockMultiResult
            
            Should -Invoke -CommandName Export-Excel -ModuleName AzureFinOpsOnboarding -ParameterFilter {
                $WorksheetName -eq "Subscriptions"
            }
        }
        
        It 'Should export Errors worksheet when errors exist' {
            $null = Export-FinOpsReportToExcel -Path "test7.xlsx" -OrchestratorObject $script:mockMultiResult
            
            Should -Invoke -CommandName Export-Excel -ModuleName AzureFinOpsOnboarding -ParameterFilter {
                $WorksheetName -eq "Errors"
            }
        }
    }
    
    Context 'Charts and AutoOpen' {
        
        BeforeAll {
            $script:mockChartResult = [PSCustomObject]@{
                CustomerName = "Chart Customer"
                Results = @(
                    [PSCustomObject]@{
                        SubscriptionId = "sub-001"
                        Success = $true
                        Checks = @{
                            Costs = [PSCustomObject]@{ Success = $true; ErrorDetail = $null }
                        }
                    }
                )
            }
        }
        
        It 'Should call Open-ExcelPackage when IncludeCharts is specified' {
            $null = Export-FinOpsReportToExcel -Path "test8.xlsx" -OrchestratorObject $script:mockChartResult -IncludeCharts
            
            Should -Invoke -CommandName Open-ExcelPackage -ModuleName AzureFinOpsOnboarding -Times 1
        }
        
        It 'Should call Start-Process when AutoOpen is specified' {
            $null = Export-FinOpsReportToExcel -Path "test9.xlsx" -OrchestratorObject $script:mockChartResult -AutoOpen
            
            Should -Invoke -CommandName Start-Process -ModuleName AzureFinOpsOnboarding -Times 1
        }
    }
}
