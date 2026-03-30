BeforeAll {
    Import-Module $PSScriptRoot\..\..\AzureFinOpsOnboarding.psd1 -Force
    
    # Default test values
    $script:TestBaseUrl = 'https://test.atlassian.net'
    $script:TestIssueKey = 'TEST-123'
    $script:TestUsername = 'test@example.com'
    $script:TestApiToken = ConvertTo-SecureString -String 'test-token' -AsPlainText -Force
    $script:TestComment = 'Test comment from Pester'
}

Describe 'Add-FinOpsJiraComment' {
    It 'should post comment via REST when credentials provided' {
        Mock Invoke-FinOpsJiraPost { return @{ id = 'comment-123'; body = $Body } }
        
        $result = Add-FinOpsJiraComment -BaseUrl $TestBaseUrl -IssueKey $TestIssueKey `
            -Comment $TestComment -Username $TestUsername -ApiToken $TestApiToken
        
        Assert-MockCalled Invoke-FinOpsJiraPost -Times 1
        $result.id | Should -Be 'comment-123'
    }

    It 'should use MCP delegate when UseAtlassianMcp specified' {
        Mock Invoke-FinOpsJiraPost { throw 'Should not call REST' }
        
        $delegateScript = { param($IssueKey, $Comment) return @{ id = 'mcp-comment'; body = $Comment } }
        Register-FinOpsAtlassianMcpProvider -AddCommentScript $delegateScript
        
        $result = Add-FinOpsJiraComment -IssueKey $TestIssueKey -Comment $TestComment -UseAtlassianMcp
        
        $result.id | Should -Be 'mcp-comment'
        Assert-MockCalled Invoke-FinOpsJiraPost -Times 0
    }

    It 'should throw when MCP delegate missing' {
        $script:AtlassianMcpProvider = @{}
        
        { Add-FinOpsJiraComment -IssueKey $TestIssueKey -Comment $TestComment -UseAtlassianMcp } | 
            Should -Throw -ExpectedMessage '*AddComment delegate*'
    }

    It 'should support ADF format' {
        Mock Invoke-FinOpsJiraPost { return @{ id = 'adf-comment'; body = $Body } }
        
        $result = Add-FinOpsJiraComment -BaseUrl $TestBaseUrl -IssueKey $TestIssueKey `
            -Comment $TestComment -Username $TestUsername -ApiToken $TestApiToken -UseAdf
        
        Assert-MockCalled Invoke-FinOpsJiraPost -Times 1
        $callArgs = @(Get-MockCallArgs -CommandName Invoke-FinOpsJiraPost)
        # Body should contain ADF structure when -UseAdf specified
        $callArgs[0].Body | Should -Match 'version.*type.*content'
    }

    It 'should throw without credentials when not using MCP' {
        { Add-FinOpsJiraComment -IssueKey $TestIssueKey -Comment $TestComment } | 
            Should -Throw -ExpectedMessage '*Username*required*'
    }
}

Describe 'Get-FinOpsJiraIssueTransitions' {
    It 'should retrieve available transitions' {
        $mockResponse = @{
            transitions = @(
                @{ id = '11'; name = 'Start'; to = @{ name = 'In Progress' } }
                @{ id = '31'; name = 'Done'; to = @{ name = 'Done' } }
            )
        }
        Mock Invoke-FinOpsJiraGet { return $mockResponse }
        
        $transitions = Get-FinOpsJiraIssueTransitions -BaseUrl $TestBaseUrl -IssueKey $TestIssueKey `
            -Username $TestUsername -ApiToken $TestApiToken
        
        $transitions | Should -HaveCount 2
        $transitions[0].name | Should -Be 'Start'
        $transitions[1].to.name | Should -Be 'Done'
    }

    It 'should throw without credentials' {
        { Get-FinOpsJiraIssueTransitions -IssueKey $TestIssueKey } | 
            Should -Throw -ExpectedMessage '*Username*required*'
    }

    It 'should format transition ID and target status correctly' {
        $mockResponse = @{
            transitions = @(
                @{ id = '31'; name = 'Resolve'; to = @{ name = 'Resolved' } }
            )
        }
        Mock Invoke-FinOpsJiraGet { return $mockResponse }
        
        $transitions = Get-FinOpsJiraIssueTransitions -BaseUrl $TestBaseUrl -IssueKey $TestIssueKey `
            -Username $TestUsername -ApiToken $TestApiToken
        
        $transitions[0].id | Should -Be '31'
        $transitions[0].to.name | Should -Be 'Resolved'
    }
}

