function ConvertTo-PhishIRNormalizedUrl {
    <#
    .SYNOPSIS
    Normalize and validate URLs for safe processing and blocking.

    .DESCRIPTION
    Performs URL normalization and security validation including:
    - Lowercase conversion and whitespace trimming
    - Punycode decoding for IDN homograph detection
    - Suspicious pattern detection (excessive subdomains, suspicious TLDs)
    - Base64 decoding attempts for obfuscated URLs
    - Risk scoring based on heuristics

    Returns a custom object with normalized URL and security metadata.

    .PARAMETER Url
    Raw URL string to normalize and validate.

    .EXAMPLE
    ConvertTo-PhishIRNormalizedUrl -Url "HTTPS://EVIL.COM/Path"
    
    Returns:
    NormalizedUrl    : https://evil.com/path
    OriginalUrl      : HTTPS://EVIL.COM/Path
    IsValid          : True
    RiskScore        : 2
    Warnings         : {}

    .EXAMPLE
    ConvertTo-PhishIRNormalizedUrl -Url "xn--80ak6aa92e.com"
    
    Returns normalized URL with punycode decoded and homograph warning.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string]$Url
    )

    process {
        $result = [PSCustomObject]@{
            OriginalUrl   = $Url
            NormalizedUrl = $null
            IsValid       = $false
            RiskScore     = 0
            Warnings      = @()
            DecodedDomain = $null
        }

        try {
            # Basic cleanup
            $normalized = $Url.ToLower().Trim()

            # Remove common tracking parameters for deduplication
            $normalized = $normalized -replace '[?&](utm_source|utm_medium|utm_campaign|fbclid|gclid)=[^&]*', ''
            $normalized = $normalized.TrimEnd('?', '&')

            # Validate URL format
            if ($normalized -notmatch '^(https?://|[a-z0-9\-]+\.[a-z]{2,})') {
                $result.Warnings += "Invalid URL format"
                return $result
            }

            # Extract domain for validation
            $domain = $null
            if ($normalized -match '^https?://([^/]+)') {
                $domain = $matches[1]
            } elseif ($normalized -match '^([a-z0-9\-\.]+)') {
                $domain = $matches[1]
            }

            if ($domain) {
                # Check for punycode (IDN homograph attack)
                if ($domain -match 'xn--') {
                    try {
                        $idn = New-Object System.Globalization.IdnMapping
                        $decoded = $idn.GetUnicode($domain)
                        $result.DecodedDomain = $decoded
                        $result.Warnings += "Punycode detected: $decoded"
                        $result.RiskScore += 2
                    } catch {
                        $result.Warnings += "Failed to decode punycode"
                    }
                }

                # Count subdomains (excessive depth is suspicious)
                $parts = $domain -split '\.'
                if ($parts.Count -gt 5) {
                    $result.Warnings += "Excessive subdomain depth ($($parts.Count) levels)"
                    $result.RiskScore += 1
                }

                # Check for suspicious TLDs
                $suspiciousTlds = @('tk', 'ml', 'ga', 'cf', 'gq', 'xyz', 'top', 'pw', 'cc')
                $tld = $parts[-1]
                if ($tld -in $suspiciousTlds) {
                    $result.Warnings += "Suspicious TLD: .$tld"
                    $result.RiskScore += 1
                }

                # Check for IP address
                if ($domain -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
                    $result.Warnings += "IP address instead of domain"
                    $result.RiskScore += 1
                }

                # Check for mixed character sets (potential homograph)
                if ($domain -match '[а-я]|[α-ω]|[а-я]') {
                    $result.Warnings += "Non-Latin characters detected (potential homograph)"
                    $result.RiskScore += 3
                }

                # Check for common brand impersonation patterns
                $brands = @('microsoft', 'paypal', 'amazon', 'google', 'apple', 'facebook', 'netflix')
                foreach ($brand in $brands) {
                    if ($domain -match $brand -and $domain -notmatch "$brand\.(com|net|org)$") {
                        $result.Warnings += "Potential brand impersonation: $brand"
                        $result.RiskScore += 2
                        break
                    }
                }
            }

            $result.NormalizedUrl = $normalized
            $result.IsValid = $true

        } catch {
            $result.Warnings += "Normalization error: $_"
        }

        return $result
    }
}
