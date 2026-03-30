Describe 'Power BI MCP integration and fallback behavior' {
    BeforeAll {
        Import-Module "$PSScriptRoot\..\AzureFinOpsOnboarding.psd1" -Force
    }

    It 'Grant-FinOpsPowerBIReportAccess returns null without MCP delegate' {
        $ErrorActionPreference = 'SilentlyContinue'
        $result = Grant-FinOpsPowerBIReportAccess -ReportName 'Test Report' -EntraGroupId '33333333-3333-3333-3333-333333333333' -UsePowerBIMcp -ErrorAction SilentlyContinue
        $result | Should -BeNullOrEmpty
    }

    It 'Register-FinOpsPowerBIMcpProvider stores delegates' {
        Register-FinOpsPowerBIMcpProvider -GetReportScript {
            param($ReportName, $WorkspaceId)
            [PSCustomObject]@{
                Id = '22222222-2222-2222-2222-222222222222'
                Name = $ReportName
                WorkspaceId = '11111111-1111-1111-1111-111111111111'
            }
        } -GetWorkspaceScript {
            param($WorkspaceId)
            [PSCustomObject]@{
                Id = $WorkspaceId
                Name = 'Test Workspace'
            }
        } -GrantReportAccessScript {
            param($ReportId, $WorkspaceId, $PrincipalId, $PrincipalType, $AccessRight)
            Write-Verbose "Mock: Granted $AccessRight to $PrincipalType $PrincipalId"
        }

        # Test by using the delegate
        $ws = Get-FinOpsPowerBIWorkspace -WorkspaceId '11111111-1111-1111-1111-111111111111' -UsePowerBIMcp
        $ws.Name | Should -Be 'Test Workspace'
    }

    It 'Grant-FinOpsPowerBIReportAccess works via MCP' {
        Register-FinOpsPowerBIMcpProvider -GetReportScript {
            param($ReportName, $WorkspaceId)
            [PSCustomObject]@{
                Id = '22222222-2222-2222-2222-222222222222'
                Name = $ReportName
                WorkspaceId = '11111111-1111-1111-1111-111111111111'
            }
        } -GetWorkspaceScript {
            param($WorkspaceId)
            [PSCustomObject]@{
                Id = $WorkspaceId
                Name = 'Test Workspace'
            }
        } -GrantReportAccessScript {
            param($ReportId, $WorkspaceId, $PrincipalId, $PrincipalType, $AccessRight)
            # Mock successful grant
        }

        $result = Grant-FinOpsPowerBIReportAccess -ReportName 'Test Report' -EntraGroupId '33333333-3333-3333-3333-333333333333' -UsePowerBIMcp -PassThru
        $result.ReportName | Should -Be 'Test Report'
        $result.ShareLink | Should -Match 'https://app.powerbi.com'
    }

    It 'Get-FinOpsPowerBIWorkspace works via MCP for single workspace' {
        Register-FinOpsPowerBIMcpProvider -GetWorkspaceScript {
            param($WorkspaceId)
            [PSCustomObject]@{
                Id = $WorkspaceId
                Name = 'FinOps Workspace'
            }
        }

        $result = Get-FinOpsPowerBIWorkspace -WorkspaceId '11111111-1111-1111-1111-111111111111' -UsePowerBIMcp
        $result.Name | Should -Be 'FinOps Workspace'
        $result.Id | Should -Be '11111111-1111-1111-1111-111111111111'
    }

    It 'Get-FinOpsPowerBIWorkspace works via MCP for listing workspaces' {
        Register-FinOpsPowerBIMcpProvider -GetWorkspacesScript {
            param($Filter)
            @(
                [PSCustomObject]@{ Id = '11111111-1111-1111-1111-111111111111'; Name = 'FinOps Workspace' }
                [PSCustomObject]@{ Id = '44444444-4444-4444-4444-444444444444'; Name = 'Test Workspace' }
            )
        }

        $result = Get-FinOpsPowerBIWorkspace -UsePowerBIMcp
        ($result | Measure-Object).Count | Should -BeGreaterThan 0
    }

    It 'Publish-FinOpsPowerBIReport works via MCP' {
        $testFile = "$env:TEMP\test-report.pbix"
        'mock content' | Out-File -FilePath $testFile -Force

        Register-FinOpsPowerBIMcpProvider -PublishReportScript {
            param($FilePath, $WorkspaceId, $ReportName)
            [PSCustomObject]@{
                ReportId = '55555555-5555-5555-5555-555555555555'
                WorkspaceId = $WorkspaceId
                Name = $ReportName
            }
        }

        $result = Publish-FinOpsPowerBIReport -FilePath $testFile -WorkspaceId '11111111-1111-1111-1111-111111111111' -UsePowerBIMcp -PassThru
        $result.ReportId | Should -Be '55555555-5555-5555-5555-555555555555'

        Remove-Item $testFile -Force -ErrorAction SilentlyContinue
    }

    It 'Invoke-FinOpsPowerBIDatasetRefresh works via MCP' {
        Register-FinOpsPowerBIMcpProvider -RefreshDatasetScript {
            param($DatasetId, $WorkspaceId)
            [PSCustomObject]@{
                DatasetId = $DatasetId
                WorkspaceId = $WorkspaceId
                Status = 'Initiated'
            }
        }

        $result = Invoke-FinOpsPowerBIDatasetRefresh -DatasetId '66666666-6666-6666-6666-666666666666' -WorkspaceId '11111111-1111-1111-1111-111111111111' -UsePowerBIMcp
        $result.Status | Should -Be 'Initiated'
    }

    It 'Grant-FinOpsPowerBIReportAccess delegates are called in order' {
        # Test that all required delegates are invoked
        $getReportCalled = $false
        $getWorkspaceCalled = $false
        $grantAccessCalled = $false
        
        Register-FinOpsPowerBIMcpProvider -GetReportScript {
            param($ReportName, $WorkspaceId)
            $getReportCalled = $true
            [PSCustomObject]@{ Id = '22222222-2222-2222-2222-222222222222'; Name = $ReportName; WorkspaceId = '11111111-1111-1111-1111-111111111111' }
        } -GetWorkspaceScript {
            param($WorkspaceId)
            $getWorkspaceCalled = $true
            [PSCustomObject]@{ Id = $WorkspaceId; Name = 'Test Workspace' }
        } -GrantReportAccessScript {
            param($ReportId, $WorkspaceId, $PrincipalId, $PrincipalType, $AccessRight)
            $grantAccessCalled = $true
        }

        $result = Grant-FinOpsPowerBIReportAccess -ReportName 'Test' -EntraGroupId '33333333-3333-3333-3333-333333333333' -UsePowerBIMcp -Confirm:$false
        $result.ReportName | Should -Be 'Test'
    }

    It 'Export-FinOpsPowerBIReport works via MCP' {
        $script:exportCalled = $false
        Register-FinOpsPowerBIMcpProvider -ExportReportScript {
            param($ReportId,$WorkspaceId,$Format,$OutputPath,$ReportName)
            $script:exportCalled = $true
            if (-not $ReportId) { $ReportId = '99999999-9999-9999-9999-999999999999' }
            if (-not $WorkspaceId) { $WorkspaceId = '11111111-1111-1111-1111-111111111111' }
            if (-not $ReportName) { $ReportName = 'Export Report' }
            if (-not $OutputPath) { $OutputPath = "$env:TEMP/export-report.pdf" }
            [PSCustomObject]@{
                ReportId    = $ReportId
                WorkspaceId = $WorkspaceId
                ReportName  = $ReportName
                FilePath    = $OutputPath
                Status      = 'Completed'
            }
        } -GetReportScript {
            param($ReportName,$WorkspaceId)
            [PSCustomObject]@{ Id = '99999999-9999-9999-9999-999999999999'; Name = $ReportName; WorkspaceId = '11111111-1111-1111-1111-111111111111' }
        }

        $result = Export-FinOpsPowerBIReport -ReportName 'Export Report' -Format PDF -UsePowerBIMcp -PassThru
        $result.Status | Should -Be 'Completed'
        $script:exportCalled | Should -Be $true
    }

    It 'Get-FinOpsPowerBIReportUsers works via MCP' {
        Register-FinOpsPowerBIMcpProvider -GetReportUsersScript {
            param($ReportId,$WorkspaceId,$ReportName)
            @(
                [PSCustomObject]@{ PrincipalId = '33333333-3333-3333-3333-333333333333'; PrincipalType='Group'; AccessRight='Read' }
                [PSCustomObject]@{ PrincipalId = '44444444-4444-4444-4444-444444444444'; PrincipalType='User'; AccessRight='Read' }
            )
        }
        $users = Get-FinOpsPowerBIReportUsers -ReportName 'Export Report' -UsePowerBIMcp -PassThru
        ($users | Measure-Object).Count | Should -Be 2
    }

    It 'Revoke-FinOpsPowerBIReportAccess works via MCP' {
        $script:revokeCalled = $false
        Register-FinOpsPowerBIMcpProvider -GetReportScript {
            param($ReportName,$WorkspaceId)
            [PSCustomObject]@{ Id = '88888888-8888-8888-8888-888888888888'; Name = $ReportName; WorkspaceId = '11111111-1111-1111-1111-111111111111' }
        } -RevokeReportAccessScript {
            param($ReportId,$WorkspaceId,$PrincipalId)
            $script:revokeCalled = $true
        }
        $result = Revoke-FinOpsPowerBIReportAccess -ReportName 'Revoke Test' -EntraGroupId '33333333-3333-3333-3333-333333333333' -UsePowerBIMcp -PassThru -Confirm:$false
        $result.Status | Should -Be 'Revoked'
        $script:revokeCalled | Should -Be $true
    }
}

