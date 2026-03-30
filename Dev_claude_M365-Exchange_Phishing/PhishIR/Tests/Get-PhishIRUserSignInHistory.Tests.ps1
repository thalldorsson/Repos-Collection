#Requires -Module Pester

BeforeAll {
    # Import module
    $modulePath = Join-Path $PSScriptRoot '..' 'PhishIR.psd1'
    Import-Module $modulePath -Force
    
    # Mock Microsoft.Graph.Reports module
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Reports)) {
        New-Module -Name Microsoft.Graph.Reports -ScriptBlock {
            function Get-MgAuditLogSignIn {
                [CmdletBinding()]
                param(
                    [string]$Filter,
                    [string[]]$Property,
                    [int]$Top,
                    [switch]$All
                )
            }
        } | Import-Module
    }
}

Describe 'Get-PhishIRUserSignInHistory' {
    
    BeforeEach {
        # Mock Get-MgAuditLogSignIn
        Mock Get-MgAuditLogSignIn {
            $upn = if ($Filter -match "userPrincipalName eq '([^']+)'") { $Matches[1] } else { 'unknown@test.com' }
            
            # Return mock sign-in data
            return @(
                [PSCustomObject]@{
                    UserPrincipalName = $upn
                    CreatedDateTime = (Get-Date).AddHours(-2)
                    AppDisplayName = 'Office 365 Exchange Online'
                    IpAddress = '203.0.113.10'
                    Location = @{ City = 'Seattle'; CountryOrRegion = 'US' }
                    DeviceDetail = @{ Browser = 'Chrome'; OperatingSystem = 'Windows 10' }
                    Status = @{ ErrorCode = 0 }
                    RiskLevel = 'none'
                }
                [PSCustomObject]@{
                    UserPrincipalName = $upn
                    CreatedDateTime = (Get-Date).AddHours(-5)
                    AppDisplayName = 'Microsoft Teams'
                    IpAddress = '203.0.113.11'
                    Location = @{ City = 'Seattle'; CountryOrRegion = 'US' }
                    DeviceDetail = @{ Browser = 'Edge'; OperatingSystem = 'Windows 11' }
                    Status = @{ ErrorCode = 0 }
                    RiskLevel = 'none'
                }
            )
        }
    }
    
    Context 'Single User Query' {
        
        It 'Should query sign-ins for a single user' {
            $result = Get-PhishIRUserSignInHistory -UserPrincipalNames 'user1@test.com' -DaysBack 7
            
            Should -Invoke Get-MgAuditLogSignIn -Times 1 -Scope It
            $result | Should -Not -BeNullOrEmpty
            $result.Count | Should -Be 2
        }
        
        It 'Should accept pipeline input' {
            $result = 'user1@test.com' | Get-PhishIRUserSignInHistory -DaysBack 7
            
            Should -Invoke Get-MgAuditLogSignIn -Times 1 -Scope It
            $result | Should -Not -BeNullOrEmpty
        }
    }
    
    Context 'Batch Processing' {
        
        It 'Should batch multiple users into single query (default BatchSize 10)' {
            $users = 1..5 | ForEach-Object { "user$_@test.com" }
            
            $result = Get-PhishIRUserSignInHistory -UserPrincipalNames $users -DaysBack 7
            
            # With 5 users and BatchSize 10, should make 1 batched call
            Should -Invoke Get-MgAuditLogSignIn -Times 1 -Scope It
            
            # Verify filter contains OR logic
            $filter = (Get-MockCallHistory Get-MgAuditLogSignIn)[0].BoundParameters.Filter
            $filter | Should -Match 'userPrincipalName eq'
            $filter | Should -Match ' or '
        }
        
        It 'Should split into multiple batches when user count exceeds BatchSize' {
            $users = 1..25 | ForEach-Object { "user$_@test.com" }
            
            $result = Get-PhishIRUserSignInHistory -UserPrincipalNames $users -DaysBack 7 -BatchSize 10
            
            # With 25 users and BatchSize 10, should make 3 batched calls
            Should -Invoke Get-MgAuditLogSignIn -Times 3 -Scope It
        }
        
        It 'Should respect custom BatchSize parameter' {
            $users = 1..15 | ForEach-Object { "user$_@test.com" }
            
            $result = Get-PhishIRUserSignInHistory -UserPrincipalNames $users -DaysBack 7 -BatchSize 5
            
            # With 15 users and BatchSize 5, should make 3 batched calls
            Should -Invoke Get-MgAuditLogSignIn -Times 3 -Scope It
        }
    }
    
    Context 'Date Filtering' {
        
        It 'Should apply DaysBack filter correctly' {
            $result = Get-PhishIRUserSignInHistory -UserPrincipalNames 'user1@test.com' -DaysBack 3
            
            $filter = (Get-MockCallHistory Get-MgAuditLogSignIn)[0].BoundParameters.Filter
            $filter | Should -Match 'createdDateTime ge'
        }
        
        It 'Should use default DaysBack of 7 when not specified' {
            Mock Get-PhishIRConfig { return @{ DefaultDaysBack = 7 } }
            
            $result = Get-PhishIRUserSignInHistory -UserPrincipalNames 'user1@test.com'
            
            $filter = (Get-MockCallHistory Get-MgAuditLogSignIn)[0].BoundParameters.Filter
            $filter | Should -Match 'createdDateTime ge'
        }
    }
    
    Context 'Output Enrichment' {
        
        It 'Should include risky sign-ins detection' {
            Mock Get-MgAuditLogSignIn {
                return @(
                    [PSCustomObject]@{
                        UserPrincipalName = 'user1@test.com'
                        CreatedDateTime = (Get-Date).AddHours(-1)
                        AppDisplayName = 'Office 365'
                        IpAddress = '203.0.113.10'
                        Location = @{ City = 'Seattle'; CountryOrRegion = 'US' }
                        DeviceDetail = @{ Browser = 'Chrome'; OperatingSystem = 'Windows 10' }
                        Status = @{ ErrorCode = 0 }
                        RiskLevel = 'high'
                        RiskState = 'atRisk'
                    }
                )
            }
            
            $result = Get-PhishIRUserSignInHistory -UserPrincipalNames 'user1@test.com' -DaysBack 7
            
            $result[0].RiskLevel | Should -Be 'high'
            $result[0].RiskState | Should -Be 'atRisk'
        }
    }
    
    Context 'Error Handling' {
        
        It 'Should handle Graph API errors gracefully' {
            Mock Get-MgAuditLogSignIn { throw 'Graph API error: Throttled' }
            
            { Get-PhishIRUserSignInHistory -UserPrincipalNames 'user1@test.com' -DaysBack 7 -ErrorAction Stop } | 
                Should -Throw
        }
        
        It 'Should warn when no sign-ins found for user' {
            Mock Get-MgAuditLogSignIn { return @() }
            
            $result = Get-PhishIRUserSignInHistory -UserPrincipalNames 'user1@test.com' -DaysBack 7 -WarningVariable warnings
            
            $warnings | Should -Not -BeNullOrEmpty
            $warnings[0] | Should -Match 'No sign-ins found'
        }
    }
    
    Context 'Parameter Validation' {
        
        It 'Should reject BatchSize below 1' {
            { Get-PhishIRUserSignInHistory -UserPrincipalNames 'user1@test.com' -BatchSize 0 } | 
                Should -Throw
        }
        
        It 'Should reject BatchSize above 100' {
            { Get-PhishIRUserSignInHistory -UserPrincipalNames 'user1@test.com' -BatchSize 150 } | 
                Should -Throw
        }
        
        It 'Should reject DaysBack above 30' {
            { Get-PhishIRUserSignInHistory -UserPrincipalNames 'user1@test.com' -DaysBack 90 } | 
                Should -Throw
        }
    }
    
    Context 'Rate Limiting' {
        
        It 'Should include delay between batches' {
            $users = 1..25 | ForEach-Object { "user$_@test.com" }
            
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $result = Get-PhishIRUserSignInHistory -UserPrincipalNames $users -DaysBack 7 -BatchSize 10
            $stopwatch.Stop()
            
            # With 3 batches and 500ms delay between, should take at least 1 second
            # (Lenient test: at least 0.8s to account for timing variations)
            $stopwatch.Elapsed.TotalSeconds | Should -BeGreaterThan 0.8
        }
    }
}

AfterAll {
    # Cleanup
    Remove-Module Microsoft.Graph.Reports -Force -ErrorAction SilentlyContinue
}
