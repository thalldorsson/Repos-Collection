Describe 'Power BI direct export configuration behavior' {
    BeforeAll {
        Import-Module "$PSScriptRoot\..\AzureFinOpsOnboarding.psd1" -Force
    }

    It 'Builds export body with pages, hidden pages, filter and locale without MCP' {
        # Mock modules and REST methods to avoid real network/module operations
        Mock Install-Module { }
        Mock Import-Module { }
        Mock Get-PowerBIAccessToken { 'token' }
        Mock Connect-PowerBIServiceAccount { }
        Mock Get-PowerBIReport { [PSCustomObject]@{ Id = 'rep-111'; Name='Test Export'} }
        Mock Invoke-PowerBIRestMethod {
            param($Url,$Method,$Body,$ContentType)
            if ($Method -eq 'Get' -and $Url -like 'admin/groups*') {
                return '{"value":[{"id":"ws-123","reports":[{"id":"rep-111"}]}]}'
            }
            if ($Method -eq 'Post' -and $Url -like '*ExportTo') {
                $script:captureBody = $Body
                return '{"id":"job-999"}'
            }
            if ($Method -eq 'Get' -and $Url -like '*exports*') {
                return '{"status":"Succeeded","percentComplete":100,"resourceLocation":"https://download/export.pdf"}'
            }
        }
        Mock Invoke-WebRequest { param($Uri,$OutFile) 'dummy' | Out-File -FilePath $OutFile }

        $tempOut = Join-Path $env:TEMP 'test-export.pdf'
        $result = Export-FinOpsPowerBIReport -ReportName 'Test Export' -Format PDF -Pages 'Page1','Page2' -IncludeHiddenPages -ReportFilter "[Table].[Column] = 'X'" -Locale 'en-US' -Wait -OutputPath $tempOut -PassThru
        $result.Status | Should Be 'Completed'
        $script:captureBody | Should Match '"pages"'
        $script:captureBody | Should Match '"includeHiddenPages"'
        $script:captureBody | Should Match '"reportLevelFilters"'
        $script:captureBody | Should Match '"locale"'
        Remove-Item $tempOut -Force -ErrorAction SilentlyContinue
    }
}
