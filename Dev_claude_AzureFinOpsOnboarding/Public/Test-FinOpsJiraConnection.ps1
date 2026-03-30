function Test-FinOpsJiraConnection {
    <#
    .SYNOPSIS
        Quick authentication & environment sanity test for Jira credentials and base URL.

    .DESCRIPTION
        Performs lightweight calls to verify:
          * Authentication (/rest/api/3/myself)
          * Project visibility (/rest/api/3/project/search first page)
          * Field list (optional, can be skipped with -SkipFields)
        Outputs a consolidated object so you can rapidly see if credentials are valid and what scope they have.

    .PARAMETER BaseUrl
        Jira base URL, e.g. https://your-org.atlassian.net

    .PARAMETER Username
        Jira account email used with API token for Basic auth.

    .PARAMETER ApiToken
        Jira API token (SecureString).

    .PARAMETER AuthorizationHeader
        Optional raw Authorization header (overrides username+token construction, still requires parameters for validation).

    .PARAMETER SkipFields
        Skips the /field enumeration (faster); FieldCount will be null.

    .PARAMETER MaxProjects
        Number of projects to fetch (default 50) for visibility sample.

    .PARAMETER ForceFieldCacheRefresh
        When -SkipFields is not set, forces refresh of the cached field list used by Get-FinOpsOnboardingFromJiraIssue.

    .OUTPUTS
        PSCustomObject with: Authenticated(bool), AccountId, DisplayName, Email, ProjectCount, SampleProjects[], FieldCount, Warnings[]

    .EXAMPLE
        Test-FinOpsJiraConnection -BaseUrl https://example.atlassian.net -Username user@example.com -ApiToken $apiToken
    #>
    [CmdletBinding()] param(
        [Parameter()][string]$BaseUrl,
        [Parameter(Mandatory)][ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')][string]$Username,
        [Parameter(Mandatory)][SecureString]$ApiToken,
        [string]$AuthorizationHeader,
        [switch]$SkipFields,
        [int]$MaxProjects = 50,
        [switch]$ForceFieldCacheRefresh
    )
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = $script:AfoDefaultJiraBaseUrl }
    $authenticated = $false
    $accountId = $null; $displayName = $null; $email = $null
    $projects = $null; $fields = $null

    # Auth probe
    try {
        $me = Invoke-FinOpsJiraGet -BaseUrl $BaseUrl -RelativePath '/rest/api/3/myself' -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader
        $authenticated = $true
        $accountId = $me.accountId
        $displayName = $me.displayName
        $email = $me.emailAddress
    } catch {
        $warnings.Add("Auth probe failed: $($_.Exception.Message)")
    }

    # Project sample
    if ($authenticated) {
        try {
            $projResp = Invoke-FinOpsJiraGet -BaseUrl $BaseUrl -RelativePath "/rest/api/3/project/search?startAt=0&maxResults=$MaxProjects" -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader
            if ($projResp.values) {
                $projects = $projResp.values | ForEach-Object { [pscustomobject]@{ Key = $_.key; Name = $_.name; Type = $_.projectTypeKey } }
            }
        } catch {
            $warnings.Add("Project probe failed: $($_.Exception.Message)")
        }
    }

    # Field list (optional)
    if (-not $SkipFields -and $authenticated) {
        try {
            if (-not $script:JiraFieldCache) { $script:JiraFieldCache = @{} }
            $cacheKey = ($BaseUrl.TrimEnd('/')).ToLowerInvariant()
            $cached = $script:JiraFieldCache[$cacheKey]
            if ($ForceFieldCacheRefresh -or -not $cached -or ((Get-Date) - $cached.Retrieved).TotalMinutes -gt 30) {
                $fieldsResp = Invoke-FinOpsJiraGet -BaseUrl $BaseUrl -RelativePath '/rest/api/3/field' -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader
                $cached = @{ Retrieved = Get-Date; Data = $fieldsResp }
                $script:JiraFieldCache[$cacheKey] = $cached
            }
            $fields = $cached.Data
        } catch {
            $warnings.Add("Field probe failed: $($_.Exception.Message)")
        }
    }

    [pscustomobject]@{
        Authenticated = $authenticated
        AccountId = $accountId
        DisplayName = $displayName
        Email = $email
        ProjectCount = if ($projects) { ($projects | Measure-Object).Count } else { 0 }
        SampleProjects = $projects
        FieldCount = if ($fields) { ($fields | Measure-Object).Count } else { $null }
        Warnings = $warnings.ToArray()
    }
}
