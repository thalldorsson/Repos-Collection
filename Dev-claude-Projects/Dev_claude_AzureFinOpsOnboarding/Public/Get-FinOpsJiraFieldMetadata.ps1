function Get-FinOpsJiraFieldMetadata {
    <#
    .SYNOPSIS
        Retrieves Jira field metadata (name, id, schema) to assist with building FieldMap entries.

    .DESCRIPTION
        Calls Jira Cloud REST API v3 (GET /rest/api/3/field) using the same authentication pattern as other
        onboarding helpers and returns a filtered, tidy list of field metadata. Useful when automatic mapping
        in Get-FinOpsOnboardingFromJiraIssue cannot find your custom display names and you need to build an
        explicit -FieldMap hashtable (key = output property name, value = 'fields.<fieldId>').

        Filtering options (-NameContains, -NameStartsWith, -NameRegex) are AND-combined where compatible.

    .PARAMETER BaseUrl
        Jira base URL (e.g. https://crayon-group.atlassian.net) without trailing slash.

    .PARAMETER Username
        Jira account email (mandatory) used with API token for Basic auth.

    .PARAMETER ApiToken
        Jira API token as SecureString.

    .PARAMETER AuthorizationHeader
        Optional pre-built Authorization header. (Username/ApiToken still validated.)

    .PARAMETER NameContains
        Case-insensitive substring filter applied to the display Name.

    .PARAMETER NameStartsWith
        Case-insensitive starts-with filter applied to the display Name.

    .PARAMETER NameRegex
        Regular expression applied to the display Name.

    .PARAMETER IncludeSystem
        Include system (non-custom) fields. By default only custom fields are shown unless you specify this.

    .PARAMETER Raw
        Return the raw objects from Jira without projection/filtering (overrides filtering switches except IncludeSystem).

    .EXAMPLE
        # List all custom fields containing the word 'Tenant'
        Get-FinOpsJiraFieldMetadata -BaseUrl https://your-domain.atlassian.net -Username you@company.com -ApiToken $apiToken -NameContains Tenant

    .EXAMPLE
        # Build a FieldMap using discovered field IDs
        $fields = Get-FinOpsJiraFieldMetadata -BaseUrl https://your-domain.atlassian.net -Username you@company.com -ApiToken $apiToken -NameContains 'Tenant','Partner','Country'
        # Create a lookup hashtable keyed by display name
        $byName = @{}
        foreach($f in $fields){ $byName[$f.Name] = $f }
        $map = @{}
        if($byName['Country'])       { $map.Country       = "fields.$($byName['Country'].Id)" }
        if($byName['Partner Name'])   { $map.PartnerName   = "fields.$($byName['Partner Name'].Id)" }
        if($byName['Customer name'])  { $map.CustomerName  = "fields.$($byName['Customer name'].Id)" }
        if($byName['Tenant Name'])    { $map.TenantName    = "fields.$($byName['Tenant Name'].Id)" }
        if($byName['Tenant Domain'])  { $map.PrimaryDomain = "fields.$($byName['Tenant Domain'].Id)" }
        if($byName['Tenant ID'])      { $map.TenantId      = "fields.$($byName['Tenant ID'].Id)" }
        $map

    .NOTES
        * Jira returns both system & custom fields; custom ones usually have ids starting with 'customfield_'.
        * Use -Raw if you need every original property Jira returns.
        * Combine substring and regex filters cautiously; regex runs last.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$BaseUrl,
        [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')][string]$Username,
        [SecureString]$ApiToken,
        [string]$AuthorizationHeader,
        [string[]]$NameContains,
        [string[]]$NameStartsWith,
        [string]$NameRegex,
        [switch]$IncludeSystem,
        [switch]$Raw,
        [switch]$UseAtlassianMcp
    )
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = $script:FinOpsDefaultJiraBaseUrl }

    if ($UseAtlassianMcp) {
        if (-not $script:AtlassianMcpProvider -or -not $script:AtlassianMcpProvider.GetFields) {
            throw "UseAtlassianMcp specified but provider.GetFields not registered. Call Register-FinOpsAtlassianMcpProvider with -GetFieldsScript."
        }
        $allFields = & $script:AtlassianMcpProvider.GetFields
    } else {
        if (-not $Username -and -not $AuthorizationHeader) { throw 'Username (or AuthorizationHeader) is required when not using Atlassian MCP.' }
        try {
            $allFields = Invoke-FinOpsJiraGet -BaseUrl $BaseUrl -RelativePath '/rest/api/3/field' -Username $Username -ApiToken $ApiToken -AuthorizationHeader $AuthorizationHeader
        } catch {
            throw "Failed to retrieve Jira fields: $($_.Exception.Message)"
        }
    }

    if ($Raw) { return $allFields }

    $proj = foreach ($f in $allFields) {
        [pscustomobject]@{
            Name = $f.name
            Id = $f.id
            Custom = [bool]($f.id -like 'customfield_*')
            SchemaType = $f.schema.type
            Clause = ($f.clauseNames -join ',')
        }
    }

    if (-not $IncludeSystem) { $proj = $proj | Where-Object { $_.Custom } }

    if ($NameContains) {
        foreach ($frag in $NameContains) {
            $proj = $proj | Where-Object { $_.Name -like "*${frag}*" }
        }
    }
    if ($NameStartsWith) {
        foreach ($start in $NameStartsWith) {
            $proj = $proj | Where-Object { $_.Name -like "${start}*" }
        }
    }
    if ($NameRegex) {
        $proj = $proj | Where-Object { $_.Name -match $NameRegex }
    }

    $proj | Sort-Object Name
}
