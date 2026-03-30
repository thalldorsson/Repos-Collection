function Test-FinOpsJiraIssueVisibility {
    <#
    .SYNOPSIS
        Diagnoses accessibility of a Jira issue key (exists, permission issue, invalid, or unknown).

    .DESCRIPTION
        Performs two probes:
          1. JQL search: key = <IssueKey>
          2. Direct issue GET
        Parses enhanced error messages emitted by internal Invoke-FinOpsJiraGet (HTTP status + Jira error messages) and
        returns a classification object. Helps quickly understand 404 vs 400 vs permission vs invalid key scenarios.

    .PARAMETER BaseUrl
        Jira base URL (defaults to module default https://crayon-group.atlassian.net; override with env var FINOPS_JIRA_BASEURL) without trailing slash.

    .PARAMETER IssueKey
        Jira issue key to test (e.g. CGGS-714).

    .PARAMETER Username
        Jira account email.

    .PARAMETER ApiToken
        Jira API token (SecureString).

    .PARAMETER AuthorizationHeader
        Optional pre-built Authorization header.

    .OUTPUTS
    PSCustomObject with: Key, SearchResultCount, SearchStatusCode, IssueFetchStatusCode, Classification, Notes, RawSearchError, RawIssueError, ParsedSearchMessages, ParsedIssueMessages, ProjectKey, ProjectVisibilityCheck

    .EXAMPLE
        Test-FinOpsJiraIssueVisibility -BaseUrl https://example.atlassian.net -IssueKey ABC-123 -Username you@org.com -ApiToken $apiToken

    .NOTES
                Classification logic (expanded):
                    * ExistsAndAccessible              : Search count > 0 & issue GET 200
                    * ExistsButForbidden               : Search count > 0 & issue GET 401/403
                    * NotFoundOrNoPermission           : Search count = 0 & issue GET 404
                    * Inconsistent404                  : Search count > 0 & issue GET 404
                    * PossiblyInvalidKey               : issue GET 400 (rare on GET) OR key fails basic pattern
                    * SearchError400_Issue404_ProjectOrPermission : Search 400 & issue 404 & project key visible (or unknown) -> strong permission/project scheme suspicion
                    * ProjectNotVisibleOrInvalid       : Search 400 & issue 404 & project key NOT in accessible project list
                    * Unknown                          : Fallback
                Heuristic uses Get-FinOpsJiraProjects (first page) unless -SkipProjectHeuristic specified.
    #>
    [CmdletBinding()] param(
        [string]$BaseUrl,
        [Parameter(Mandatory)][string]$IssueKey,
        [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')][string]$Username,
        [SecureString]$ApiToken,
        [string]$AuthorizationHeader,
        [switch]$SkipProjectHeuristic,
        [switch]$UseAtlassianMcp
    )

    if (-not $UseAtlassianMcp -and [string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = $script:FinOpsDefaultJiraBaseUrl }

    $searchCount = $null
    $searchStatus = $null
    $issueStatus = $null
    $rawSearchErr = $null
    $rawIssueErr = $null
    $parsedSearchMessages = $null
    $parsedIssueMessages = $null
    $projectKey = $null
    $projectVisible = $null

    # Extract project key prefix (before hyphen)
    if ($IssueKey -match '^([A-Z][A-Z0-9]+)-\d+$') { $projectKey = $Matches[1] }

    # Probe 1: JQL search
    try {
        if ($UseAtlassianMcp) {
            $keys = Invoke-FinOpsJiraMcp -Operation Search -Arguments @{ Jql = "key = $IssueKey" }
            $searchCount = ($keys | Where-Object { $_ -eq $IssueKey } | Measure-Object).Count
        } else {
            $res = Get-FinOpsJiraSearch -BaseUrl $BaseUrl -Jql "key = $IssueKey" -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader -Raw
            $searchCount = ($res.issues | Measure-Object).Count
        }
    } catch {
        $rawSearchErr = $_.Exception.Message
        if ($rawSearchErr -match 'HTTP\s+(\d{3})') { $searchStatus = [int]$Matches[1] }
        # Attempt parse for structured messages
        if ($rawSearchErr -match 'Errors?:') { $parsedSearchMessages = ($rawSearchErr -replace '^.*?(Errors?:)', '${1}') }
    }

    # Probe 2: Direct issue GET
    try {
        if ($UseAtlassianMcp) {
            $issue = Invoke-FinOpsJiraMcp -Operation GetIssue -Arguments @{ IssueKey = $IssueKey }
            if ($issue) { $issueStatus = 200 } else { $issueStatus = $null }
        } else {
            $issue = Get-FinOpsJiraIssue -BaseUrl $BaseUrl -IssueKey $IssueKey -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader
            $issueStatus = 200
            # Touch a property to silence unused variable analyzers without extra output
            $null = $issue.id
        }
    } catch {
        $rawIssueErr = $_.Exception.Message
        if ($rawIssueErr -match 'HTTP\s+(\d{3})') { $issueStatus = [int]$Matches[1] }
        if ($rawIssueErr -match 'Errors?:') { $parsedIssueMessages = ($rawIssueErr -replace '^.*?(Errors?:)', '${1}') }
    }

    # Classification
    $classification = 'Unknown'
    $notes = @()
    if ($searchCount -gt 0 -and $issueStatus -eq 200) {
        $classification = 'ExistsAndAccessible'
    } elseif ($searchCount -gt 0 -and $issueStatus -in 401, 403) {
        $classification = 'ExistsButForbidden'
        $notes += 'You appear to locate the key via search but cannot fetch issue (permission).'
    } elseif ($searchCount -eq 0 -and $issueStatus -eq 404) {
        $classification = 'NotFoundOrNoPermission'
        $notes += 'Could be non-existent key OR no Browse permission; verify in UI.'
    } elseif ($issueStatus -eq 404 -and $searchCount -gt 0) {
        $classification = 'Inconsistent404'
        $notes += 'Search found issue but direct fetch 404: possible permission screen scheme nuance.'
    } elseif ($issueStatus -eq 400) {
        $classification = 'PossiblyInvalidKey'
        $notes += '400 on direct fetch—rare for existing keys; check key pattern or base URL.'
    } elseif ($searchStatus -eq 400 -and $issueStatus -eq 404) {
        # Run project heuristic if possible
        if ($projectKey -and -not $SkipProjectHeuristic) {
            try {
                $projSample = if ($UseAtlassianMcp) { Get-FinOpsJiraProjects -UseAtlassianMcp } else { Get-FinOpsJiraProjects -BaseUrl $BaseUrl -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader -Max 500 }
                if ($projSample) {
                    $projectVisible = ($projSample | Where-Object Key -eq $projectKey | Measure-Object).Count -gt 0
                }
            } catch {
                $notes += 'Project heuristic failed: ' + $_.Exception.Message
            }
        }
        if ($projectKey -and $projectVisible -eq $false) {
            $classification = 'ProjectNotVisibleOrInvalid'
            $notes += "Project key '$projectKey' not in visible list; either typo or permission (Browse Project)."
        } else {
            $classification = 'SearchError400_Issue404_ProjectOrPermission'
            $notes += 'Search 400 + Issue 404 suggests project visibility or permission scheme issue.'
        }
    }

    if ($null -eq $searchCount) { $searchCount = 0 }
    [pscustomobject]@{
        Key = $IssueKey
        SearchResultCount = $searchCount
        SearchStatusCode = $searchStatus
        IssueFetchStatusCode = $issueStatus
        Classification = $classification
        Notes = ($notes -join ' ')
        RawSearchError = $rawSearchErr
        RawIssueError = $rawIssueErr
        ParsedSearchMessages = $parsedSearchMessages
        ParsedIssueMessages = $parsedIssueMessages
        ProjectKey = $projectKey
        ProjectVisibilityCheck = if ($null -eq $projectVisible) { $null } else { if ($projectVisible) { 'Visible' } else { 'NotVisible' } }
    }
}
