function Find-FinOpsJiraIssueUrls {
    <#
    .SYNOPSIS
        Searches a Jira issue for URL strings across fields, renderedFields, properties and remote links.
    .DESCRIPTION
        When a URL is visible in the Jira UI but not present in a simple customfield_* value, it may reside in:
          * A rendered field (HTML) – need expand=renderedFields
          * A remote link ( /issue/{key}/remotelink )
          * An issue property provided by an app ( /issue/{key}/properties/{prop} )
          * Nested JSON within objects/arrays stored in fields
        This helper consolidates all potential sources and returns a flattened list of matches with their origin path.
    .PARAMETER BaseUrl
        Jira base URL (defaults to module default https://crayon-group.atlassian.net; override via env var FINOPS_JIRA_BASEURL). No trailing slash.
    .PARAMETER IssueKey
        Issue key (e.g. FIN-123).
    .PARAMETER Username
        Jira user email.
    .PARAMETER ApiToken
        SecureString API token.
    .PARAMETER AuthorizationHeader
        Optional Authorization header override.
    .PARAMETER Patterns
        One or more regex patterns to match. Defaults to a generic URL pattern if omitted.
    .PARAMETER IncludeRenderedFields
        Include expand=renderedFields and scan those values.
    .PARAMETER IncludeProperties
        Enumerate issue properties (keys), fetch each value JSON, and scan.
    .PARAMETER IncludeRemoteLinks
        Retrieve remote links and scan their URL/object parts.
    .PARAMETER IncludeComments
        Retrieve issue comments and scan their bodies (ADF JSON and any plain strings) for URLs.
    .PARAMETER IncludeChangelog
        Include changelog expansion and scan history items for added/removed URLs.
    .PARAMETER MaxDepth
        Maximum object depth to recurse when flattening (default 12).
    .OUTPUTS
        PSCustomObject: SourceType, Path, Match, FullValue (trimmed), Origin
    .EXAMPLE
        Find-FinOpsJiraIssueUrls -BaseUrl https://org.atlassian.net -IssueKey FIN-1 -Username user@org -ApiToken $tok -IncludeRenderedFields -IncludeProperties -IncludeRemoteLinks -Patterns 'deila\\.sensa\\.is'
    #>
    [CmdletBinding()]
    param(
        [string] $BaseUrl,
        [Parameter(Mandatory)] [string] $IssueKey,
        [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')] [string] $Username,
        [SecureString] $ApiToken,
        [string] $AuthorizationHeader,
        [string[]] $Patterns,
        [switch] $IncludeRenderedFields,
        [switch] $IncludeProperties,
        [switch] $IncludeRemoteLinks,
        [switch] $IncludeComments,
        [switch] $IncludeChangelog,
        [switch] $IncludeAllExpansions,
        [string[]] $AdditionalExpansions,
        [switch] $DecodePercentEncoded,
        [switch] $GracefulIssueFailure,
        [switch] $EmitSummary,
        [int] $MaxDepth = 12,
        [switch] $UseAtlassianMcp
    )
    if (-not $UseAtlassianMcp -and [string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = $script:FinOpsDefaultJiraBaseUrl }
    if (-not $Patterns -or $Patterns.Count -eq 0) { $Patterns = @('https?://[^\s"<>]+') }

    $expand = @()
    if ($IncludeRenderedFields) { $expand += 'renderedFields' }
    if ($IncludeChangelog) { $expand += 'changelog' }
    if ($IncludeAllExpansions) {
        $expand += 'renderedFields', 'changelog', 'names', 'schema', 'operations', 'versionedRepresentations', 'editmeta'
    }
    if ($AdditionalExpansions) { $expand += $AdditionalExpansions }
    $expand = $expand | Select-Object -Unique
    try {
        if ($UseAtlassianMcp) {
            $issue = Invoke-FinOpsJiraMcp -Operation GetIssue -Arguments @{ IssueKey = $IssueKey; Expand = $expand }
        } else {
            if (-not $Username -or -not $ApiToken) { throw 'Username and ApiToken are required when not using -UseAtlassianMcp.' }
            $issue = Get-FinOpsJiraIssue -BaseUrl $BaseUrl -IssueKey $IssueKey -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader -Expand $expand
        }
    } catch {
        if ($GracefulIssueFailure) {
            Write-Verbose ("Issue retrieval failed but GracefulIssueFailure set: {0}" -f $_.Exception.Message)
            if ($EmitSummary) { return [pscustomobject]@{ TotalMatches = 0; BySourceType = @(); PropertiesEnumerated = 0; PropertyFetchSucceeded = 0; PropertyFetchFailed = 0; Patterns = $Patterns -join ', '; Error = $_.Exception.Message } }
            return @()
        }
        throw
    }

    $results = New-Object System.Collections.Generic.List[object]
    $seen = New-Object System.Collections.Generic.HashSet[string]

    function Add-Match([string]$source, [string]$path, [string]$value, [string]$origin) {
        foreach ($pat in $Patterns) {
            $m = [regex]::Matches($value, $pat)
            foreach ($mm in $m) {
                $key = "$source|$path|$($mm.Value)"
                if (-not $seen.Contains($key)) {
                    $seen.Add($key) | Out-Null
                    $results.Add([pscustomobject]@{
                            SourceType = $source
                            Path = $path
                            Match = $mm.Value
                            FullValue = if ($value.Length -gt 400) { $value.Substring(0, 400) + '…' } else { $value }
                            Origin = $origin
                        })
                }
            }
            if ($DecodePercentEncoded -and $value -match '%[0-9A-Fa-f]{2}') {
                try {
                    $decoded = [System.Uri]::UnescapeDataString($value)
                    if ($decoded -ne $value) {
                        $m2 = [regex]::Matches($decoded, $pat)
                        foreach ($mm2 in $m2) {
                            $key2 = "$source|$path|$($mm2.Value)"
                            if (-not $seen.Contains($key2)) {
                                $seen.Add($key2) | Out-Null
                                $results.Add([pscustomobject]@{
                                        SourceType = $source
                                        Path = $path
                                        Match = $mm2.Value
                                        FullValue = if ($decoded.Length -gt 400) { $decoded.Substring(0, 400) + '…' } else { $decoded }
                                        Origin = $origin + ':decoded'
                                    })
                            }
                        }
                    }
                } catch { Write-Verbose ("Percent decode failed at {0}: {1}" -f $path, $_.Exception.Message) }
            }
        }
    }

    function Flatten([object]$obj, [string]$path, [int]$depth) {
        if ($depth -gt $MaxDepth -or $null -eq $obj) { return }
        if ($obj -is [string]) { Add-Match -source 'Field' -path $path -value $obj -origin 'fields' ; return }
        if ($obj -is [System.Collections.IDictionary]) {
            foreach ($k in $obj.Keys) { 
                $newPath = if ($path) { "$path.$k" } else { $k }
                Flatten -obj $obj[$k] -path $newPath -depth ($depth + 1) 
            }
        } elseif ($obj -is [System.Collections.IEnumerable]) {
            $i = 0; foreach ($v in $obj) { Flatten -obj $v -path "$path[$i]" -depth ($depth + 1); $i++ }
        }
    }

    # Scan fields
    Flatten -obj $issue.fields -path 'fields' -depth 0

    # Rendered fields
    if ($IncludeRenderedFields -and $issue.renderedFields) {
        if ($issue.renderedFields -is [System.Collections.IDictionary]) {
            foreach ($key in $issue.renderedFields.Keys) {
                $val = $issue.renderedFields[$key]
                if ($val -is [string]) { Add-Match -source 'RenderedField' -path "renderedFields.$key" -value $val -origin 'renderedFields' }
            }
        } else {
            foreach ($prop in $issue.renderedFields.PSObject.Properties) {
                $val = $prop.Value
                if ($val -is [string]) { Add-Match -source 'RenderedField' -path "renderedFields.$($prop.Name)" -value $val -origin 'renderedFields' }
            }
        }
    }

    # Remote links
    if ($IncludeRemoteLinks) {
        try {
            $remote = if ($UseAtlassianMcp) {
                Invoke-FinOpsJiraMcp -Operation GetRemoteLinks -Arguments @{ IssueKey = $IssueKey }
            } else {
                if (-not $Username -or -not $ApiToken) { throw 'Username and ApiToken are required when not using -UseAtlassianMcp.' }
                Invoke-FinOpsJiraGet -BaseUrl $BaseUrl -RelativePath "/rest/api/3/issue/$IssueKey/remotelink" -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader
            }
            foreach ($rl in $remote) {
                $json = ($rl | ConvertTo-Json -Depth 6 -Compress)
                Add-Match -source 'RemoteLink' -path 'remotelink' -value $json -origin 'remotelink'
            }
        } catch {
            if ($UseAtlassianMcp) { throw "-IncludeRemoteLinks requires MCP delegate GetRemoteLinks: $($_.Exception.Message)" }
            Write-Verbose "Remote link retrieval failed: $($_.Exception.Message)"
        }
    }

    # Comments
    if ($IncludeComments) {
        try {
            $comments = if ($UseAtlassianMcp) {
                Invoke-FinOpsJiraMcp -Operation GetIssueComments -Arguments @{ IssueKey = $IssueKey }
            } else {
                if (-not $Username -or -not $ApiToken) { throw 'Username and ApiToken are required when not using -UseAtlassianMcp.' }
                Invoke-FinOpsJiraGet -BaseUrl $BaseUrl -RelativePath "/rest/api/3/issue/$IssueKey/comment?maxResults=500" -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader
            }
            if ($comments.comments) {
                $idx = 0
                foreach ($c in $comments.comments) {
                    # Flatten body (ADF structure) to JSON string, plus any direct plain text fields
                    $bodyJson = ($c.body | ConvertTo-Json -Depth 12 -Compress)
                    Add-Match -source 'Comment' -path "comment[$idx].body" -value $bodyJson -origin 'comment'
                    if ($c.body -is [string]) { Add-Match -source 'Comment' -path "comment[$idx].bodyText" -value $c.body -origin 'comment' }
                    $idx++
                }
            }
        } catch {
            if ($UseAtlassianMcp) { throw "-IncludeComments requires MCP delegate GetIssueComments: $($_.Exception.Message)" }
            Write-Verbose ("Comment retrieval failed: {0}" -f $_.Exception.Message)
        }
    }

    # Changelog (if expanded)
    if ($IncludeChangelog -and $issue.changelog -and $issue.changelog.histories) {
        try {
            $histIdx = 0
            foreach ($h in $issue.changelog.histories) {
                $hJson = ($h | ConvertTo-Json -Depth 8 -Compress)
                Add-Match -source 'Changelog' -path "changelog.histories[$histIdx]" -value $hJson -origin 'changelog'
                $histIdx++
            }
        } catch { Write-Verbose ("Changelog scan failed: {0}" -f $_.Exception.Message) }
    }

    # Issue properties (with metrics)
    $propEnumerated = 0
    $propFetchOk = 0
    $propFetchFail = 0
    if ($IncludeProperties) {
        try {
            if ($UseAtlassianMcp) {
                $propItems = Invoke-FinOpsJiraMcp -Operation GetIssueProperties -Arguments @{ IssueKey = $IssueKey; FetchValues = $true }
                foreach ($pi in $propItems) {
                    $propEnumerated++
                    $flat = $pi.Value
                    if ($flat) { Add-Match -source 'Property' -path ("property[" + $pi.Key + "]") -value $flat -origin 'property' }
                    if ($flat -ne $null) { $propFetchOk++ } else { $propFetchFail++ }
                }
            } else {
                if (-not $Username -or -not $ApiToken) { throw 'Username and ApiToken are required when not using -UseAtlassianMcp.' }
                $props = Invoke-FinOpsJiraGet -BaseUrl $BaseUrl -RelativePath "/rest/api/3/issue/$IssueKey/properties" -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader
                foreach ($pi in $props.keys) {
                    $k = $pi.key
                    if ([string]::IsNullOrWhiteSpace($k)) { continue }
                    $propEnumerated++
                    try {
                        $pv = Invoke-FinOpsJiraGet -BaseUrl $BaseUrl -RelativePath "/rest/api/3/issue/$IssueKey/properties/$k" -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader
                        $val = $pv.value
                        $flat = if ($null -eq $val) { '' } elseif ($val -is [string]) { $val } else { ($val | ConvertTo-Json -Depth 6 -Compress) }
                        if ($flat) { Add-Match -source 'Property' -path "property[$k]" -value $flat -origin 'property' }
                        $propFetchOk++
                    } catch { Write-Verbose ("Property fetch failed for {0}: {1}" -f $k, $_.Exception.Message); $propFetchFail++ }
                }
            }
        } catch {
            if ($UseAtlassianMcp) { throw "-IncludeProperties requires MCP delegate GetIssueProperties: $($_.Exception.Message)" }
            Write-Verbose ("Property list failed: {0}" -f $_.Exception.Message)
        }
    }

    $sorted = $results | Sort-Object Match, SourceType, Path
    if ($EmitSummary) {
        $byType = $sorted | Group-Object SourceType | ForEach-Object { [pscustomobject]@{ SourceType = $_.Name; Count = $_.Count } }
        [pscustomobject]@{
            TotalMatches = $sorted.Count
            BySourceType = $byType
            PropertiesEnumerated = $propEnumerated
            PropertyFetchSucceeded = $propFetchOk
            PropertyFetchFailed = $propFetchFail
            Patterns = $Patterns -join ', '
        }
    } else {
        $sorted
    }
}