Describe 'Update-FinOpsJiraIssueStatus' {
    It 'should transition issue when valid status provided' {
        $mockTransitions = @{
            transitions = @(
                @{ id = '31'; name = 'Done'; to = @{ name = 'Done' } }
            )
        }
        Mock Invoke-FinOpsJiraGet { return $mockTransitions }
        Mock Invoke-FinOpsJiraPost { return $null }
        
        Update-FinOpsJiraIssueStatus -BaseUrl $TestBaseUrl -IssueKey $TestIssueKey `
            -TargetStatus 'Done' -Username $TestUsername -ApiToken $TestApiToken
        
        Assert-MockCalled Invoke-FinOpsJiraPost -Times 1
    }

    It 'should throw when target status not available' {
        $mockTransitions = @{
            transitions = @(
                @{ id = '11'; name = 'Start'; to = @{ name = 'In Progress' } }
            )
        }
        Mock Invoke-FinOpsJiraGet { return $mockTransitions }
        
        { Update-FinOpsJiraIssueStatus -BaseUrl $TestBaseUrl -IssueKey $TestIssueKey `
            -TargetStatus 'NonExistent' -Username $TestUsername -ApiToken $TestApiToken } | 
            Should -Throw -ExpectedMessage '*not found in available transitions*'
    }

    It 'should include comment in transition when provided' {
        $mockTransitions = @{
            transitions = @(
                @{ id = '31'; name = 'Done'; to = @{ name = 'Done' } }
            )
        }
        Mock Invoke-FinOpsJiraGet { return $mockTransitions }
        Mock Invoke-FinOpsJiraPost { return $null }
        
        Update-FinOpsJiraIssueStatus -BaseUrl $TestBaseUrl -IssueKey $TestIssueKey `
            -TargetStatus 'Done' -Comment 'Completed successfully' -Username $TestUsername -ApiToken $TestApiToken
        
        $callArgs = @(Get-MockCallArgs -CommandName Invoke-FinOpsJiraPost)
        $callArgs[0].Body | Should -Match 'comment'
    }

    It 'should use MCP delegate when specified' {
        Mock Invoke-FinOpsJiraGet { throw 'Should not call REST' }
        Mock Invoke-FinOpsJiraPost { throw 'Should not call REST' }
        
        $delegateScript = { param($IssueKey, $TargetStatus, $Comment) return $true }
        Register-FinOpsAtlassianMcpProvider -TransitionIssueScript $delegateScript
        
        $result = Update-FinOpsJiraIssueStatus -IssueKey $TestIssueKey -TargetStatus 'Done' -UseAtlassianMcp
        
        $result | Should -Be $true
        Assert-MockCalled Invoke-FinOpsJiraGet -Times 0
    }

    It 'should require credentials or MCP' {
        { Update-FinOpsJiraIssueStatus -IssueKey $TestIssueKey -TargetStatus 'Done' } | 
            Should -Throw -ExpectedMessage '*Username*required*'
    }
}

Describe 'Update-FinOpsJiraIssueField' {
    It 'should update issue fields via REST' {
        Mock Invoke-FinOpsJiraPut { return $null }
        
        $fields = @{ summary = 'Updated title'; labels = @('finops') }
        Update-FinOpsJiraIssueField -BaseUrl $TestBaseUrl -IssueKey $TestIssueKey `
            -Fields $fields -Username $TestUsername -ApiToken $TestApiToken
        
        Assert-MockCalled Invoke-FinOpsJiraPut -Times 1
    }

    It 'should use MCP delegate when specified' {
        Mock Invoke-FinOpsJiraPut { throw 'Should not call REST' }
        
        $delegateScript = { param($IssueKey, $Fields) return $true }
        Register-FinOpsAtlassianMcpProvider -UpdateIssueFieldsScript $delegateScript
        
        $fields = @{ summary = 'Updated' }
        $result = Update-FinOpsJiraIssueField -IssueKey $TestIssueKey -Fields $fields -UseAtlassianMcp
        
        $result | Should -Be $true
        Assert-MockCalled Invoke-FinOpsJiraPut -Times 0
    }

    It 'should handle empty fields hashtable' {
        Mock Invoke-FinOpsJiraPut { return $null }
        
        Update-FinOpsJiraIssueField -BaseUrl $TestBaseUrl -IssueKey $TestIssueKey `
            -Fields @{} -Username $TestUsername -ApiToken $TestApiToken
        
        Assert-MockCalled Invoke-FinOpsJiraPut -Times 1
    }
}

Describe 'Publish-FinOpsOnboardingToJira' {
    It 'should post summary comment and optionally transition' {
        Mock Add-FinOpsJiraComment { return $null }
        Mock Update-FinOpsJiraIssueStatus { return $null }
        
        $orchestrator = @{
            Customer = @{ Name = 'Contoso'; TenantId = 'test-tenant'; PrimaryDomain = 'contoso.com' }
            Checks = @(
                @{ Name = 'Subscriptions'; Success = $true; ErrorDetail = 'OK' }
                @{ Name = 'Costs'; Success = $false; ErrorDetail = 'No data' }
            )
            GeneratedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
        
        Publish-FinOpsOnboardingToJira -OrchestratorObject $orchestrator -IssueKey $TestIssueKey `
            -BaseUrl $TestBaseUrl -Username $TestUsername -ApiToken $TestApiToken
        
        Assert-MockCalled Add-FinOpsJiraComment -Times 1
        Assert-MockCalled Update-FinOpsJiraIssueStatus -Times 0
    }

    It 'should transition issue when TransitionToStatus provided' {
        Mock Add-FinOpsJiraComment { return $null }
        Mock Update-FinOpsJiraIssueStatus { return $null }
        
        $orchestrator = @{
            Customer = @{ Name = 'Contoso'; TenantId = 'test-tenant'; PrimaryDomain = 'contoso.com' }
            Checks = @( @{ Name = 'Test'; Success = $true; ErrorDetail = 'OK' } )
            GeneratedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
        
        Publish-FinOpsOnboardingToJira -OrchestratorObject $orchestrator -IssueKey $TestIssueKey `
            -BaseUrl $TestBaseUrl -Username $TestUsername -ApiToken $TestApiToken -TransitionToStatus 'Done'
        
        Assert-MockCalled Add-FinOpsJiraComment -Times 1
        Assert-MockCalled Update-FinOpsJiraIssueStatus -Times 1
    }

    It 'should include check results in comment' {
        Mock Add-FinOpsJiraComment { 
            $Comment -match 'Contoso' | Should -Be $true
            $Comment -match '1/2' | Should -Be $true
            return $null 
        }
        
        $orchestrator = @{
            Customer = @{ Name = 'Contoso'; TenantId = 'test-tenant'; PrimaryDomain = 'contoso.com' }
            Checks = @(
                @{ Name = 'Check1'; Success = $true; ErrorDetail = 'OK' }
                @{ Name = 'Check2'; Success = $true; ErrorDetail = 'OK' }
            )
            GeneratedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
        
        Publish-FinOpsOnboardingToJira -OrchestratorObject $orchestrator -IssueKey $TestIssueKey `
            -BaseUrl $TestBaseUrl -Username $TestUsername -ApiToken $TestApiToken
        
        Assert-MockCalled Add-FinOpsJiraComment -Times 1
    }

    It 'should support MCP delegates' {
        Mock Add-FinOpsJiraComment { throw 'Should use MCP' }
        Mock Update-FinOpsJiraIssueStatus { throw 'Should use MCP' }
        
        $addScript = { param($IssueKey, $Comment) return $null }
        $transScript = { param($IssueKey, $TargetStatus) return $null }
        Register-FinOpsAtlassianMcpProvider -AddCommentScript $addScript -TransitionIssueScript $transScript
        
        $orchestrator = @{
            Customer = @{ Name = 'Contoso'; TenantId = 'test-tenant'; PrimaryDomain = 'contoso.com' }
            Checks = @( @{ Name = 'Test'; Success = $true; ErrorDetail = 'OK' } )
            GeneratedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
        
        # Should not throw because MCP delegates are used
        { Publish-FinOpsOnboardingToJira -OrchestratorObject $orchestrator -IssueKey $TestIssueKey `
            -BaseUrl $TestBaseUrl -TransitionToStatus 'Done' -UseAtlassianMcp } | Should -Not -Throw
    }
}

Describe 'Register-FinOpsAtlassianMcpProvider write delegates' {
    It 'should register AddComment delegate' {
        $script = { param($IssueKey, $Comment) return $true }
        Register-FinOpsAtlassianMcpProvider -AddCommentScript $script
        
        $script:AtlassianMcpProvider.AddComment | Should -Not -BeNullOrEmpty
    }

    It 'should register GetTransitions delegate' {
        $script = { param($IssueKey) return @() }
        Register-FinOpsAtlassianMcpProvider -GetTransitionsScript $script
        
        $script:AtlassianMcpProvider.GetTransitions | Should -Not -BeNullOrEmpty
    }

    It 'should register TransitionIssue delegate' {
        $script = { param($IssueKey, $TargetStatus, $Comment) return $true }
        Register-FinOpsAtlassianMcpProvider -TransitionIssueScript $script
        
        $script:AtlassianMcpProvider.TransitionIssue | Should -Not -BeNullOrEmpty
    }

    It 'should register UpdateIssueFields delegate' {
        $script = { param($IssueKey, $Fields) return $null }
        Register-FinOpsAtlassianMcpProvider -UpdateIssueFieldsScript $script
        
        $script:AtlassianMcpProvider.UpdateIssueFields | Should -Not -BeNullOrEmpty
    }

    It 'should preserve existing delegates when adding new ones' {
        $getScript = { param($IssueKey) return @{ key = $IssueKey } }
        Register-FinOpsAtlassianMcpProvider -GetIssueScript $getScript
        
        $addScript = { param($IssueKey, $Comment) return @{ id = 'comment' } }
        Register-FinOpsAtlassianMcpProvider -AddCommentScript $addScript
        
        $script:AtlassianMcpProvider.GetIssue | Should -Not -BeNullOrEmpty
        $script:AtlassianMcpProvider.AddComment | Should -Not -BeNullOrEmpty
    }
}

Describe 'Invoke-FinOpsOnboarding Jira Integration' {
    It 'should accept JiraIssueKey parameter' {
        Mock Invoke-FinOpsBearerToken { return 'mock-token' }
        Mock Test-FinOpsAzSubscriptions { return @{ Success = $true; Data = @() } }
        Mock Publish-FinOpsOnboardingToJira { return $null }
        Mock Resolve-FinOpsOutputPath { return @{ Json = 'test.json'; Markdown = 'test.md' } }
        Mock Write-FinOpsManifest { return 'test.json' }
        
        Invoke-FinOpsOnboarding -TenantId 'tenant-id' -ApplicationId 'app-id' -ClientSecret (ConvertTo-SecureString 'secret' -AsPlainText -Force) `
            -CustomerName 'Test' -PrimaryDomain 'test.com' -ReportFormat None `
            -JiraIssueKey 'TEST-123' -PublishToJira -JiraUsername 'test@test.com' -JiraApiToken (ConvertTo-SecureString 'token' -AsPlainText -Force)
        
        Assert-MockCalled Publish-FinOpsOnboardingToJira -Times 1
    }

    It 'should not publish to Jira if PublishToJira not specified' {
        Mock Invoke-FinOpsBearerToken { return 'mock-token' }
        Mock Test-FinOpsAzSubscriptions { return @{ Success = $true; Data = @() } }
        Mock Publish-FinOpsOnboardingToJira { throw 'Should not call' }
        Mock Resolve-FinOpsOutputPath { return @{ Json = 'test.json'; Markdown = 'test.md' } }
        Mock Write-FinOpsManifest { return 'test.json' }
        
        Invoke-FinOpsOnboarding -TenantId 'tenant-id' -ApplicationId 'app-id' -ClientSecret (ConvertTo-SecureString 'secret' -AsPlainText -Force) `
            -CustomerName 'Test' -PrimaryDomain 'test.com' -ReportFormat None `
            -JiraIssueKey 'TEST-123' | Out-Null
        
        Assert-MockCalled Publish-FinOpsOnboardingToJira -Times 0
    }

    It 'should warn if PublishToJira without JiraIssueKey' {
        Mock Invoke-FinOpsBearerToken { return 'mock-token' }
        Mock Test-FinOpsAzSubscriptions { return @{ Success = $true; Data = @() } }
        Mock Resolve-FinOpsOutputPath { return @{ Json = 'test.json'; Markdown = 'test.md' } }
        Mock Write-FinOpsManifest { return 'test.json' }
        Mock Write-Host { }
        
        $warning = $null
        Invoke-FinOpsOnboarding -TenantId 'tenant-id' -ApplicationId 'app-id' -ClientSecret (ConvertTo-SecureString 'secret' -AsPlainText -Force) `
            -CustomerName 'Test' -PrimaryDomain 'test.com' -ReportFormat None `
            -PublishToJira -WarningAction SilentlyContinue 3>&1 | Where-Object { $_ -match 'empty' } | Should -Not -BeNullOrEmpty
    }
}
