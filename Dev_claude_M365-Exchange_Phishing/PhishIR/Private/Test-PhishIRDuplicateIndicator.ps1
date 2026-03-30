function Test-PhishIRDuplicateIndicator {
    <#
    .SYNOPSIS
    Check if URL/domain/IP indicator already exists in active Defender indicators.

    .DESCRIPTION
    Queries Microsoft Graph Security tiIndicators to verify if an active (non-expired)
    indicator matching the provided URL/domain/IP already exists. Prevents duplicate
    submissions and quota exhaustion.

    Returns $true if duplicate exists, $false otherwise.

    .PARAMETER Url
    URL, domain, or IP address to check for duplicates.

    .PARAMETER Action
    Action type to match (Block, Allow, Warn, Audit). Default checks all actions.

    .EXAMPLE
    Test-PhishIRDuplicateIndicator -Url "malicious.com"
    
    Returns $true if active indicator exists for malicious.com.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter()]
        [ValidateSet('Block', 'Allow', 'Warn', 'Audit', 'All')]
        [string]$Action = 'All'
    )

    try {
        # Normalize URL for comparison
        $normalizedUrl = $Url.ToLower().Trim()
        
        # Map action to tiAction enum
        $tiAction = switch ($Action) {
            'Block' { 'block' }
            'Allow' { 'allow' }
            'Warn' { 'warn' }
            'Audit' { 'alert' }
            'All' { $null }
        }

        # Build filter for active indicators (not expired)
        $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        $filter = "expirationDateTime gt $now and targetProduct eq 'Microsoft Defender ATP'"

        # Query existing indicators
        $existingIndicators = Get-MgBetaSecurityTiIndicator -Filter $filter -All -ErrorAction Stop

        # Check for matches
        foreach ($indicator in $existingIndicators) {
            $match = $false

            # Check URL match
            if ($indicator.Url -and $indicator.Url.ToLower() -eq $normalizedUrl) {
                $match = $true
            }
            # Check domain match
            elseif ($indicator.DomainName -and $indicator.DomainName.ToLower() -eq $normalizedUrl) {
                $match = $true
            }
            # Check IP match
            elseif ($indicator.NetworkIPv4 -and $indicator.NetworkIPv4 -eq $normalizedUrl) {
                $match = $true
            }

            # If URL/domain/IP matches, check action if specified
            if ($match) {
                if ($tiAction -and $indicator.Action -ne $tiAction) {
                    continue
                }
                
                Write-Verbose "Duplicate indicator found: $($indicator.Id) (Action: $($indicator.Action), Expires: $($indicator.ExpirationDateTime))"
                return $true
            }
        }

        return $false

    } catch {
        Write-Warning "Failed to check for duplicate indicators: $_"
        # On error, assume no duplicate to avoid blocking legitimate operations
        return $false
    }
}
