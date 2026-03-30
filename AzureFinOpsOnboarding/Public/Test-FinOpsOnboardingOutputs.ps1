function Test-FinOpsOnboardingOutputs {
    <#
    .SYNOPSIS
        Validates onboarding outputs and integration points.
    
    .DESCRIPTION
        Performs smoke tests on artifacts and integrations created during onboarding:
        - Verifies report files exist at reported paths
        - Tests Power BI workspace accessibility
        - Tests Teams webhook delivery
        - Validates Jira comment/transition success
        
        Returns detailed validation results per category with pass/fail status.
    
    .PARAMETER OnboardingResult
        Orchestrator result object from Invoke-FinOpsOnboarding.
    
    .PARAMETER ValidatePowerBI
        Test Power BI workspace accessibility using Get-FinOpsPowerBIWorkspace.
    
    .PARAMETER ValidateTeams
        Test Teams webhook delivery using Send-FinOpsTeamsNotification.
    
    .PARAMETER ValidateJira
        Verify Jira comment/transition succeeded using Get-FinOpsJiraIssue.
    
    .EXAMPLE
        $result = Invoke-FinOpsOnboarding -TenantId $tid -CustomerName "Contoso" ...
        Test-FinOpsOnboardingOutputs -OnboardingResult $result
    
    .EXAMPLE
        Test-FinOpsOnboardingOutputs -OnboardingResult $result `
            -ValidatePowerBI `
            -ValidateTeams `
            -ValidateJira
    
    .OUTPUTS
        PSCustomObject with validation results per category including pass/fail status.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [PSCustomObject]$OnboardingResult,
        
        [Parameter()]
        [switch]$ValidatePowerBI,
        
        [Parameter()]
        [switch]$ValidateTeams,
        
        [Parameter()]
        [switch]$ValidateJira
    )
    
    try {
        Write-Verbose "=== Starting Output Validation ==="
        
        $validationResults = [PSCustomObject]@{
            Timestamp       = Get-Date
            CustomerName    = $OnboardingResult.CustomerName
            OverallStatus   = 'Unknown'
            Categories      = @()
            PassedChecks    = 0
            FailedChecks    = 0
            SkippedChecks   = 0
        }
        
        # Category 1: File outputs (reports/manifests)
        Write-Verbose "Validating file outputs..."
        
        $fileValidation = [PSCustomObject]@{
            Category = 'FileOutputs'
            Status   = 'Pass'
            Checks   = @()
            Message  = ''
        }
        
        # Check JSON report
        if ($OnboardingResult.ReportPath) {
            $jsonExists = Test-Path $OnboardingResult.ReportPath
            $fileValidation.Checks += [PSCustomObject]@{
                Name   = 'JSONReport'
                Path   = $OnboardingResult.ReportPath
                Exists = $jsonExists
                Status = if ($jsonExists) { 'Pass' } else { 'Fail' }
            }
            
            if ($jsonExists) {
                $validationResults.PassedChecks++
            } else {
                $validationResults.FailedChecks++
                $fileValidation.Status = 'Fail'
            }
        } else {
            $validationResults.SkippedChecks++
        }
        
        # Check Markdown report
        if ($OnboardingResult.MarkdownReportPath) {
            $mdExists = Test-Path $OnboardingResult.MarkdownReportPath
            $fileValidation.Checks += [PSCustomObject]@{
                Name   = 'MarkdownReport'
                Path   = $OnboardingResult.MarkdownReportPath
                Exists = $mdExists
                Status = if ($mdExists) { 'Pass' } else { 'Fail' }
            }
            
            if ($mdExists) {
                $validationResults.PassedChecks++
            } else {
                $validationResults.FailedChecks++
                $fileValidation.Status = 'Fail'
            }
        } else {
            $validationResults.SkippedChecks++
        }
        
        $fileValidation.Message = if ($fileValidation.Status -eq 'Pass') {
            "All report files exist at expected locations"
        } else {
            "One or more report files are missing"
        }
        
        $validationResults.Categories += $fileValidation
        
        # Category 2: Power BI workspace (if requested)
        if ($ValidatePowerBI) {
            Write-Verbose "Validating Power BI workspace..."
            
            $pbiValidation = [PSCustomObject]@{
                Category = 'PowerBI'
                Status   = 'Unknown'
                Checks   = @()
                Message  = ''
            }
            
            try {
                if ($OnboardingResult.PowerBIWorkspaceId) {
                    $workspace = Get-FinOpsPowerBIWorkspace -WorkspaceId $OnboardingResult.PowerBIWorkspaceId -ErrorAction Stop
                    
                    if ($workspace) {
                        $pbiValidation.Status = 'Pass'
                        $pbiValidation.Message = "Power BI workspace accessible: $($workspace.Name)"
                        $pbiValidation.Checks += [PSCustomObject]@{
                            Name        = 'WorkspaceAccess'
                            WorkspaceId = $OnboardingResult.PowerBIWorkspaceId
                            Status      = 'Pass'
                            Details     = "Workspace: $($workspace.Name)"
                        }
                        $validationResults.PassedChecks++
                    } else {
                        $pbiValidation.Status = 'Fail'
                        $pbiValidation.Message = "Power BI workspace not found"
                        $validationResults.FailedChecks++
                    }
                } else {
                    $pbiValidation.Status = 'Skipped'
                    $pbiValidation.Message = "No Power BI workspace ID in onboarding result"
                    $validationResults.SkippedChecks++
                }
            } catch {
                $pbiValidation.Status = 'Fail'
                $pbiValidation.Message = "Failed to access Power BI workspace: $_"
                $pbiValidation.Checks += [PSCustomObject]@{
                    Name   = 'WorkspaceAccess'
                    Status = 'Fail'
                    Error  = $_.Exception.Message
                }
                $validationResults.FailedChecks++
                Write-Warning "Power BI validation failed: $_"
            }
            
            $validationResults.Categories += $pbiValidation
        }
        
        # Category 3: Teams webhook (if requested)
        if ($ValidateTeams) {
            Write-Verbose "Validating Teams webhook..."
            
            $teamsValidation = [PSCustomObject]@{
                Category = 'Teams'
                Status   = 'Unknown'
                Checks   = @()
                Message  = ''
            }
            
            try {
                if ($OnboardingResult.TeamsWebhookUrl) {
                    # Send test notification
                    $testResult = Send-FinOpsTeamsNotification `
                        -WebhookUrl $OnboardingResult.TeamsWebhookUrl `
                        -Title "FinOps Output Validation" `
                        -Message "Test notification from Test-FinOpsOnboardingOutputs for customer: $($OnboardingResult.CustomerName)" `
                        -ErrorAction Stop
                    
                    $teamsValidation.Status = 'Pass'
                    $teamsValidation.Message = "Teams webhook delivered successfully"
                    $teamsValidation.Checks += [PSCustomObject]@{
                        Name    = 'WebhookDelivery'
                        Status  = 'Pass'
                        Details = 'Test card delivered'
                    }
                    $validationResults.PassedChecks++
                } else {
                    $teamsValidation.Status = 'Skipped'
                    $teamsValidation.Message = "No Teams webhook URL in onboarding result"
                    $validationResults.SkippedChecks++
                }
            } catch {
                $teamsValidation.Status = 'Fail'
                $teamsValidation.Message = "Failed to deliver Teams notification: $_"
                $teamsValidation.Checks += [PSCustomObject]@{
                    Name   = 'WebhookDelivery'
                    Status = 'Fail'
                    Error  = $_.Exception.Message
                }
                $validationResults.FailedChecks++
                Write-Warning "Teams validation failed: $_"
            }
            
            $validationResults.Categories += $teamsValidation
        }
        
        # Category 4: Jira integration (if requested)
        if ($ValidateJira) {
            Write-Verbose "Validating Jira integration..."
            
            $jiraValidation = [PSCustomObject]@{
                Category = 'Jira'
                Status   = 'Unknown'
                Checks   = @()
                Message  = ''
            }
            
            try {
                if ($OnboardingResult.JiraIssueKey -and $OnboardingResult.JiraBaseUrl -and $OnboardingResult.JiraUsername -and $OnboardingResult.JiraApiToken) {
                    # Get issue to verify comment/transition
                    $issue = Get-FinOpsJiraIssue `
                        -BaseUrl $OnboardingResult.JiraBaseUrl `
                        -IssueKey $OnboardingResult.JiraIssueKey `
                        -Username $OnboardingResult.JiraUsername `
                        -ApiToken $OnboardingResult.JiraApiToken `
                        -ErrorAction Stop
                    
                    if ($issue) {
                        $jiraValidation.Status = 'Pass'
                        $jiraValidation.Message = "Jira issue accessible: $($OnboardingResult.JiraIssueKey)"
                        $jiraValidation.Checks += [PSCustomObject]@{
                            Name     = 'IssueAccess'
                            IssueKey = $OnboardingResult.JiraIssueKey
                            Status   = 'Pass'
                            Details  = "Issue status: $($issue.fields.status.name)"
                        }
                        $validationResults.PassedChecks++
                        
                        # Check if expected transition occurred
                        if ($OnboardingResult.JiraTransitionStatus) {
                            if ($issue.fields.status.name -eq $OnboardingResult.JiraTransitionStatus) {
                                $jiraValidation.Checks += [PSCustomObject]@{
                                    Name     = 'TransitionStatus'
                                    Status   = 'Pass'
                                    Expected = $OnboardingResult.JiraTransitionStatus
                                    Actual   = $issue.fields.status.name
                                }
                                $validationResults.PassedChecks++
                            } else {
                                $jiraValidation.Checks += [PSCustomObject]@{
                                    Name     = 'TransitionStatus'
                                    Status   = 'Warning'
                                    Expected = $OnboardingResult.JiraTransitionStatus
                                    Actual   = $issue.fields.status.name
                                    Message  = "Status does not match expected transition"
                                }
                                $validationResults.FailedChecks++
                                Write-Warning "Jira issue status mismatch: expected '$($OnboardingResult.JiraTransitionStatus)', got '$($issue.fields.status.name)'"
                            }
                        }
                    } else {
                        $jiraValidation.Status = 'Fail'
                        $jiraValidation.Message = "Jira issue not found or inaccessible"
                        $validationResults.FailedChecks++
                    }
                } else {
                    $jiraValidation.Status = 'Skipped'
                    $jiraValidation.Message = "Incomplete Jira information in onboarding result"
                    $validationResults.SkippedChecks++
                }
            } catch {
                $jiraValidation.Status = 'Fail'
                $jiraValidation.Message = "Failed to validate Jira integration: $_"
                $jiraValidation.Checks += [PSCustomObject]@{
                    Name   = 'IssueAccess'
                    Status = 'Fail'
                    Error  = $_.Exception.Message
                }
                $validationResults.FailedChecks++
                Write-Warning "Jira validation failed: $_"
            }
            
            $validationResults.Categories += $jiraValidation
        }
        
        # Determine overall status
        if ($validationResults.FailedChecks -eq 0 -and $validationResults.PassedChecks -gt 0) {
            $validationResults.OverallStatus = 'Pass'
        } elseif ($validationResults.FailedChecks -gt 0) {
            $validationResults.OverallStatus = 'Fail'
        } elseif ($validationResults.SkippedChecks -gt 0 -and $validationResults.PassedChecks -eq 0) {
            $validationResults.OverallStatus = 'Skipped'
        } else {
            $validationResults.OverallStatus = 'Unknown'
        }
        
        # Display summary
        Write-Host "`n=== Output Validation Complete ===" -ForegroundColor $(if($validationResults.OverallStatus -eq 'Pass'){'Green'}elseif($validationResults.OverallStatus -eq 'Fail'){'Red'}else{'Yellow'})
        Write-Host "Customer: " -NoNewline
        Write-Host $validationResults.CustomerName -ForegroundColor Cyan
        Write-Host "Overall Status: " -NoNewline
        Write-Host $validationResults.OverallStatus -ForegroundColor $(if($validationResults.OverallStatus -eq 'Pass'){'Green'}elseif($validationResults.OverallStatus -eq 'Fail'){'Red'}else{'Yellow'})
        Write-Host "Passed: " -NoNewline
        Write-Host $validationResults.PassedChecks -ForegroundColor Green
        Write-Host "Failed: " -NoNewline
        Write-Host $validationResults.FailedChecks -ForegroundColor Red
        Write-Host "Skipped: " -NoNewline
        Write-Host $validationResults.SkippedChecks -ForegroundColor Gray
        
        Write-Host "`nCategory Results:" -ForegroundColor Cyan
        foreach ($category in $validationResults.Categories) {
            $statusColor = switch ($category.Status) {
                'Pass' { 'Green' }
                'Fail' { 'Red' }
                'Warning' { 'Yellow' }
                default { 'Gray' }
            }
            Write-Host "  $($category.Category): " -NoNewline
            Write-Host $category.Status -ForegroundColor $statusColor
            Write-Host "    $($category.Message)" -ForegroundColor Gray
        }
        
        return $validationResults
        
    } catch {
        Write-Error "Failed to validate onboarding outputs: $_"
        throw
    }
}
