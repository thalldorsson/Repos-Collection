function Get-FinOpsJiraIssueSafe {
    <#
    .SYNOPSIS
        Safe wrapper to fetch a Jira issue after checking visibility and optionally map to onboarding object.

    .DESCRIPTION
        Runs Test-FinOpsJiraIssueVisibility first to classify 404/permission errors. On success, fetches the raw
        issue with Get-FinOpsJiraIssue. If -MapToOnboarding is specified, returns the output of
        Get-FinOpsOnboardingFromJiraIssue instead (same params forwarded).
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$BaseUrl,
        [Parameter(Mandatory)][string]$IssueKey,
        [Parameter(Mandatory)][ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')][string]$Username,
        [Parameter(Mandatory)][SecureString]$ApiToken,
        [switch]$MapToOnboarding
    )

    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = $script:AfoDefaultJiraBaseUrl }

    try {
        $vis = Test-FinOpsJiraIssueVisibility -BaseUrl $BaseUrl -IssueKey $IssueKey -Username $Username -ApiToken $ApiToken -ErrorAction Stop
    } catch {
        Write-Verbose "Visibility probe threw an exception: $($_.Exception.Message)"
        return @{ Success = $false; Error = $_.Exception.Message }
    }

    if (-not $vis.Success) {
        Write-Verbose "Issue visibility check failed: $($vis | ConvertTo-Json -Compress)"
        return $vis
    }

    if ($MapToOnboarding) {
        return Get-FinOpsOnboardingFromJiraIssue -BaseUrl $BaseUrl -IssueKey $IssueKey -Username $Username -ApiToken $ApiToken
    }

    return Get-FinOpsJiraIssue -BaseUrl $BaseUrl -IssueKey $IssueKey -Username $Username -ApiToken $ApiToken
}
