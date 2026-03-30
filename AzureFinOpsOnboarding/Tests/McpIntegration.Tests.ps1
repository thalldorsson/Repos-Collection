Import-Module Pester

Describe 'MCP integration and fallback behavior' {
    BeforeAll {
        # Import module once for access to registration function and public functions
        $modulePath = Join-Path $PSScriptRoot '..\AzureFinOpsOnboarding.psd1'
        Import-Module $modulePath -Force
    }

    It 'Get-FinOpsJiraIssueFieldScan returns results using MCP GetIssue delegate' {
        # Register minimal provider that reads cached issue JSON
        Register-FinOpsAtlassianMcpProvider -GetIssueScript {
            param($IssueKey)
            $moduleBase = (Get-Module AzureFinOpsOnboarding).ModuleBase
            $p = Join-Path $moduleBase "Data/JiraIssues/$IssueKey.json"
            if (-not (Test-Path $p)) { throw "Cached issue not found: $IssueKey" }
            Get-Content $p | ConvertFrom-Json
        } | Out-Null

        $rows = Get-FinOpsJiraIssueFieldScan -IssueKey 'CGGS-965' -UseAtlassianMcp
        ($rows | Measure-Object).Count | Should -BeGreaterThan 0
    }

    It 'Find-FinOpsJiraIssueUrls with IncludeRemoteLinks via MCP without delegate throws' {
        { Find-FinOpsJiraIssueUrls -IssueKey 'CGGS-965' -UseAtlassianMcp -IncludeRemoteLinks } | Should -Throw
    }

    It 'Get-FinOpsJiraIssueProperties via MCP throws until properties delegate is provided' {
        { Get-FinOpsJiraIssueProperties -IssueKey 'CGGS-965' -UseAtlassianMcp } | Should -Throw

        Register-FinOpsAtlassianMcpProvider -GetIssuePropertiesScript {
            param($IssueKey,$FetchValues,$ValueContains)
            # Return a minimal sample set
            $items = @(
                [pscustomobject]@{ Key = 'sample.key'; Value = if ($FetchValues) { 'https://example.com' } else { $null }; Length = 19 }
            )
            if ($ValueContains) { $items = $items | Where-Object { $_.Value -and $_.Value -match [regex]::Escape($ValueContains) } }
            $items
        } | Out-Null

        $props = Get-FinOpsJiraIssueProperties -IssueKey 'CGGS-965' -UseAtlassianMcp -FetchValues
        ($props | Measure-Object).Count | Should -BeGreaterThan 0
    }

    It 'Find-FinOpsJiraIssueUrls returns matches using MCP delegates (fields, remote links, comments, properties)' {
        # Register all relevant delegates
        Register-FinOpsAtlassianMcpProvider -GetIssueScript { 
            param($IssueKey,$Expand) 
            @{ key=$IssueKey; fields = @{ summary = 'See https://contoso.com' }; renderedFields = @{ description = '<a href="https://rendered.example">link</a>' } } 
        } -GetRemoteLinksScript { 
            param($IssueKey) 
            @([pscustomobject]@{ id=1; object=@{ url='https://remote.example'; title='Remote' } }) 
        } -GetIssueCommentsScript { 
            param($IssueKey) 
            @{ comments = @(@{ id='1'; body=@{ type='doc'; content=@() } }, @{ id='2'; body=@{ type='doc'; content=@() } }) } 
        } -GetIssuePropertiesScript { 
            param($IssueKey,$FetchValues,$ValueContains) 
            @([pscustomobject]@{ Key='k'; Value='https://property.example'; Length=24 }) 
        } | Out-Null

        $matches = Find-FinOpsJiraIssueUrls -IssueKey 'FOO-1' -UseAtlassianMcp -IncludeRenderedFields -IncludeRemoteLinks -IncludeComments -IncludeProperties
        ($matches | Measure-Object).Count | Should -BeGreaterThan 0
        ($matches | Where-Object Match -eq 'https://remote.example' | Measure-Object).Count | Should -Be 1
    }

    It 'Test-FinOpsJiraIssueVisibility classifies ExistsAndAccessible under MCP' {
        Register-FinOpsAtlassianMcpProvider -SearchScript { 
            param($Jql) 
            @('ABC-123') 
        } -GetIssueScript { 
            param($IssueKey) 
            @{ key=$IssueKey } 
        } | Out-Null

        $res = Test-FinOpsJiraIssueVisibility -IssueKey 'ABC-123' -UseAtlassianMcp
        $res.Classification | Should -Be 'ExistsAndAccessible'
    }

    It 'Find-FinOpsJiraIssueUrls matches URLs from properties only via MCP' {
        Register-FinOpsAtlassianMcpProvider -GetIssueScript { param($IssueKey) @{ key=$IssueKey; fields=@{} } } -GetIssuePropertiesScript {
            param($IssueKey,$FetchValues,$ValueContains)
            @([pscustomobject]@{ Key='k'; Value='https://property.only'; Length=20 })
        } | Out-Null

        $matches = Find-FinOpsJiraIssueUrls -IssueKey 'XYZ-1' -UseAtlassianMcp -IncludeProperties
        ($matches | Where-Object Match -eq 'https://property.only' | Measure-Object).Count | Should -Be 1
    }

    It 'Find-FinOpsJiraIssueUrls matches URLs from rendered fields only via MCP' {
        Register-FinOpsAtlassianMcpProvider -GetIssueScript {
            param($IssueKey,$Expand)
            $result = @{ 
                key = $IssueKey
                fields = @{}
            }
            # Only add renderedFields if requested in Expand
            if ($Expand -contains 'renderedFields') {
                $result.renderedFields = @{ description = '<a href="https://rendered.only">link</a>' }
            }
            $result
        } | Out-Null

        $matches = Find-FinOpsJiraIssueUrls -IssueKey 'XYZ-2' -UseAtlassianMcp -IncludeRenderedFields
        ($matches | Where-Object Match -eq 'https://rendered.only' | Measure-Object).Count | Should -Be 1
    }
}
