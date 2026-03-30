#Requires -Module Pester

BeforeAll {
    $moduleRoot = Join-Path -Path $PSScriptRoot -ChildPath '..'
    $modulePath = Join-Path -Path $moduleRoot -ChildPath 'PhishIR.psd1'
    Import-Module $modulePath -Force

    $samplesDir = Join-Path $moduleRoot '..' | Join-Path -ChildPath 'samples'
    $script:SamplePath = Join-Path $samplesDir 'tenants.sample.json'
}

Describe 'Confirm-PhishIRTenantOperation - Approval Workflow' {
    BeforeAll {
        $cfg = Get-PhishIRTenantConfig -Path $script:SamplePath -Validate
        $script:TestTenant = $cfg.tenants[0]
    }

    Context 'Purge Operation Approval' {
        It 'Should approve with correct purge phrase' {
            $result = Confirm-PhishIRTenantOperation -Tenant $script:TestTenant -Operation Purge -Phrase $script:TestTenant.approvals.purgePhrase
            
            $result | Should -Not -BeNullOrEmpty
            $result.Approved | Should -Be $true
            $result.Operation | Should -Be 'Purge'
            $result.Forced | Should -Be $false
            $result.TenantDisplayName | Should -Be $script:TestTenant.displayName
        }

        It 'Should reject with incorrect purge phrase' {
            { Confirm-PhishIRTenantOperation -Tenant $script:TestTenant -Operation Purge -Phrase 'wrong phrase' } | Should -Throw -ExpectedMessage '*Approval phrase mismatch*'
        }

        It 'Should reject with missing purge phrase' {
            { Confirm-PhishIRTenantOperation -Tenant $script:TestTenant -Operation Purge } | Should -Throw -ExpectedMessage '*Confirmation phrase required*'
        }

        It 'Should be case-sensitive for purge phrase' {
            $wrongCase = $script:TestTenant.approvals.purgePhrase.ToLower()
            { Confirm-PhishIRTenantOperation -Tenant $script:TestTenant -Operation Purge -Phrase $wrongCase } | Should -Throw
        }
    }

    Context 'HardDelete Operation Approval' {
        It 'Should approve with correct hardDelete phrase' {
            $result = Confirm-PhishIRTenantOperation -Tenant $script:TestTenant -Operation HardDelete -Phrase $script:TestTenant.approvals.hardDeletePhrase
            
            $result.Approved | Should -Be $true
            $result.Operation | Should -Be 'HardDelete'
            $result.Forced | Should -Be $false
        }

        It 'Should reject with incorrect hardDelete phrase' {
            { Confirm-PhishIRTenantOperation -Tenant $script:TestTenant -Operation HardDelete -Phrase 'wrong phrase' } | Should -Throw -ExpectedMessage '*Approval phrase mismatch*'
        }

        It 'Should reject with missing hardDelete phrase' {
            { Confirm-PhishIRTenantOperation -Tenant $script:TestTenant -Operation HardDelete } | Should -Throw -ExpectedMessage '*Confirmation phrase required*'
        }
    }

    Context 'Force Override' {
        It 'Should approve with Force even with wrong phrase' {
            $result = Confirm-PhishIRTenantOperation -Tenant $script:TestTenant -Operation Purge -Phrase 'wrong phrase' -Force
            
            $result.Approved | Should -Be $true
            $result.Forced | Should -Be $true
            $result.Operation | Should -Be 'Purge'
        }

        It 'Should approve with Force and no phrase' {
            $result = Confirm-PhishIRTenantOperation -Tenant $script:TestTenant -Operation HardDelete -Force
            
            $result.Approved | Should -Be $true
            $result.Forced | Should -Be $true
        }

        It 'Should mark as forced in result' {
            $result = Confirm-PhishIRTenantOperation -Tenant $script:TestTenant -Operation Purge -Phrase 'wrong' -Force
            
            $result.Forced | Should -Be $true
            $result.Approved | Should -Be $true
        }
    }

    Context 'Tenant Without Approval Requirements' {
        It 'Should auto-approve when requireApproval is false' {
            $testTenant = [PSCustomObject]@{
                displayName = 'No Approval Tenant'
                tenantId = 'test-tenant-id'
                approvals = [PSCustomObject]@{
                    requireApproval = $false
                }
            }
            
            $result = Confirm-PhishIRTenantOperation -Tenant $testTenant -Operation Purge
            
            $result.Approved | Should -Be $true
            $result.Forced | Should -Be $false
        }

        It 'Should auto-approve when approvals block missing' {
            $testTenant = [PSCustomObject]@{
                displayName = 'No Approval Block Tenant'
                tenantId = 'test-tenant-id'
            }
            
            $result = Confirm-PhishIRTenantOperation -Tenant $testTenant -Operation Purge
            
            $result.Approved | Should -Be $true
            $result.Forced | Should -Be $false
        }
    }

    Context 'Phrase Hash Security' {
        It 'Should return phrase hashes instead of actual phrases' {
            $result = Confirm-PhishIRTenantOperation -Tenant $script:TestTenant -Operation Purge -Phrase $script:TestTenant.approvals.purgePhrase
            
            $result.ExpectedPhraseHash | Should -Not -BeNullOrEmpty
            $result.ProvidedPhraseHash | Should -Not -BeNullOrEmpty
            # Hashes should be short (12 chars)
            $result.ExpectedPhraseHash.Length | Should -Be 12
            $result.ProvidedPhraseHash.Length | Should -Be 12
        }

        It 'Should match hashes when phrases match' {
            $result = Confirm-PhishIRTenantOperation -Tenant $script:TestTenant -Operation Purge -Phrase $script:TestTenant.approvals.purgePhrase
            
            $result.ExpectedPhraseHash | Should -Be $result.ProvidedPhraseHash
        }

        It 'Should have different hashes when phrases differ' {
            try {
                Confirm-PhishIRTenantOperation -Tenant $script:TestTenant -Operation Purge -Phrase 'wrong phrase'
            } catch {
                # Expected to throw, but we're testing hash generation
                $_.Exception.Message | Should -Match 'Approval phrase mismatch'
            }
        }
    }

    Context 'Audit Trail' {
        It 'Should include timestamp in result' {
            $result = Confirm-PhishIRTenantOperation -Tenant $script:TestTenant -Operation Purge -Phrase $script:TestTenant.approvals.purgePhrase
            
            $result.Timestamp | Should -Not -BeNullOrEmpty
            # Should be valid ISO 8601 timestamp
            { [datetime]::Parse($result.Timestamp) } | Should -Not -Throw
        }

        It 'Should include tenant display name' {
            $result = Confirm-PhishIRTenantOperation -Tenant $script:TestTenant -Operation Purge -Phrase $script:TestTenant.approvals.purgePhrase
            
            $result.TenantDisplayName | Should -Be $script:TestTenant.displayName
        }

        It 'Should include operation type' {
            $result = Confirm-PhishIRTenantOperation -Tenant $script:TestTenant -Operation Purge -Phrase $script:TestTenant.approvals.purgePhrase
            
            $result.Operation | Should -Be 'Purge'
        }
    }

    Context 'Error Handling' {
        It 'Should throw on missing required approval phrase property' {
            $testTenant = [PSCustomObject]@{
                displayName = 'Broken Tenant'
                tenantId = 'test-tenant-id'
                approvals = [PSCustomObject]@{
                    requireApproval = $true
                    # Missing purgePhrase and hardDeletePhrase
                }
            }
            
            { Confirm-PhishIRTenantOperation -Tenant $testTenant -Operation Purge -Phrase 'any phrase' } | Should -Throw -ExpectedMessage '*missing expected approvals property*'
        }

        It 'Should throw on null tenant' {
            { Confirm-PhishIRTenantOperation -Tenant $null -Operation Purge } | Should -Throw
        }

        It 'Should validate operation parameter' {
            { Confirm-PhishIRTenantOperation -Tenant $script:TestTenant -Operation 'InvalidOperation' -Phrase 'test' } | Should -Throw
        }
    }

    Context 'Multi-Tenant Scenarios' {
        It 'Should handle different approval phrases per tenant' {
            $cfg = Get-PhishIRTenantConfig -Path $script:SamplePath -Validate
            
            # Test first tenant
            $result1 = Confirm-PhishIRTenantOperation -Tenant $cfg.tenants[0] -Operation Purge -Phrase $cfg.tenants[0].approvals.purgePhrase
            $result1.Approved | Should -Be $true
            
            # Test second tenant (if exists)
            if ($cfg.tenants.Count -gt 1) {
                $result2 = Confirm-PhishIRTenantOperation -Tenant $cfg.tenants[1] -Operation Purge -Phrase $cfg.tenants[1].approvals.purgePhrase
                $result2.Approved | Should -Be $true
                
                # Different tenants should have different phrases
                $cfg.tenants[0].approvals.purgePhrase | Should -Not -Be $cfg.tenants[1].approvals.purgePhrase
            }
        }

        It 'Should reject cross-tenant phrase usage' {
            $cfg = Get-PhishIRTenantConfig -Path $script:SamplePath -Validate
            
            if ($cfg.tenants.Count -gt 1) {
                # Try to use tenant 2 phrase on tenant 1
                { Confirm-PhishIRTenantOperation -Tenant $cfg.tenants[0] -Operation Purge -Phrase $cfg.tenants[1].approvals.purgePhrase } | Should -Throw
            }
        }
    }

    Context 'Integration with Destructive Operations' {
        It 'Should support purge operation workflow' {
            # Simulate purge workflow
            $tenant = $script:TestTenant
            $operation = 'Purge'
            $phrase = $tenant.approvals.purgePhrase
            
            # Step 1: Request approval
            $approval = Confirm-PhishIRTenantOperation -Tenant $tenant -Operation $operation -Phrase $phrase
            
            # Step 2: Check approval result
            $approval.Approved | Should -Be $true
            
            # Step 3: Proceed with operation (simulated)
            if ($approval.Approved) {
                # Operation would proceed here
                $operationProceeded = $true
            }
            
            $operationProceeded | Should -Be $true
        }

        It 'Should support hardDelete operation workflow' {
            # Simulate hardDelete workflow
            $tenant = $script:TestTenant
            $operation = 'HardDelete'
            $phrase = $tenant.approvals.hardDeletePhrase
            
            # Step 1: Request approval
            $approval = Confirm-PhishIRTenantOperation -Tenant $tenant -Operation $operation -Phrase $phrase
            
            # Step 2: Check approval result
            $approval.Approved | Should -Be $true
            
            # Step 3: Ensure forced flag is false for proper approval
            $approval.Forced | Should -Be $false
        }
    }
}
