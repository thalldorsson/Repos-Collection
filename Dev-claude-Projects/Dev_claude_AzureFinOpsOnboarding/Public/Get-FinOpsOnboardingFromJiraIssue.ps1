function Get-FinOpsOnboardingFromJiraIssue {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'ClientSecret field value is retrieved from Jira issue and needs to be converted to SecureString for downstream use')]
    # Suppress PSScriptAnalyzer warning: ClientSecret field is retrieved from Jira and must be converted to SecureString
    <#
    .SYNOPSIS
        Retrieves a Jira issue and maps selected (system + custom) fields into FinOps onboarding parameter values.

    .DESCRIPTION
        Pulls a Jira Cloud issue (REST API v3) and projects selected field values into a PSCustomObject whose
        property names align with downstream onboarding logic (e.g. Invoke-FinOpsOnboarding).

    MAPPING MODES
        * Automatic (default): Discovers a curated set of display names -> output properties.
        * Explicit: Provide -FieldMap hashtable to take full control.
        * Scripted: Hashtable values can be ScriptBlocks for transformation / normalization logic.

    AUTOMATIC MAPPING SET (when -FieldMap omitted)
        (System) Issue Type            -> IssueType      (issuetype.name)
        (System) Key                   -> IssueKey       (issue.key; not in /field list)
        (System) Summary               -> Summary        (fields.summary)
        Country                        -> Country
        Partner Name                   -> PartnerName
        Customer name                  -> CustomerName
        Tenant Name                    -> TenantName
        Tenant Domain                  -> PrimaryDomain
        End Customer Tenant ID         -> EndCustomerTenantId
        Tenant ID                      -> TenantId

    BEHAVIOR NOTES
                * IssueKey, Summary, IssueType always added even if not mapped or you pass -FieldMap.
                * 'Issue Key' (root property) is never looked up in /field; we skip it intentionally. For 'Issue Type' and 'Summary'
                    Jira may not surface identical display names via /field depending on plan / configuration; Verbose "not found"
                    lines for those two are normal and do not block their final inclusion (they are injected after issue fetch).
                * Exact (case‑sensitive) match on custom display names; rename in Jira or use explicit map if different.
                * Unresolved names -> null + Verbose note (or throw with -FailOnEmptyAutoMap if none resolved).
                * EndCustomerTenantId also populated from customfield_11252 if present.
                * Use Get-FinOpsJiraFieldMetadata to verify display names; use Get-FinOpsJiraProjects to confirm project key visibility.

    FIELD MAP VALUE TYPES (explicit mode)
        * String: Dot-path from root issue object (e.g. 'fields.customfield_10583').
        * ScriptBlock: Invoked with full issue object; return desired value.

    SECURITY HANDLING
        * Output property containing 'ClientSecret' auto-converted to SecureString if plain string.
        * API token never logged; Username & ApiToken mandatory.

    API TOKEN & CLOUD ID NOTES
        * Jira Cloud API tokens inherit user permissions (not fine‑grained scoped).
        * Auth pattern: Basic base64(email:token).
        * Quick verify:  curl -u email@example.com:token https://<site>.atlassian.net/rest/api/3/myself
        * Get cloudId:   curl -u email:token https://<site>.atlassian.net/rest/api/3/serverInfo  (id field)
        * Universal form: https://api.atlassian.com/ex/jira/{cloudId}/rest/api/3/issue/<KEY>
        * This function uses site-specific base URL so cloudId not required.
        * Future: swap to OAuth 2.0 (Bearer) by extending Invoke-FinOpsJiraGet.

    DIAGNOSTICS & RELATED HELPERS
        * Get-FinOpsJiraFieldMetadata  - Browse & filter fields / IDs.
        * Get-FinOpsJiraIssue          - Raw issue payload.
        * Get-FinOpsJiraSearch         - Run JQL and list keys.
        * Test-FinOpsJiraIssueVisibility - Classify 404/400 vs permission vs existence.
    * Get-FinOpsJiraProjects       - List accessible project keys (detect permission vs typo quickly).

    PERFORMANCE
        * Automatic mode calls /rest/api/3/field (can be large). For bulk + known IDs use explicit -FieldMap.

        TROUBLESHOOTING QUICK GUIDE
                * 404 on issue GET + 400 on search: Usually project key not visible to the token user (missing Browse Project) or typo.
                    -> Run Get-FinOpsJiraProjects | Where Key -eq <PROJECT> to confirm visibility.
                * Verbose: "Display field 'Issue Type' not found" or 'Summary' not found: Normal (system inject later) unless other fields also missing.
                * All automatic fields null + warning: None of the expected display names matched. Either localization/renames or wrong project/permissions.
                    -> Inspect field names: Get-FinOpsJiraFieldMetadata -NameContains 'tenant' / 'partner' / etc.
                * Need minimal mapping speed: Build an explicit -FieldMap with IDs to skip name resolution.
                * Confirm auth quickly: Invoke /rest/api/3/myself or use forthcoming Test-FinOpsJiraConnection helper (if implemented).

    .PARAMETER BaseUrl
        Jira base URL (e.g. https://crayon-group.atlassian.net). Do not include a trailing slash.

    .PARAMETER IssueKey
        Jira issue key (e.g. FIN-123 / CGGS-714).

    .PARAMETER Username
        (Mandatory) Jira account email used with the API token for Basic authentication. Must be a valid email format.

    .PARAMETER ApiToken
        (Mandatory) Jira API token as SecureString. Create/manage at: https://id.atlassian.com/manage/api-tokens

    .PARAMETER AuthorizationHeader
        Optional raw Authorization header (e.g. 'Basic xxx'). If supplied it is passed through to the underlying
        helper; Username/ApiToken are still validated (current implementation does not make them mutually exclusive).

    .PARAMETER FieldMap
        (Optional) Hashtable mapping output property names (keys) to either dot-path strings or scriptblocks. When
        omitted automatic display-name based mapping runs. Supplying this disables automatic mapping.

    .PARAMETER UseStandardDisplayNames
        Optional switch retained for explicitness; automatic mapping already occurs by default when -FieldMap is absent.
        Providing it has no effect beyond an extra Verbose message.

    .PARAMETER FailOnEmptyAutoMap
        When set, the command will throw if automatic display-name mapping finds none of the expected fields. By default
        the function now returns an object with those properties set to $null and emits a warning instead of throwing.

        .OUTPUTS
                PSCustomObject with a subset/all of:
                    IssueType, IssueKey, Summary,
                    Country, PartnerName, CustomerName,
                    TenantName, PrimaryDomain,
                    EndCustomerTenantId, TenantId,
                    (plus any explicitly mapped custom properties you add in -FieldMap)

    .EXAMPLE
        # 1. Automatic mapping (default) with Verbose insight.
        $apiToken = Read-Host 'Jira API Token' -AsSecureString
        $p = Get-FinOpsOnboardingFromJiraIssue -BaseUrl https://crayon-group.atlassian.net -IssueKey CGGS-713 -Username thorsteinn.halldorsson@sensa.is -ApiToken $apiToken -Verbose
        $p | Format-List

    .EXAMPLE
        # 2. Explicit map (skip auto resolution for performance in batch scenarios).
        $map = @{ CustomerName='fields.customfield_10010'; TenantId='fields.customfield_10011'; PrimaryDomain='fields.customfield_10012' }
        Get-FinOpsOnboardingFromJiraIssue -BaseUrl https://crayon-group.atlassian.net -IssueKey CGGS-713 -Username thorsteinn.halldorsson@sensa.is -ApiToken $apiToken -FieldMap $map

        .EXAMPLE
                # 3. Mixed map with scriptblock normalization (strip protocol).
                $map = @{
                    CustomerName  = 'fields.summary'
                    PrimaryDomain = { param($issue) ($issue.fields.customfield_10012 -replace '^https?://','').TrimEnd('/') }
                    TenantId      = 'fields.customfield_10011'
                }
                Get-FinOpsOnboardingFromJiraIssue -BaseUrl https://crayon-group.atlassian.net -IssueKey CGGS-713 -Username thorsteinn.halldorsson@sensa.is -ApiToken $apiToken -FieldMap $map

        .EXAMPLE
                # 4. Scriptblock extracting first value from multi-select custom field.
                $map = @{
                    Country = { param($issue) ($issue.fields.customfield_10281 | Select-Object -First 1) }
                    TenantId = 'fields.customfield_11897'
                }
                Get-FinOpsOnboardingFromJiraIssue -BaseUrl https://crayon-group.atlassian.net -IssueKey CGGS-713 -Username thorsteinn.halldorsson@sensa.is -ApiToken $apiToken -FieldMap $map

    .EXAMPLE
        # 5. Enforce failure if no automatic display names resolve.
        Get-FinOpsOnboardingFromJiraIssue -BaseUrl https://crayon-group.atlassian.net -IssueKey CGGS-713 -Username thorsteinn.halldorsson@sensa.is -ApiToken $apiToken -FailOnEmptyAutoMap -Verbose

    .NOTES
        * Automatic mode: one /field call per invocation (optimize by caching externally for batch jobs).
        * Display name matching is exact; small wording changes in Jira break automatic mapping silently (Verbose shows misses).
        * Combine explicit + automatic behavior manually by building a FieldMap then adding custom scriptblock entries.
        * Helper synergy:
            - Use Get-FinOpsJiraSearch for quick existence checks before mapping.
            - Use Test-FinOpsJiraIssueVisibility if you suspect 404/403 ambiguity on an IssueKey.
        * Future candidates: partial overrides (auto + explicit merge), local field cache, fuzzy similarity for near-miss names, retry/backoff on 429.
        * Null output properties are normal when a field is not on the issue's screen or permission restricts it.
    .LINK
        Get-FinOpsJiraFieldMetadata
    .LINK
        Get-FinOpsJiraIssue
    .LINK
        Get-FinOpsJiraSearch
    .LINK
        Test-FinOpsJiraIssueVisibility
    .LINK
        Test-FinOpsJiraConnection

    ADDITIONAL PARAMETER DETAILS
        SkipFieldDiscovery
            Skips the /rest/api/3/field call. Only system properties (IssueKey, Summary, IssueType) plus any explicitly
            mapped paths will be populated. Use this for performance in batch mode once you have a stable -FieldMap.

        FuzzyAutoMatch
            Attempts a lightweight similarity match (character difference heuristic) when an exact display name is not
            found. It only engages for missing names and requires the /field list to be present. Verbose output shows
            any accepted fuzzy matches. Intended as convenience—explicit mapping remains more reliable.

        ForceFieldCacheRefresh
            Forces a fresh /field retrieval even if a cached copy (<=30 min old) exists. Combine with Verbose to verify
            new/renamed fields are picked up promptly.

    FIELD FETCH FALLBACK BEHAVIOR
        If the /field call fails (e.g. permission, transient network, plan restrictions), the function now emits a warning
        and continues, producing system fields plus nulls for the unmapped custom properties (instead of throwing).
        Options when this happens:
          * Re-run with -SkipFieldDiscovery if you only need system fields.
          * Supply -FieldMap with field IDs (no discovery required).
          * Verify permissions by running: Test-FinOpsJiraConnection (should show Authenticated True) and ensuring the account
            has permission to view field configuration.

    VALUE SHAPING & POST-PROCESSING
        Some Jira fields (e.g. single-select) return objects like { value=..; id=.. }. Automatic mapping leaves these
        unchanged to avoid assumptions. Use either:
          * A scriptblock in -FieldMap to extract/normalize (e.g. { param($issue) $issue.fields.customfield_12345.value })
          * Post-processing: $p.Country = $p.Country.value

    MISSING FIELDS (null values)
        PartnerName / EndCustomerTenantId null typically means:
          * Field is not on the request type's screen
          * Display name differs (rename in Jira or use explicit -FieldMap)
          * Value intentionally blank

    EXPLICIT MAP QUICK TEMPLATE
        $fieldMap = @{
            CustomerName         = 'fields.customfield_10010'
            TenantId             = 'fields.customfield_11897'
            PrimaryDomain        = { param($i) ($i.fields.customfield_10012 -replace '^https?://','').TrimEnd('/') }
            Country              = { param($i) $i.fields.customfield_10753.value }
            EndCustomerTenantId  = 'fields.customfield_11252'
            PartnerName          = 'fields.customfield_20001'
        }
        Get-FinOpsOnboardingFromJiraIssue -BaseUrl <site> -IssueKey CGGS-713 -Username <email> -ApiToken $apiToken -FieldMap $fieldMap -SkipFieldDiscovery

    BEST PRACTICE DECISION TREE
        1. Test connectivity:  Test-FinOpsJiraConnection
        2. Issue accessible?:  Test-FinOpsJiraIssueVisibility
        3. Need field IDs?:    Get-FinOpsJiraFieldMetadata -NameContains 'tenant'
        4. Stable mapping?:    Use -FieldMap + -SkipFieldDiscovery for speed
        5. Missing values?:    Confirm field on screen / permissions / rename or explicit map
        6. Performance tweak:  ForceFieldCacheRefresh only when expecting changes

    SECURITY NOTE
        Only properties whose output names contain 'ClientSecret' are auto-secured. If you introduce additional secret
        fields, either adjust naming to include ClientSecret or secure them manually post-call.

    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$BaseUrl,
        [Parameter(Mandatory)][string]$IssueKey,
        [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')][string]$Username,
        [SecureString]$ApiToken,
        [string]$AuthorizationHeader,
        [hashtable]$FieldMap,
        [switch]$UseStandardDisplayNames,
        [switch]$FailOnEmptyAutoMap,
        [switch]$SkipFieldDiscovery,
        [switch]$FuzzyAutoMatch,
        [switch]$ForceFieldCacheRefresh,
        [string]$AutoSharedLinkPattern,
        [string]$SharedLinkPropertyName = 'SharedLink',
        [switch]$AutoSharedLinkIncludeRenderedFields,
        [switch]$AutoSharedLinkIncludeProperties,
        [switch]$AutoSharedLinkIncludeRemoteLinks,
        [switch]$AutoSharedLinkIncludeComments,
        [switch]$AutoSharedLinkIncludeChangelog,
        [string]$SharedLinkFormat,
        [switch]$UseAtlassianMcp,
        [psobject]$IssueObject
    )

    # Automatic mapping now occurs by default if no explicit FieldMap provided.
    if (-not $FieldMap) {
        if ($UseStandardDisplayNames) {
            Write-Verbose 'Performing automatic display-name mapping (explicit switch).'
        } else {
            Write-Verbose 'No FieldMap supplied; performing default automatic display-name mapping.'
        }
        $displayNameMap = [ordered]@{
            # System fields (handled specially after mapping to extract scalar values)
            IssueType = 'Issue Type'
            IssueKey = 'Key'              # note: not present in /field list, handled separately later
            Summary = 'Summary'
            # Custom / business fields
            Country = 'Country'
            PartnerName = 'Partner Name'
            CustomerName = 'Customer name'
            TenantName = 'Tenant Name'
            PrimaryDomain = 'Tenant Domain'
            EndCustomerTenantId = 'End Customer Tenant ID'
            TenantId = 'Tenant ID'
        }
        $allFields = $null
        if ($UseAtlassianMcp -and -not $Username) {
            # When using MCP without direct Jira credentials, skip /field discovery to avoid auth requirement
            $SkipFieldDiscovery = $true
        }
        if ($SkipFieldDiscovery) {
            Write-Verbose 'SkipFieldDiscovery specified; only system fields will be injected (custom fields will be null unless explicit map provided).'
        } else {
            if (-not $script:JiraFieldCache) { $script:JiraFieldCache = @{} }
            $cacheKey = ($BaseUrl.TrimEnd('/')).ToLowerInvariant()
            $cached = $script:JiraFieldCache[$cacheKey]
            if ($ForceFieldCacheRefresh -or -not $cached -or ((Get-Date) - $cached.Retrieved).TotalMinutes -gt 30) {
                try {
                    Write-Verbose 'Fetching /field list from Jira (cache miss or refresh requested).'
                    $fieldsResp = Invoke-FinOpsJiraGet -BaseUrl $BaseUrl -RelativePath '/rest/api/3/field' -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader
                    $cached = @{ Retrieved = Get-Date; Data = $fieldsResp }
                    $script:JiraFieldCache[$cacheKey] = $cached
                } catch {
                    Write-Warning ("Failed to retrieve Jira fields for automatic mapping: $($_.Exception.Message). Fallback: system fields only; custom fields will be null. Consider: -SkipFieldDiscovery with explicit -FieldMap, or ensure permission to call /field (may require broader Jira permissions).")
                    $cached = @{ Retrieved = Get-Date; Data = $null }
                }
            } else {
                Write-Verbose 'Using cached Jira field list.'
            }
            $allFields = $cached.Data
        }
        $FieldMap = [ordered]@{}
        $similarMatches = @()
        foreach ($prop in $displayNameMap.Keys) {
            $wantedName = $displayNameMap[$prop]
            if ($prop -eq 'IssueKey') { continue } # key is root property, not in /field list
            $match = $null
            if ($allFields) { $match = $allFields | Where-Object { $_.name -eq $wantedName } }
            if (-not $match) {
                if ($FuzzyAutoMatch -and $allFields) {
                    # Simple Levenshtein distance or case-insensitive contains heuristic (lightweight)
                    $candidates = $allFields | Where-Object { $_.name -like "*$($wantedName.Split(' ')[0])*" }
                    $best = $null
                    $bestScore = 1e9
                    foreach ($c in $candidates) {
                        $d = [int](Compare-Object -ReferenceObject ($wantedName.ToCharArray()) -DifferenceObject ($c.name.ToCharArray()) -IncludeEqual | Where-Object SideIndicator -ne '==' | Measure-Object).Count
                        if ($d -lt $bestScore) { $bestScore = $d; $best = $c }
                    }
                    if ($best -and $bestScore -le 5) {
                        Write-Verbose "Fuzzy matched '$wantedName' -> '$($best.name)' (distance $bestScore)."
                        $FieldMap[$prop] = "fields.$($best.id)"
                        $similarMatches += [pscustomobject]@{ Requested = $wantedName; Matched = $best.name; Distance = $bestScore }
                        continue
                    }
                }
                Write-Verbose "Display field '$wantedName' not found in Jira. Property '$prop' will be null."; continue
            }
            $id = $match.id
            $FieldMap[$prop] = "fields.$id"
        }
        if ($FieldMap.Count -eq 0) {
            $warn = 'Automatic mapping found none of the expected display field names. Returning empty properties. '
            $warn += 'Supply -FieldMap for explicit mapping, rename fields in Jira, or use -FailOnEmptyAutoMap to enforce failure.'
            if ($FailOnEmptyAutoMap) {
                throw $warn
            } else {
                Write-Warning $warn
                # Populate a placeholder map so downstream loop creates the desired (null) properties.
                foreach ($prop in $displayNameMap.Keys) {
                    $FieldMap[$prop] = ''  # empty string triggers null assignment branch later
                }
            }
        }
        if ($FuzzyAutoMatch -and $similarMatches.Count -gt 0) {
            Write-Verbose ("Fuzzy matches applied: " + ($similarMatches | ForEach-Object { "$($_.Requested)->$($_.Matched)" } -join ', '))
        }
    }
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = $script:FinOpsDefaultJiraBaseUrl }
    $issue = $null
    if ($IssueObject) {
        $issue = $IssueObject
        Write-Verbose 'Using provided IssueObject (skipping fetch).'
    } elseif ($UseAtlassianMcp) {
        if (-not $script:AtlassianMcpProvider -or -not $script:AtlassianMcpProvider.GetIssue) {
            throw "UseAtlassianMcp specified but no Atlassian MCP provider is registered. Call Register-FinOpsAtlassianMcpProvider first."
        }
        Write-Verbose 'Fetching Jira issue via Atlassian MCP provider.'
        $issue = & $script:AtlassianMcpProvider.GetIssue -IssueKey $IssueKey
    } else {
        $issue = Invoke-FinOpsJiraGet -BaseUrl $BaseUrl -RelativePath "/rest/api/3/issue/$IssueKey" -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader
    }

    $out = [ordered]@{}
    foreach ($k in $FieldMap.Keys) {
        $spec = $FieldMap[$k]
        $value = $null
        if ($spec -is [scriptblock]) {
            $value = & $spec $issue
        } elseif ([string]::IsNullOrWhiteSpace($spec)) {
            $value = $null
        } else {
            # dot path navigation
            $segments = $spec -split '\.'
            $cursor = $issue
            foreach ($seg in $segments) {
                if ($null -eq $cursor) { break }
                if ($cursor -is [System.Collections.IDictionary] -and $cursor.Contains($seg)) {
                    $cursor = $cursor[$seg]
                } else {
                    $cursor = $cursor | Select-Object -ExpandProperty $seg -ErrorAction SilentlyContinue
                }
            }
            $value = $cursor
            # Post-adjustment for certain system objects
            if ($k -eq 'IssueType' -and $value) {
                # System field issuetype returns object; we want its name if present
                $value = $value.name
            }
        }
        if ($k -match 'ClientSecret' -and $value -is [string] -and $value.Length -gt 0) {
            $secure = ConvertTo-SecureString -String $value -AsPlainText -Force
            $out[$k] = $secure
        } else {
            $out[$k] = $value
        }
    }
    # Ensure core system scalar properties present even if not mapped (IssueKey, Summary)
    if (-not $out.Contains('IssueKey')) { $out['IssueKey'] = $issue.key }
    if (-not $out.Contains('Summary')) { $out['Summary'] = $issue.fields.summary }
    if (-not $out.Contains('IssueType')) { $out['IssueType'] = $issue.fields.issuetype.name }
    if (-not $out.Contains('EndCustomerTenantId') -and $issue.fields.PSObject.Properties.Name -contains 'customfield_11252') {
        $out['EndCustomerTenantId'] = $issue.fields.customfield_11252
    }
    # Optional automatic shared link extraction
    if ($AutoSharedLinkPattern) {
        Write-Verbose ("Attempting AutoSharedLinkPattern scan using pattern '{0}'" -f $AutoSharedLinkPattern)
        try {
            $scan = Find-FinOpsJiraIssueUrls -BaseUrl $BaseUrl -IssueKey $IssueKey -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader -Patterns $AutoSharedLinkPattern `
                -IncludeRenderedFields:([bool]$AutoSharedLinkIncludeRenderedFields) `
                -IncludeProperties:([bool]$AutoSharedLinkIncludeProperties) `
                -IncludeRemoteLinks:([bool]$AutoSharedLinkIncludeRemoteLinks) `
                -IncludeComments:([bool]$AutoSharedLinkIncludeComments) `
                -IncludeChangelog:([bool]$AutoSharedLinkIncludeChangelog)
            $first = $scan | Select-Object -First 1
            if ($first) {
                Write-Verbose ("AutoSharedLinkPattern matched URL: {0}" -f $first.Match)
                if (-not $out.Contains($SharedLinkPropertyName)) {
                    $out[$SharedLinkPropertyName] = $first.Match
                } else {
                    Write-Verbose ("SharedLinkPropertyName '{0}' already present; skipping overwrite" -f $SharedLinkPropertyName)
                }
            } else {
                Write-Verbose 'AutoSharedLinkPattern produced no matches.'
            }
        } catch {
            Write-Verbose ("AutoSharedLinkPattern scan failed: {0}" -f $_.Exception.Message)
        }
    }
    # Deterministic shared link generation if still absent and format supplied
    if ($SharedLinkFormat -and -not $out.Contains($SharedLinkPropertyName)) {
        Write-Verbose ("Attempting SharedLinkFormat generation: {0}" -f $SharedLinkFormat)
        $tokenMap = @{
            'IssueKey' = $issue.key
            'IssueType' = $out['IssueType']
            'Summary' = $out['Summary']
            'CustomerName' = $out['CustomerName']
            'PartnerName' = $out['PartnerName']
            'TenantName' = $out['TenantName']
            'PrimaryDomain' = $out['PrimaryDomain']
            'TenantId' = $out['TenantId']
            'EndCustomerTenantId' = $out['EndCustomerTenantId']
        }
        $link = $SharedLinkFormat
        foreach ($tk in $tokenMap.Keys) {
            $safe = ($tokenMap[$tk])
            if ($null -ne $safe) {
                $escaped = [regex]::Escape('{' + $tk + '}')
                $link = [regex]::Replace($link, $escaped, [string]$safe)
            }
        }
        if ($link -match '{[A-Za-z0-9]+}') {
            Write-Verbose "SharedLinkFormat still contains unreplaced tokens; leaving property unset."
        } else {
            Write-Verbose ("SharedLinkFormat produced link: {0}" -f $link)
            $out[$SharedLinkPropertyName] = $link
        }
    }
    [pscustomobject]$out
}
