function Hide-FinOpsSensitiveData {
    <#
    .SYNOPSIS
        Masks sensitive data in strings for safe logging.
    
    .DESCRIPTION
        Automatically detects and masks common sensitive patterns including:
        - Email addresses
        - GUIDs (tenant IDs, subscription IDs)
        - JWT tokens
        - IP addresses
        - API keys (common patterns)
        - Bearer tokens
        
        Used internally to protect sensitive data in logs, reports, and output.
    
    .PARAMETER Text
        Text to scan and mask for sensitive data.
    
    .PARAMETER MaskChar
        Character to use for masking. Default is '*'.
    
    .PARAMETER PreserveLength
        If set, preserves the length of masked data. Otherwise uses fixed-length masks.
    
    .EXAMPLE
        Hide-FinOpsSensitiveData -Text 'Contact: user@company.com for tenant 12345678-1234-1234-1234-123456789012'
        # Returns: 'Contact: ***@***.*** for tenant ********-****-****-****-************'
    
    .EXAMPLE
        $logMessage = "Bearer token: eyJhbGci... for API call"
        $masked = Hide-FinOpsSensitiveData -Text $logMessage
        # Returns: "Bearer token: ***TOKEN*** for API call"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [string]$Text,
        
        [Parameter()]
        [char]$MaskChar = '*',
        
        [Parameter()]
        [switch]$PreserveLength
    )
    
    process {
        if ([string]::IsNullOrEmpty($Text)) {
            return $Text
        }
        
        $masked = $Text
        
        # Email addresses - mask username and domain but keep structure
        $masked = $masked -replace '([\w\.-]+)@([\w\.-]+)\.(\w+)', "$MaskChar$MaskChar$MaskChar@$MaskChar$MaskChar$MaskChar.$MaskChar$MaskChar$MaskChar"
        
        # GUID-like strings (tenant IDs, subscription IDs, object IDs)
        # Format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
        if ($PreserveLength) {
            $masked = $masked -replace '\b[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\b', {
                param($match)
                ($MaskChar.ToString() * 8) + '-' + ($MaskChar.ToString() * 4) + '-' + ($MaskChar.ToString() * 4) + '-' + ($MaskChar.ToString() * 4) + '-' + ($MaskChar.ToString() * 12)
            }
        }
        else {
            $masked = $masked -replace '\b[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\b', '********-****-****-****-************'
        }
        
        # JWT tokens (starts with eyJ - Base64 encoded JSON header)
        $masked = $masked -replace '\beyJ[A-Za-z0-9_-]*\.eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*\b', "$MaskChar$MaskChar${MaskChar}JWT_TOKEN$MaskChar$MaskChar$MaskChar"
        
        # Bearer tokens in Authorization headers
        $masked = $masked -replace '(Bearer\s+)[A-Za-z0-9\-\._~\+\/]+=*', "`$1$MaskChar$MaskChar${MaskChar}TOKEN$MaskChar$MaskChar$MaskChar"
        
        # IPv4 addresses
        $masked = $masked -replace '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b', "$MaskChar.$MaskChar.$MaskChar.$MaskChar"
        
        # Common API key patterns
        # Azure Storage Account keys (Base64, 88 chars)
        $masked = $masked -replace '\b[A-Za-z0-9+/]{86}==\b', "$MaskChar$MaskChar${MaskChar}STORAGE_KEY$MaskChar$MaskChar$MaskChar"
        
        # Generic long Base64 strings that might be keys (40+ chars)
        $masked = $masked -replace '\b[A-Za-z0-9+/]{40,}={0,2}\b', "$MaskChar$MaskChar${MaskChar}KEY$MaskChar$MaskChar$MaskChar"
        
        # Passwords in URLs or connection strings
        $masked = $masked -replace '(password|pwd|pass)=[^;&\s]+', "`$1=$MaskChar$MaskChar$MaskChar$MaskChar$MaskChar$MaskChar"
        
        # Secrets in URLs or connection strings
        $masked = $masked -replace '(secret|key|token)=[^;&\s]+', "`$1=$MaskChar$MaskChar$MaskChar$MaskChar$MaskChar$MaskChar"
        
        # SAS tokens (Azure Storage)
        $masked = $masked -replace '\?sv=\d{4}-\d{2}-\d{2}[^"''\s]*', "?sv=****-**-**&sig=$MaskChar$MaskChar${MaskChar}SAS_TOKEN$MaskChar$MaskChar$MaskChar"
        
        return $masked
    }
}

function Test-FinOpsSensitiveData {
    <#
    .SYNOPSIS
        Tests if text contains sensitive data patterns.
    
    .DESCRIPTION
        Scans text for common sensitive data patterns without masking.
        Returns true if sensitive data is detected.
    
    .PARAMETER Text
        Text to scan for sensitive data.
    
    .EXAMPLE
        if (Test-FinOpsSensitiveData -Text $logMessage) {
            $logMessage = Hide-FinOpsSensitiveData -Text $logMessage
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [string]$Text
    )
    
    process {
        if ([string]::IsNullOrEmpty($Text)) {
            return $false
        }
        
        # Check for various sensitive patterns
        $patterns = @(
            '[\w\.-]+@[\w\.-]+\.\w+',                                      # Email
            '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}', # GUID
            'eyJ[A-Za-z0-9_-]*\.eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*',        # JWT
            'Bearer\s+[A-Za-z0-9\-\._~\+\/]+=*',                            # Bearer token
            '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}',                          # IP address
            '[A-Za-z0-9+/]{40,}={0,2}',                                    # Long Base64 (keys)
            '(password|pwd|pass|secret|key|token)=[^;&\s]+',               # Credentials in strings
            '\?sv=\d{4}-\d{2}-\d{2}'                                       # SAS token
        )
        
        foreach ($pattern in $patterns) {
            if ($Text -match $pattern) {
                return $true
            }
        }
        
        return $false
    }
}
