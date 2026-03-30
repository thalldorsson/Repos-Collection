function Get-FinOpsJiraIssueFieldScan {
    <#
    .SYNOPSIS
        Scans a Jira issue for customfield_* properties and returns ID/value/length for quick mapping discovery.

    .DESCRIPTION
        Useful when automatic display-name mapping fails or when you need to build an explicit -FieldMap. It inspects the
        issue JSON and enumerates every property matching customfield_* under fields, summarizing simple scalar values and
        object types. Optionally you can filter by a -ValueContains substring (case-insensitive) to narrow candidates.

    .PARAMETER BaseUrl
        Jira base URL (defaults to module default https://crayon-group.atlassian.net unless overridden by env var FINOPS_JIRA_BASEURL).

    .PARAMETER IssueKey
        Issue key to inspect (e.g. CGGS-713).

    .PARAMETER Username
        Jira account email.

    .PARAMETER ApiToken
        Jira API token (SecureString).

    .PARAMETER AuthorizationHeader
        Optional Authorization header override.

    .PARAMETER ValueContains
        Case-insensitive substring filter applied to the stringified value (after simple flattening) to reduce noise.

    .PARAMETER MaxValueLength
        Maximum captured value string length (default 150) to keep output compact.

    .EXAMPLE
        Get-FinOpsJiraIssueFieldScan -BaseUrl https://crayon-group.atlassian.net -IssueKey CGGS-713 -Username thorsteinn.halldorsson@sensa.is -ApiToken $token -ValueContains tenant

    .OUTPUTS
        PSCustomObject: FieldId, Type, ValuePreview, Length
    #>
    [CmdletBinding()] param(
        [string]$BaseUrl,
        [Parameter(Mandatory)][string]$IssueKey,
        [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')][string]$Username,
        [SecureString]$ApiToken,
        [string]$AuthorizationHeader,
        [string]$ValueContains,
        [int]$MaxValueLength = 150,
        [switch]$UseAtlassianMcp
    )

    $issue = $null
    if ($UseAtlassianMcp) {
        $issue = Invoke-FinOpsJiraMcp -Operation GetIssue -Arguments @{ IssueKey = $IssueKey }
    } else {
        if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = $script:FinOpsDefaultJiraBaseUrl }
        if (-not $Username -or -not $ApiToken) { throw 'Username and ApiToken are required when not using -UseAtlassianMcp.' }
        $issue = Get-FinOpsJiraIssue -BaseUrl $BaseUrl -IssueKey $IssueKey -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader
    }
    $props = $issue.fields.PSObject.Properties | Where-Object { $_.Name -like 'customfield_*' }
    $results = foreach ($p in $props) {
        $val = $p.Value
        $type = $null
        $preview = $null
        if ($null -eq $val) {
            $type = 'null'; $preview = ''
        } elseif ($val -is [string]) {
            $type = 'string'; $preview = $val
        } elseif ($val -is [int] -or $val -is [long] -or $val -is [double]) {
            $type = 'number'; $preview = "$val"
        } elseif ($val -is [bool]) {
            $type = 'bool'; $preview = "$val"
        } elseif ($val -is [System.Collections.IEnumerable] -and -not ($val -is [string])) {
            $type = 'array';
            $preview = ($val | ForEach-Object {
                    if ($_ -is [string]) { $_ }
                    elseif ($_ -is [System.Collections.IDictionary] -and $_.Contains('value')) { $_.value }
                    elseif ($_ -is [System.Collections.IDictionary] -and $_.Contains('name')) { $_.name }
                    else { ($_ | Out-String).Trim() }
                }) -join ', '
        } elseif ($val -is [System.Collections.IDictionary]) {
            $type = 'object'
            if ($val.Contains('value')) { $preview = $val.value }
            elseif ($val.Contains('name')) { $preview = $val.name }
            else { $preview = ($val.Keys | Select-Object -First 5) -join ';' }
        } else {
            $type = $val.GetType().Name
            $preview = ($val | Out-String).Trim()
        }
        if ($preview.Length -gt $MaxValueLength) { $preview = $preview.Substring(0, $MaxValueLength) + '…' }
        [pscustomobject]@{
            FieldId = $p.Name
            Type = $type
            ValuePreview = $preview
            Length = $preview.Length
        }
    }
    if ($ValueContains) {
        $lc = $ValueContains.ToLowerInvariant()
        $results = $results | Where-Object { $_.ValuePreview -and $_.ValuePreview.ToLowerInvariant().Contains($lc) }
    }
    $results | Sort-Object FieldId
}
