function Add-PhishIRDefenderURLBlock {
    <#
    .SYNOPSIS
    Submit URL/domain block indicators to Microsoft Defender for Endpoint via Graph Security Threat Intelligence API.

    .DESCRIPTION
    Creates custom network indicators (threat intelligence indicators) to block malicious URLs or domains 
    at the endpoint level using Microsoft Defender for Endpoint. Indicators are enforced via Network Protection 
    and Windows Defender SmartScreen.
    
    This function uses the Microsoft Graph Security tiIndicator API to submit indicators that target 
    "Microsoft Defender ATP" (MDE). Indicators can block URLs, allow trusted domains, or warn users 
    before access.

    Actions performed:
    1. Connect to Microsoft Graph (if not connected)
    2. Validate URL/domain formats
    3. Submit tiIndicators to Graph Security API
    4. Return submission results with indicator IDs

    Prerequisites:
    - Microsoft.Graph.Beta.Security module
    - Graph API permission: ThreatIndicators.ReadWrite.OwnedBy
    - Network Protection enabled in Block mode (for enforcement)
    - Custom network indicators feature enabled in Defender portal (Settings > Endpoints > General > Advanced features)

    .PARAMETER Urls
    Array of URLs or domains to submit as indicators.
    
    URL formats supported:
    - Domains: example.com (blocks all subdomains including sub.example.com)
    - Full URLs: https://example.com/malicious/page (blocks specific URL path)
    - IP addresses: 203.0.113.42

    .PARAMETER Action
    Action to take when indicator is matched. Valid values:
    - Block (default): Block access to URL/domain
    - Allow: Allow access (whitelist trusted URLs)
    - Warn: Warn user before allowing access
    - Audit: Log event without blocking

    .PARAMETER ThreatType
    Type of threat represented by indicator. Valid values:
    - Phishing (default)
    - MaliciousUrl
    - Malware
    - C2
    - Botnet
    - DDoS
    - WatchList

    .PARAMETER ExpirationDays
    Number of days until indicator expires. Default is 90 days.
    Range: 1-365 days. All indicators must have an expiration to avoid stale indicators.

    .PARAMETER Description
    Brief description of the threat (max 100 characters).

    .PARAMETER Confidence
    Confidence level that indicator identifies malicious behavior. Range: 0-100 (default 80).

    .PARAMETER Severity
    Severity of malicious behavior. Range: 0-5 (default 3).
    - 0: Informational
    - 1-2: Low
    - 3: Medium (default)
    - 4: High
    - 5: Critical

    .PARAMETER CsvPath
    Path to CSV file containing URLs to block. CSV must have column named 'Url'.
    Optional columns: Action, ThreatType, Description, ExpirationDays

    .PARAMETER BlockConfirmation
    Required confirmation phrase for block/warn actions: "CONFIRM: Block URLs approved by [Name]"
    Not required for Allow or Audit actions, or when using -WhatIf.

    .PARAMETER WhatIf
    Shows what would happen without submitting indicators.

    .EXAMPLE
    Add-PhishIRDefenderURLBlock -Urls "malicious-domain.com", "phishing-site.net" -WhatIf

    Preview URL blocking without submitting indicators.

    .EXAMPLE
    Add-PhishIRDefenderURLBlock -Urls "evil.com" -Description "Invoice phishing campaign" -BlockConfirmation "CONFIRM: Block URLs approved by John Doe"

    Block a single domain with required confirmation.

    .EXAMPLE
    Add-PhishIRDefenderURLBlock -CsvPath ".\phishing-urls.csv" -ThreatType Phishing -ExpirationDays 30 -BlockConfirmation "CONFIRM: Block URLs approved by SOC Lead"

    Bulk import phishing URLs from CSV and block for 30 days.

    .EXAMPLE
    Add-PhishIRDefenderURLBlock -Urls "trusted-partner.com" -Action Allow -Description "Legitimate partner domain"

    Allow-list a trusted domain (no confirmation required).

    .EXAMPLE
    Add-PhishIRDefenderURLBlock -Urls "https://suspicious-site.com/download" -Action Warn -Description "Potentially unwanted software" -BlockConfirmation "CONFIRM: Block URLs approved by Admin"

    Create a warning prompt for a specific URL path.

    .NOTES
    Requires:
    - Microsoft.Graph.Beta.Security module: Install-Module Microsoft.Graph.Beta.Security
    - Connect-MgGraph -Scopes "ThreatIndicators.ReadWrite.OwnedBy"
    - Network Protection enabled in Block mode
    - Custom network indicators feature enabled in Defender portal
    
    Graph API endpoint: POST https://graph.microsoft.com/beta/security/tiIndicators/submitTiIndicators
    TargetProduct: Microsoft Defender ATP
    
    Indicator propagation: Up to 48 hours (typically under 2 hours)
    Enforcement: SmartScreen (Microsoft browsers) + Network Protection (non-Microsoft browsers)
    
    Policy conflict resolution: Allow > Warn > Block
    Example: If URL has both Allow and Block indicators, Allow takes precedence.

    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Urls')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Urls', ValueFromPipeline = $true)]
        [string[]]$Urls,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Block', 'Allow', 'Warn', 'Audit')]
        [string]$Action = 'Block',

        [Parameter(Mandatory = $false)]
        [ValidateSet('Phishing', 'MaliciousUrl', 'Malware', 'C2', 'Botnet', 'DDoS', 'CryptoMining', 'Darknet', 'Proxy', 'PUA', 'WatchList')]
        [string]$ThreatType = 'Phishing',

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 365)]
        [int]$ExpirationDays = 90,

        [Parameter(Mandatory = $false)]
        [ValidateLength(1, 100)]
        [string]$Description,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 100)]
        [int]$Confidence = 80,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 5)]
        [int]$Severity = 3,

        [Parameter(Mandatory = $true, ParameterSetName = 'Csv')]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$CsvPath,

        [Parameter(Mandatory = $false)]
        [string]$BlockConfirmation

        ,
        [Parameter(Mandatory = $false)]
        [switch]$LogIncident,

        [Parameter(Mandatory = $false)]
        [string]$IncidentApprovedBy,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0,5)]
        [int]$IncidentSeverity = $Severity,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$IncidentStatus = 'Submitted',

        [Parameter(Mandatory = $false)]
        [string]$IncidentNotes,

        [Parameter(Mandatory = $false)]
        [string[]]$IncidentTags = @('DefenderURLBlock'),

        [Parameter(Mandatory = $false)]
        [string]$CorrelationId,

        [Parameter(Mandatory = $false)]
        [string]$StorePath
    )

    begin {
        $ErrorActionPreference = 'Stop'
        $results = @{
            IndicatorsSubmitted = @()
            IndicatorIds        = @()
            Errors              = @()
        }

        # Safety check for Block/Warn actions
        if ($Action -in @('Block', 'Warn') -and -not $WhatIfPreference) {
            if (-not $BlockConfirmation -or $BlockConfirmation -notmatch '^CONFIRM:\s+Block URLs approved by\s+.+$') {
                throw "Block/Warn actions require -BlockConfirmation parameter with format: 'CONFIRM: Block URLs approved by [Name]'"
            }
            Write-PhishIRLog -Message "URL blocking confirmed: $BlockConfirmation" -Level Warning
        }

        # Check Microsoft Graph connection
        try {
            $context = Get-MgContext -ErrorAction Stop
            if (-not $context) {
                throw "Not connected to Microsoft Graph"
            }
            
            # Verify required permission
            $requiredScope = "ThreatIndicators.ReadWrite.OwnedBy"
            if ($context.Scopes -notcontains $requiredScope) {
                Write-Warning "Missing required Graph permission: $requiredScope"
                Write-Warning "Run: Connect-MgGraph -Scopes 'ThreatIndicators.ReadWrite.OwnedBy'"
                throw "Missing Graph API permission: $requiredScope"
            }
            
            Write-PhishIRLog -Message "Microsoft Graph connection verified (ThreatIndicators.ReadWrite.OwnedBy)" -Level Info
        }
        catch {
            Write-Warning "Not connected to Microsoft Graph or missing permissions"
            Write-Warning "Run: Connect-MgGraph -Scopes 'ThreatIndicators.ReadWrite.OwnedBy'"
            throw "Microsoft Graph connection required with ThreatIndicators.ReadWrite.OwnedBy permission"
        }

        # Import from CSV if specified
        if ($PSCmdlet.ParameterSetName -eq 'Csv') {
            Write-PhishIRLog -Message "Importing URLs from CSV: $CsvPath" -Level Info
            $csvData = Import-Csv -Path $CsvPath
            
            if (-not $csvData) {
                throw "CSV file is empty or could not be read: $CsvPath"
            }
            
            if (-not ($csvData[0].PSObject.Properties.Name -contains 'Url')) {
                throw "CSV must contain 'Url' column. Found columns: $($csvData[0].PSObject.Properties.Name -join ', ')"
            }
            
            $Urls = $csvData | ForEach-Object { $_.Url }
            Write-PhishIRLog -Message "Loaded $($Urls.Count) URLs from CSV" -Level Info
            
            # Override parameters from CSV if provided
            if ($csvData[0].PSObject.Properties.Name -contains 'Action' -and $csvData[0].Action) {
                $Action = $csvData[0].Action
            }
            if ($csvData[0].PSObject.Properties.Name -contains 'ThreatType' -and $csvData[0].ThreatType) {
                $ThreatType = $csvData[0].ThreatType
            }
            if ($csvData[0].PSObject.Properties.Name -contains 'Description' -and $csvData[0].Description) {
                $Description = $csvData[0].Description
            }
            if ($csvData[0].PSObject.Properties.Name -contains 'ExpirationDays' -and $csvData[0].ExpirationDays) {
                $ExpirationDays = [int]$csvData[0].ExpirationDays
            }
        }

        Write-PhishIRLog -Message "Preparing to submit $($Urls.Count) URL indicator(s) with Action=$Action, ThreatType=$ThreatType" -Level Info
    }

    process {
        try {
            # Normalize and validate URLs first
            $validatedUrls = @()
            $skippedDuplicates = @()
            
            foreach ($url in $Urls) {
                # Normalize URL
                $normalized = ConvertTo-PhishIRNormalizedUrl -Url $url
                
                if (-not $normalized.IsValid) {
                    Write-Warning "Skipping invalid URL: $url - $($normalized.Warnings -join ', ')"
                    $results.Errors += "Invalid URL: $url"
                    continue
                }
                
                # Display warnings for high-risk URLs
                if ($normalized.RiskScore -ge 2) {
                    Write-Warning "High-risk URL detected: $($normalized.NormalizedUrl) (Score: $($normalized.RiskScore))"
                    if ($normalized.Warnings.Count -gt 0) {
                        Write-Warning "  Warnings: $($normalized.Warnings -join ', ')"
                    }
                }
                
                # Check for duplicates (skip if active indicator exists)
                if (Test-PhishIRDuplicateIndicator -Url $normalized.NormalizedUrl -Action $Action) {
                    Write-Host "⊗ Skipping duplicate: $($normalized.NormalizedUrl) (active indicator exists)" -ForegroundColor Yellow
                    $skippedDuplicates += $normalized.NormalizedUrl
                    continue
                }
                
                $validatedUrls += [PSCustomObject]@{
                    Original = $url
                    Normalized = $normalized.NormalizedUrl
                    RiskScore = $normalized.RiskScore
                    Warnings = $normalized.Warnings
                }
            }
            
            if ($validatedUrls.Count -eq 0) {
                Write-Warning "No valid URLs to submit after validation and deduplication"
                if ($skippedDuplicates.Count -gt 0) {
                    Write-Host "`nSkipped $($skippedDuplicates.Count) duplicate(s):" -ForegroundColor Cyan
                    $skippedDuplicates | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
                }
                return $results
            }
            
            Write-PhishIRLog -Message "Validated $($validatedUrls.Count) URLs (skipped $($skippedDuplicates.Count) duplicates)" -Level Info

            # Build tiIndicator objects
            $tiIndicators = @()
            $expirationDateTime = (Get-Date).AddDays($ExpirationDays).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            
            foreach ($urlObj in $validatedUrls) {
                $url = $urlObj.Normalized
                
                # Validate and parse URL/domain
                $isIpAddress = $false
                $isFullUrl = $false
                
                # Check if IP address (IPv4)
                if ($url -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
                    $isIpAddress = $true
                    Write-PhishIRLog -Message "Detected IP address: $url" -Level Debug
                }
                # Check if full URL (http/https)
                elseif ($url -match '^https?://') {
                    $isFullUrl = $true
                    Write-PhishIRLog -Message "Detected full URL: $url" -Level Debug
                }
                # Otherwise treat as domain
                else {
                    Write-PhishIRLog -Message "Detected domain: $url" -Level Debug
                }

                # Build indicator description
                $indicatorDescription = if ($Description) {
                    $Description
                } else {
                    "PhishIR: $ThreatType threat indicator"
                }

                # Truncate description to 100 characters (Graph API requirement)
                if ($indicatorDescription.Length -gt 100) {
                    $indicatorDescription = $indicatorDescription.Substring(0, 97) + "..."
                }

                # Map Action to tiAction enum
                $tiAction = switch ($Action) {
                    'Block' { 'block' }
                    'Allow' { 'allow' }
                    'Warn' { 'warn' }
                    'Audit' { 'alert' }
                }

                # Build tiIndicator object
                $tiIndicator = @{
                    Action              = $tiAction
                    Description         = $indicatorDescription
                    ExpirationDateTime  = $expirationDateTime
                    TargetProduct       = 'Microsoft Defender ATP'
                    ThreatType          = $ThreatType
                    TlpLevel            = 'amber'  # Traffic Light Protocol: Amber (limited distribution)
                    Confidence          = $Confidence
                    Severity            = $Severity
                    Tags                = @('PhishIR', 'AutoGenerated', $ThreatType)
                }

                # Add URL/Domain/IP specific properties
                if ($isIpAddress) {
                    $tiIndicator.NetworkIPv4 = $url
                }
                elseif ($isFullUrl) {
                    $tiIndicator.Url = $url
                }
                else {
                    $tiIndicator.DomainName = $url
                }

                $tiIndicators += $tiIndicator
            }

            # WhatIf preview
            if ($WhatIfPreference) {
                Write-Host "`n=== WhatIf: Would submit $($tiIndicators.Count) URL indicators ===" -ForegroundColor Cyan
                foreach ($indicator in $tiIndicators) {
                    $targetValue = if ($indicator.NetworkIPv4) { "IP: $($indicator.NetworkIPv4)" }
                                   elseif ($indicator.Url) { "URL: $($indicator.Url)" }
                                   else { "Domain: $($indicator.DomainName)" }
                    
                    Write-Host "  $targetValue" -ForegroundColor Yellow
                    Write-Host "    Action: $($indicator.Action)" -ForegroundColor Gray
                    Write-Host "    ThreatType: $($indicator.ThreatType)" -ForegroundColor Gray
                    Write-Host "    Expires: $($indicator.ExpirationDateTime)" -ForegroundColor Gray
                    Write-Host "    Description: $($indicator.Description)" -ForegroundColor Gray
                }
                Write-Host "`nNo changes made (WhatIf)" -ForegroundColor Green
                return $results
            }

            # Submit indicators via Graph API with retry logic
            Write-PhishIRLog -Message "Submitting $($tiIndicators.Count) indicator(s) to Microsoft Graph Security API" -Level Info
            
            if ($PSCmdlet.ShouldProcess("$($tiIndicators.Count) URL indicator(s)", "Submit to Defender for Endpoint")) {
                try {
                    # Submit with automatic retry on throttling/server errors
                    $submissionResult = Invoke-PhishIRGraphRetry -ScriptBlock {
                        Submit-MgBetaSecurityTiIndicator -Value $tiIndicators -ErrorAction Stop
                    } -MaxRetries 3 -InitialDelaySeconds 2
                    
                    # Extract indicator IDs from response
                    if ($submissionResult.Value) {
                        foreach ($submittedIndicator in $submissionResult.Value) {
                            $results.IndicatorIds += $submittedIndicator.Id
                            $results.IndicatorsSubmitted += $submittedIndicator
                        }
                    }
                    
                    Write-PhishIRLog -Message "Successfully submitted $($tiIndicators.Count) indicator(s)" -Level Success
                    Write-Host "`n=== URL Indicators Submitted ===" -ForegroundColor Green
                    Write-Host "Count: $($results.IndicatorIds.Count)"
                    Write-Host "Action: $Action"
                    Write-Host "ThreatType: $ThreatType"
                    Write-Host "Expiration: $ExpirationDays days"
                    Write-Host "`nIndicator IDs:" -ForegroundColor Cyan
                    $results.IndicatorIds | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
                    
                    Write-Host "`n=== Important Notes ===" -ForegroundColor Yellow
                    Write-Host "• Indicators propagate to endpoints within 2-48 hours (typically < 2 hours)"
                    Write-Host "• Enforcement requires Network Protection enabled in Block mode"
                    Write-Host "• Verify indicators in Defender portal: Settings > Endpoints > Indicators"
                    Write-Host "• Domain indicators block all subdomains (e.g., example.com blocks sub.example.com)"
                    Write-Host "• Policy precedence: Allow > Warn > Block"

                    # Optional incident logging
                    if ($LogIncident) {
                        $incidentActions = @{ IndicatorsSubmitted = $results.IndicatorIds.Count; Action = $Action; ThreatType = $ThreatType }
                        try {
                            Add-PhishIRIncidentRecord -IncidentType 'DefenderURLBlock' -ExtractedUrls $Urls -Actions $incidentActions -CorrelationId $CorrelationId -ApprovedBy $IncidentApprovedBy -Severity $IncidentSeverity -Status $IncidentStatus -Notes $IncidentNotes -Tags ($IncidentTags + 'PhishIR') -StorePath $StorePath -PassThru:$false -ErrorAction Stop | Out-Null
                            Write-Host " Incident record logged (DefenderURLBlock)" -ForegroundColor Green
                        }
                        catch {
                            Write-Warning "Incident logging failed: $($_.Exception.Message)"
                        }
                    }
                }
                catch {
                    $errMsg = $_.Exception.Message
                    $results.Errors += "Failed to submit indicators: $errMsg"
                    Write-PhishIRLog -Message "Failed to submit indicators: $errMsg" -Level Error
                    throw
                }
            }

            return $results
        }
        catch {
            $results.Errors += $_.Exception.Message
            Write-PhishIRLog -Message "Error in Add-PhishIRDefenderURLBlock: $_" -Level Error
            throw
        }
    }

    end {
        if ($results.Errors.Count -gt 0) {
            Write-Warning "Completed with $($results.Errors.Count) error(s)"
            Write-Host "`nErrors:" -ForegroundColor Red
            foreach ($err in $results.Errors) { Write-Host "  $err" -ForegroundColor Red }
        }
    }
}



