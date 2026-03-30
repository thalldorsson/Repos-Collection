function Get-PhishIRDefenderIndicators {
    <#
    .SYNOPSIS
    Retrieve and filter URL/domain threat intelligence indicators from Microsoft Defender for Endpoint.

    .DESCRIPTION
    Queries threat intelligence indicators (tiIndicators) from Microsoft Graph Security API to view 
    existing URL/domain block lists, allow lists, and warning indicators in Defender for Endpoint.
    
    Useful for:
    - Auditing active URL blocks
    - Identifying expired indicators
    - Finding indicators by threat type or action
    - Validating indicator submission results
    - Generating compliance reports

    .PARAMETER IndicatorType
    Filter by indicator type. Valid values:
    - Url: Full URL paths (e.g., https://example.com/malicious)
    - DomainName: Domain names (e.g., example.com)
    - IpAddress: IPv4/IPv6 addresses
    - All (default): Return all URL/domain/IP indicators

    .PARAMETER Action
    Filter by indicator action. Valid values:
    - Block: Blocking indicators
    - Allow: Allow-list indicators
    - Warn: Warning indicators
    - Audit: Audit-only indicators
    - All (default): Return all actions

    .PARAMETER ThreatType
    Filter by threat type (e.g., Phishing, MaliciousUrl, Malware, C2). 
    Default: return all threat types.

    .PARAMETER ShowExpired
    Include expired indicators in results. By default, only active indicators are returned.

    .PARAMETER IncludeDetails
    Include full indicator details (confidence, severity, tags, etc.). 
    Default: return summary view (ID, URL/domain, action, expiration).

    .EXAMPLE
    Get-PhishIRDefenderIndicators

    Retrieve all active URL/domain indicators with summary view.

    .EXAMPLE
    Get-PhishIRDefenderIndicators -Action Block -IncludeDetails

    List all active blocking indicators with full details.

    .EXAMPLE
    Get-PhishIRDefenderIndicators -IndicatorType DomainName -ThreatType Phishing -ShowExpired

    Find all phishing domain indicators including expired ones.

    .EXAMPLE
    Get-PhishIRDefenderIndicators -Action Allow | Select-Object DomainName, Description, ExpirationDateTime

    View all allow-listed domains with descriptions and expiration dates.

    .EXAMPLE
    Get-PhishIRDefenderIndicators -IndicatorType Url -Action Block | Where-Object { $_.ExpirationDateTime -lt (Get-Date).AddDays(7) }

    Find URL block indicators expiring in the next 7 days.

    .NOTES
    Requires:
    - Microsoft.Graph.Beta.Security module
    - Connect-MgGraph -Scopes "ThreatIndicators.Read.All" or "ThreatIndicators.ReadWrite.OwnedBy"
    
    Graph API endpoint: GET https://graph.microsoft.com/beta/security/tiIndicators
    Filters: targetProduct eq 'Microsoft Defender ATP'
    
    Returns indicators managed by current tenant only (based on AzureTenantId).

    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateSet('Url', 'DomainName', 'IpAddress', 'All')]
        [string]$IndicatorType = 'All',

        [Parameter(Mandatory = $false)]
        [ValidateSet('Block', 'Allow', 'Warn', 'Audit', 'All')]
        [string]$Action = 'All',

        [Parameter(Mandatory = $false)]
        [string]$ThreatType,

        [Parameter(Mandatory = $false)]
        [switch]$ShowExpired,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeDetails
    )

    $ErrorActionPreference = 'Stop'

    try {
        Write-PhishIRLog -Message "Querying Defender URL/domain indicators" -Level Info

        # Check Microsoft Graph connection
        try {
            $context = Get-MgContext -ErrorAction Stop
            if (-not $context) {
                throw "Not connected to Microsoft Graph"
            }
            
            # Verify required permission
            $requiredScopes = @("ThreatIndicators.Read.All", "ThreatIndicators.ReadWrite.OwnedBy")
            $hasPermission = $false
            foreach ($scope in $requiredScopes) {
                if ($context.Scopes -contains $scope) {
                    $hasPermission = $true
                    break
                }
            }
            
            if (-not $hasPermission) {
                Write-Warning "Missing required Graph permission. Need one of: $($requiredScopes -join ', ')"
                Write-Warning "Run: Connect-MgGraph -Scopes 'ThreatIndicators.ReadWrite.OwnedBy'"
                throw "Missing Graph API permission"
            }
            
            Write-PhishIRLog -Message "Microsoft Graph connection verified" -Level Info
        }
        catch {
            Write-Warning "Not connected to Microsoft Graph or missing permissions"
            Write-Warning "Run: Connect-MgGraph -Scopes 'ThreatIndicators.ReadWrite.OwnedBy'"
            throw "Microsoft Graph connection required"
        }

        # Build Graph API filter
        $filters = @()
        $filters += "targetProduct eq 'Microsoft Defender ATP'"

        # Filter by action
        if ($Action -ne 'All') {
            $tiAction = switch ($Action) {
                'Block' { 'block' }
                'Allow' { 'allow' }
                'Warn' { 'warn' }
                'Audit' { 'alert' }
            }
            $filters += "action eq '$tiAction'"
        }

        # Filter by threat type
        if ($ThreatType) {
            $filters += "threatType eq '$ThreatType'"
        }

        # Build OData filter string
        $filterString = $filters -join ' and '
        Write-PhishIRLog -Message "Applying filter: $filterString" -Level Debug

        # Query indicators via Graph API
        Write-PhishIRLog -Message "Retrieving indicators from Graph Security API" -Level Info
        
        try {
            $uri = "https://graph.microsoft.com/beta/security/tiIndicators?`$filter=$filterString"
            $response = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
            
            if (-not $response.value) {
                Write-PhishIRLog -Message "No indicators found matching criteria" -Level Warning
                return @()
            }
            
            $indicators = $response.value
            Write-PhishIRLog -Message "Retrieved $($indicators.Count) indicator(s)" -Level Info
        }
        catch {
            Write-PhishIRLog -Message "Failed to query indicators: $_" -Level Error
            throw
        }

        # Filter by indicator type (client-side filtering since API doesn't support OR on multiple properties)
        if ($IndicatorType -ne 'All') {
            $indicators = $indicators | Where-Object {
                switch ($IndicatorType) {
                    'Url' { $_.url }
                    'DomainName' { $_.domainName }
                    'IpAddress' { $_.networkIPv4 -or $_.networkIPv6 }
                }
            }
            Write-PhishIRLog -Message "Filtered to $($indicators.Count) $IndicatorType indicator(s)" -Level Debug
        }
        else {
            # Only include URL/domain/IP indicators (exclude file hash, certificate, etc.)
            $indicators = $indicators | Where-Object {
                $_.url -or $_.domainName -or $_.networkIPv4 -or $_.networkIPv6
            }
        }

        # Filter expired indicators (unless ShowExpired is specified)
        if (-not $ShowExpired) {
            $now = Get-Date
            $indicators = $indicators | Where-Object {
                $expirationDate = [DateTime]::Parse($_.expirationDateTime)
                $expirationDate -gt $now
            }
            Write-PhishIRLog -Message "Filtered to $($indicators.Count) active (non-expired) indicator(s)" -Level Debug
        }

        # Format output
        if ($IncludeDetails) {
            # Full details view
            $output = $indicators | ForEach-Object {
                $indicatorValue = if ($_.url) { $_.url }
                                 elseif ($_.domainName) { $_.domainName }
                                 elseif ($_.networkIPv4) { $_.networkIPv4 }
                                 elseif ($_.networkIPv6) { $_.networkIPv6 }
                                 else { 'Unknown' }
                
                $indicatorType = if ($_.url) { 'Url' }
                                elseif ($_.domainName) { 'DomainName' }
                                elseif ($_.networkIPv4 -or $_.networkIPv6) { 'IpAddress' }
                                else { 'Other' }
                
                [PSCustomObject]@{
                    Id                 = $_.id
                    Type               = $indicatorType
                    Value              = $indicatorValue
                    Action             = $_.action
                    ThreatType         = $_.threatType
                    Description        = $_.description
                    Confidence         = $_.confidence
                    Severity           = $_.severity
                    ExpirationDateTime = $_.expirationDateTime
                    IsActive           = $_.isActive
                    Tags               = ($_.tags -join ', ')
                    IngestedDateTime   = $_.ingestedDateTime
                    AzureTenantId      = $_.azureTenantId
                }
            }
        }
        else {
            # Summary view
            $output = $indicators | ForEach-Object {
                $indicatorValue = if ($_.url) { $_.url }
                                 elseif ($_.domainName) { $_.domainName }
                                 elseif ($_.networkIPv4) { $_.networkIPv4 }
                                 elseif ($_.networkIPv6) { $_.networkIPv6 }
                                 else { 'Unknown' }
                
                $indicatorType = if ($_.url) { 'Url' }
                                elseif ($_.domainName) { 'DomainName' }
                                elseif ($_.networkIPv4 -or $_.networkIPv6) { 'IpAddress' }
                                else { 'Other' }
                
                [PSCustomObject]@{
                    Id                 = $_.id
                    Type               = $indicatorType
                    Value              = $indicatorValue
                    Action             = $_.action
                    ThreatType         = $_.threatType
                    Description        = $_.description
                    ExpirationDateTime = $_.expirationDateTime
                }
            }
        }

        # Display summary
        Write-Host "`n=== Defender URL/Domain Indicators Summary ===" -ForegroundColor Green
        Write-Host "Total indicators: $($output.Count)"
        
        if ($output.Count -gt 0) {
            $actionCounts = $output | Group-Object -Property Action | Select-Object Name, Count
            Write-Host "`nBy Action:" -ForegroundColor Cyan
            $actionCounts | ForEach-Object { Write-Host "  $($_.Name): $($_.Count)" }
            
            $typeCounts = $output | Group-Object -Property Type | Select-Object Name, Count
            Write-Host "`nBy Type:" -ForegroundColor Cyan
            $typeCounts | ForEach-Object { Write-Host "  $($_.Name): $($_.Count)" }
            
            if ($output.ThreatType) {
                $threatCounts = $output | Group-Object -Property ThreatType | Select-Object Name, Count
                Write-Host "`nBy Threat Type:" -ForegroundColor Cyan
                $threatCounts | ForEach-Object { Write-Host "  $($_.Name): $($_.Count)" }
            }
            
            # Check for expiring indicators
            $expiringCount = ($output | Where-Object { 
                [DateTime]::Parse($_.ExpirationDateTime) -lt (Get-Date).AddDays(7) 
            }).Count
            
            if ($expiringCount -gt 0) {
                Write-Host "`n⚠️  $expiringCount indicator(s) expiring within 7 days" -ForegroundColor Yellow
            }
        }

        return $output
    }
    catch {
        Write-PhishIRLog -Message "Error in Get-PhishIRDefenderIndicators: $_" -Level Error
        throw
    }
}
