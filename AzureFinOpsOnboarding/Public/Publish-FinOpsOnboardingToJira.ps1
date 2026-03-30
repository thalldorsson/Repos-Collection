function Publish-FinOpsOnboardingToJira {
    <#
    .SYNOPSIS
        Posts onboarding results to Jira issue as comment and optionally transitions status.

    .DESCRIPTION
        Takes the orchestrator object from Invoke-FinOpsOnboarding and publishes a summary
        comment to the associated Jira issue. Optionally transitions the issue to a final status.

    .PARAMETER OrchestratorObject
        PSCustomObject from Invoke-FinOpsOnboarding containing check results and customer info.

    .PARAMETER IssueKey
        Jira issue key (e.g. CGGS-714).

    .PARAMETER BaseUrl
        Jira base URL (e.g. https://crayon-group.atlassian.net) without trailing slash.

    .PARAMETER Username
        Jira account email used with API token for Basic Auth.

    .PARAMETER ApiToken
        Jira API token as SecureString.

    .PARAMETER AuthorizationHeader
        Optional pre-built Authorization header (overrides Username/ApiToken).

    .PARAMETER TransitionToStatus
        Optional target status for issue transition (e.g. 'Done', 'In Review').
        If not specified, only comment is posted.

    .PARAMETER UseAtlassianMcp
        Switch to use Atlassian Rovo MCP Server delegates for operations.

    .EXAMPLE
        $apiToken = Read-Host 'Token' -AsSecureString
        $result = Invoke-FinOpsOnboarding -TenantId $tid -ApplicationId $appId -ClientSecret $secret -CustomerName "Contoso" -PrimaryDomain "contoso.com" -PassThru
        Publish-FinOpsOnboardingToJira -OrchestratorObject $result -IssueKey CGGS-714 -BaseUrl https://crayon-group.atlassian.net -Username you@company.com -ApiToken $apiToken -TransitionToStatus "Done"

    .NOTES
        Combines comment posting and optional status transition in a single logical operation.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)][PSCustomObject]$OrchestratorObject,
        [Parameter(Mandatory)][string]$IssueKey,
        [Parameter()][string]$BaseUrl,
        [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')][string]$Username,
        [SecureString]$ApiToken,
        [string]$AuthorizationHeader,
        [string]$TransitionToStatus,
        [switch]$UseAtlassianMcp
    )
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = $script:FinOpsDefaultJiraBaseUrl }
    
    if (-not $UseAtlassianMcp -and -not $Username -and -not $AuthorizationHeader) {
        throw "Username (or AuthorizationHeader) is required when not using Atlassian MCP."
    }
    
    # Build summary comment
    $passedChecks = ($OrchestratorObject.Checks | Where-Object { $_.Success }).Count
    $totalChecks = $OrchestratorObject.Checks.Count
    $allPassed = $passedChecks -eq $totalChecks
    
    $checkSummary = $OrchestratorObject.Checks | ForEach-Object {
        $status = if ($_.Success) { '✅' } else { '❌' }
        "$status $($_.Name): $($_.ErrorDetail)"
    } | Join-String -Separator "`n"
    
    $commentText = @"
Onboarding completed for customer: $($OrchestratorObject.Customer.Name)

**Summary:**
- Tenant ID: $($OrchestratorObject.Customer.TenantId)
- Primary Domain: $($OrchestratorObject.Customer.PrimaryDomain)
- Checks Passed: $passedChecks/$totalChecks
- Status: $(if ($allPassed) { 'SUCCESS ✅' } else { 'PARTIAL ⚠️' })

**Check Results:**
$checkSummary

Generated: $($OrchestratorObject.GeneratedAt)
"@

    Write-Verbose "Publishing onboarding results to Jira issue: $IssueKey"
    
    # Post comment
    Add-FinOpsJiraComment -BaseUrl $BaseUrl -IssueKey $IssueKey -Comment $commentText -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader -UseAtlassianMcp:$UseAtlassianMcp | Out-Null
    Write-Verbose "Comment posted to $IssueKey"
    
    # Optionally transition issue
    if ($TransitionToStatus) {
        Write-Verbose "Transitioning $IssueKey to status: $TransitionToStatus"
        Update-FinOpsJiraIssueStatus -BaseUrl $BaseUrl -IssueKey $IssueKey -TargetStatus $TransitionToStatus -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader -UseAtlassianMcp:$UseAtlassianMcp | Out-Null
        Write-Verbose "Issue transitioned successfully"
    }
    
    Write-Output "Onboarding results published to Jira issue $IssueKey"
}
