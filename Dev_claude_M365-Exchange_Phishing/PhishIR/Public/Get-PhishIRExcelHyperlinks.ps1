function Get-PhishIRExcelHyperlinks {
    <#
    .SYNOPSIS
    Extract hyperlinks from Excel files (.xlsx) to identify malicious URLs for blocking.

    .DESCRIPTION
    Analyzes Excel files (.xlsx format) to extract all hyperlinks, including:
    - Cell hyperlinks (HYPERLINK formulas)
    - External relationships (hyperlink rels in .xlsx.rels files)
    - Embedded objects with URLs

    This function is designed for incident response workflows where malicious Excel attachments
    contain phishing URLs that need to be extracted and blocked at the network/endpoint level.

    Prerequisites:
    - .xlsx files only (Office Open XML format)
    - Files must be unencrypted
    - No Office/Excel installation required (uses ZIP extraction)

    .PARAMETER FilePath
    Path to Excel file (.xlsx) to analyze. Can be a single file or array of files.
    Accepts pipeline input from Get-ChildItem or Get-PhishIRMacroHunt.

    .PARAMETER IncludeInternal
    Include internal links (e.g., links to other sheets within the workbook).
    Default: only external URLs are returned.

    .PARAMETER ExportCsv
    Export results to CSV file for further processing or bulk URL blocking.

    .PARAMETER BlockImmediately
    Immediately submit extracted URLs to Defender for Endpoint blocking (requires confirmation).
    Uses Add-PhishIRDefenderURLBlock with safety rails.

    .PARAMETER BlockConfirmation
    Required confirmation phrase when using -BlockImmediately.
    Format: "CONFIRM: Block URLs approved by [Name]"

    .EXAMPLE
    Get-PhishIRExcelHyperlinks -FilePath ".\suspicious-invoice.xlsx"

    Extract all external hyperlinks from Excel file.

    Output:
    FileName        : suspicious-invoice.xlsx
    LinkType        : ExternalRelationship
    Url             : https://malicious-site.com/payload.svg
    SheetName       : Sheet1
    CellReference   : A1
    LinkText        : Click here for invoice

    .EXAMPLE
    Get-ChildItem "C:\QuarantinedEmails\*.xlsx" | Get-PhishIRExcelHyperlinks -ExportCsv ".\extracted-urls.csv"

    Extract hyperlinks from all Excel files in quarantine folder and export to CSV.

    .EXAMPLE
    Get-PhishIRExcelHyperlinks -FilePath ".\phishing.xlsx" -BlockImmediately -BlockConfirmation "CONFIRM: Block URLs approved by SOC Lead"

    Extract URLs and immediately block them in Defender for Endpoint (requires Graph connection).

    .EXAMPLE
    # Combined workflow: Hunt for macro emails, download attachments, extract URLs, block
    $macroHunt = Get-PhishIRMacroHunt -QueryType EmailAttachment -TimeRange "7d"
    $urls = $macroHunt | ForEach-Object {
        Get-PhishIRExcelHyperlinks -FilePath $_.AttachmentPath
    }
    $urls | Select-Object -Unique Url | Export-Csv ".\campaign-urls.csv" -NoTypeInformation

    .EXAMPLE
    Get-PhishIRExcelHyperlinks -FilePath ".\invoice.xlsx" -IncludeInternal

    Extract all hyperlinks including internal sheet references.

    .EXAMPLE
    # Track recipients and check sign-in activity
    $recipients = @("user1@contoso.com", "user2@contoso.com")
    Get-PhishIRExcelHyperlinks -FilePath ".\phishing.xlsx" -Recipients $recipients -CheckSignIns -SignInDaysBack 7

    Extract URLs and check if any recipients had suspicious sign-ins after delivery.

    .NOTES
    Requires:
    - PowerShell 5.1+
    - .NET Framework (for ZIP extraction)
    - Microsoft.Graph.Authentication (for sign-in history tracking)

    Excel .xlsx file structure:
    - .xlsx files are ZIP archives containing XML files
    - Hyperlinks stored in xl/worksheets/_rels/sheet1.xml.rels (external relationships)
    - Cell formulas stored in xl/worksheets/sheet1.xml (HYPERLINK functions)

    Security considerations:
    - Does NOT open Excel files (no macro execution risk)
    - Safe to analyze malicious files (static ZIP extraction only)
    - Extracts URLs without triggering any payload downloads

    Common use cases:
    - Invoice phishing campaigns with malicious hyperlinks
    - Excel files with external content loading (SVG, HTML, etc.)
    - Suspicious files from email quarantine
    - Threat intelligence URL extraction from samples

    .LINK
    Add-PhishIRDefenderURLBlock
    Get-PhishIRMacroHunt
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'Path', 'AttachmentPath')]
        [ValidateScript({
            if (-not (Test-Path $_)) {
                throw "File not found: $_"
            }
            if ($_ -notmatch '\.xlsx$') {
                throw "File must be .xlsx format (Office Open XML). Got: $_"
            }
            $true
        })]
        [string[]]$FilePath,

        [Parameter()]
        [switch]$IncludeInternal,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$ExportCsv,

        [Parameter()]
        [switch]$BlockImmediately,

        [Parameter()]
        [ValidatePattern('^CONFIRM:\s+Block URLs approved by\s+.+$')]
        [string]$BlockConfirmation,

        [Parameter()]
        [switch]$LogIncident,

        [Parameter(Mandatory = $false)]
        [string]$IncidentApprovedBy,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0,5)]
        [int]$IncidentSeverity = 3,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$IncidentStatus = 'Extracted',

        [Parameter(Mandatory = $false)]
        [string]$IncidentNotes,

        [Parameter(Mandatory = $false)]
        [string[]]$IncidentTags = @('ExcelHyperlinkExtraction'),

        [Parameter(Mandatory = $false)]
        [string]$StorePath,

        [Parameter(Mandatory = $false)]
        [Alias('EmailRecipients', 'RecipientEmailAddress', 'TargetUsers')]
        [string[]]$Recipients,

        [Parameter(Mandatory = $false)]
        [switch]$CheckSignIns,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 30)]
        [int]$SignInDaysBack = 7,

        [Parameter(Mandatory = $false)]
        [string]$EmailSubject,

        [Parameter(Mandatory = $false)]
        [datetime]$EmailDeliveryTime
    )

    begin {
        Write-Verbose "Starting Excel hyperlink extraction"

        # Safety validation for immediate blocking
        if ($BlockImmediately -and -not $BlockConfirmation) {
            throw "BlockImmediately requires BlockConfirmation parameter. Format: 'CONFIRM: Block URLs approved by [Name]'"
        }

        # Check if Add-PhishIRDefenderURLBlock is available when blocking
        if ($BlockImmediately) {
            if (-not (Get-Command Add-PhishIRDefenderURLBlock -ErrorAction SilentlyContinue)) {
                throw "Add-PhishIRDefenderURLBlock function not available. Ensure PhishIR module is loaded."
            }
        }

        $allResults = @()
        $allUrls = @()

        # Helper function: Extract URLs from XML content
        function Get-PhishIRUrlsFromXml {
            param([string]$XmlContent, [string]$SheetName)

            $urls = @()

            # Parse relationships XML (external links in .rels files)
            if ($XmlContent -match '<Relationships') {
                try {
                    [xml]$xml = $XmlContent
                    $relationships = $xml.Relationships.Relationship | Where-Object {
                        $_.Type -match 'hyperlink|externalLink' -and $_.TargetMode -eq 'External'
                    }

                    foreach ($rel in $relationships) {
                        if ($rel.Target) {
                            $urls += [PSCustomObject]@{
                                LinkType = 'ExternalRelationship'
                                Url = $rel.Target
                                SheetName = $SheetName
                                RelationshipId = $rel.Id
                            }
                        }
                    }
                } catch {
                    Write-Warning "Failed to parse relationships XML: $_"
                }
            }

            # Parse worksheet XML (HYPERLINK formulas)
            if ($XmlContent -match '<worksheet') {
                try {
                    [xml]$xml = $XmlContent

                    # Find cells with formulas containing HYPERLINK
                    $cells = $xml.worksheet.sheetData.row.c | Where-Object {
                        $_.f -and $_.f.'#text' -match 'HYPERLINK\s*\('
                    }

                    foreach ($cell in $cells) {
                        $formula = $cell.f.'#text'
                        # Extract URL from HYPERLINK("url","text") formula
                        if ($formula -match 'HYPERLINK\s*\(\s*"([^"]+)"') {
                            $url = $matches[1]

                            # Skip internal references unless requested
                            if (-not $IncludeInternal -and $url -match '^#') {
                                continue
                            }

                            $urls += [PSCustomObject]@{
                                LinkType = 'HyperlinkFormula'
                                Url = $url
                                SheetName = $SheetName
                                CellReference = $cell.r
                            }
                        }
                    }
                } catch {
                    Write-Warning "Failed to parse worksheet XML: $_"
                }
            }

            return $urls
        }
    }

    process {
        foreach ($file in $FilePath) {
            Write-Verbose "Analyzing file: $file"

            $fileInfo = Get-Item $file
            $fileName = $fileInfo.Name
            $fileResults = @()

            try {
                # Create temporary extraction directory
                $tempDir = Join-Path $env:TEMP "PhishIR_Excel_$(Get-Random)"
                New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

                # Detect encryption before extraction attempt
                $fileBytes = [System.IO.File]::ReadAllBytes($file)
                $isEncrypted = $false
                
                # Check for Office encryption signatures
                # Encrypted files start with D0CF11E0 (OLE/CFB) instead of PK (ZIP)
                if ($fileBytes.Length -ge 4) {
                    $header = [System.BitConverter]::ToString($fileBytes[0..3]) -replace '-', ''
                    if ($header -eq 'D0CF11E0') {
                        $isEncrypted = $true
                        Write-Warning "File appears to be encrypted: $fileName"
                        Write-Host "⚠ Encrypted workbook detected: $fileName" -ForegroundColor Yellow
                        Write-Host "  Status: Requires manual password decryption" -ForegroundColor Yellow
                        
                        # Log as special case needing manual intervention
                        if ($LogIncident) {
                            $incidentActions = @{ Status = 'NeedsDecryption'; Encrypted = $true }
                            try {
                                Add-PhishIRIncidentRecord -IncidentType 'ExcelHyperlinkExtraction' -SourceFiles @($file) -Actions $incidentActions -Status 'NeedsDecryption' -Notes "Encrypted workbook requires manual password decryption" -Tags ($IncidentTags + 'Encrypted', 'ManualReview') -StorePath $StorePath -PassThru:$false -ErrorAction Stop | Out-Null
                            } catch {
                                Write-Warning "Incident logging failed: $_"
                            }
                        }
                        
                        continue  # Skip to next file
                    }
                }

                # Extract .xlsx (ZIP archive) to temp directory
                try {
                    Add-Type -AssemblyName System.IO.Compression.FileSystem
                    [System.IO.Compression.ZipFile]::ExtractToDirectory($file, $tempDir)
                    Write-Verbose "Extracted $fileName to $tempDir"
                } catch {
                    if ($_.Exception.Message -match 'password|encrypted|protected') {
                        Write-Warning "File is password-protected: $fileName"
                        Write-Host "⚠ Password-protected file detected: $fileName" -ForegroundColor Yellow
                        continue
                    }
                    throw "Failed to extract .xlsx file. File may be corrupted: $_"
                }

                # Process all worksheet relationships
                $relsDir = Join-Path $tempDir "xl\worksheets\_rels"
                if (Test-Path $relsDir) {
                    $relsFiles = Get-ChildItem -Path $relsDir -Filter "*.rels"

                    foreach ($relsFile in $relsFiles) {
                        # Extract sheet name from filename (sheet1.xml.rels -> Sheet1)
                        $sheetName = $relsFile.BaseName -replace '\.xml$', ''

                        $xmlContent = Get-Content -Path $relsFile.FullName -Raw
                        $extractedUrls = Get-PhishIRUrlsFromXml -XmlContent $xmlContent -SheetName $sheetName

                        foreach ($urlObj in $extractedUrls) {
                            $fileResults += [PSCustomObject]@{
                                FileName = $fileName
                                FilePath = $fileInfo.FullName
                                LinkType = $urlObj.LinkType
                                Url = $urlObj.Url
                                SheetName = $urlObj.SheetName
                                CellReference = $urlObj.CellReference
                                RelationshipId = $urlObj.RelationshipId
                                ExtractedAt = Get-Date
                            }
                        }
                    }
                }

                # Process worksheet XML files for HYPERLINK formulas
                $worksheetsDir = Join-Path $tempDir "xl\worksheets"
                if (Test-Path $worksheetsDir) {
                    $worksheetFiles = Get-ChildItem -Path $worksheetsDir -Filter "*.xml" -Exclude "*_rels"

                    foreach ($worksheet in $worksheetFiles) {
                        $sheetName = $worksheet.BaseName

                        $xmlContent = Get-Content -Path $worksheet.FullName -Raw
                        $extractedUrls = Get-PhishIRUrlsFromXml -XmlContent $xmlContent -SheetName $sheetName

                        foreach ($urlObj in $extractedUrls) {
                            # Skip if URL already found in relationships (avoid duplicates)
                            if ($fileResults | Where-Object { $_.Url -eq $urlObj.Url -and $_.SheetName -eq $urlObj.SheetName }) {
                                continue
                            }

                            $fileResults += [PSCustomObject]@{
                                FileName = $fileName
                                FilePath = $fileInfo.FullName
                                LinkType = $urlObj.LinkType
                                Url = $urlObj.Url
                                SheetName = $urlObj.SheetName
                                CellReference = $urlObj.CellReference
                                RelationshipId = $null
                                ExtractedAt = Get-Date
                            }
                        }
                    }
                }

                # Output results for this file
                if ($fileResults.Count -gt 0) {
                    Write-Host "✓ Found $($fileResults.Count) hyperlink(s) in $fileName" -ForegroundColor Green

                    foreach ($result in $fileResults) {
                        Write-Verbose "  - $($result.LinkType): $($result.Url)"
                    }

                    $allResults += $fileResults
                    $allUrls += $fileResults.Url | Select-Object -Unique
                } else {
                    Write-Host "ℹ No external hyperlinks found in $fileName" -ForegroundColor Cyan
                }

            } catch {
                Write-Error "Failed to process $fileName : $_"
            } finally {
                # Clean up temp directory
                if (Test-Path $tempDir) {
                    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    end {
        # Display summary
        Write-Host "`n=== Excel Hyperlink Extraction Summary ===" -ForegroundColor Green
        Write-Host "Files analyzed: $(($FilePath | Measure-Object).Count)"
        Write-Host "Total hyperlinks found: $($allResults.Count)"
        Write-Host "Unique URLs: $($allUrls.Count)"

        if ($allResults.Count -gt 0) {
            # Group by link type
            $byType = $allResults | Group-Object LinkType
            Write-Host "`nBy Link Type:" -ForegroundColor Cyan
            foreach ($group in $byType) {
                Write-Host "  $($group.Name): $($group.Count)"
            }

            # Display unique URLs
            Write-Host "`nExtracted URLs:" -ForegroundColor Yellow
            $allUrls | Sort-Object -Unique | ForEach-Object {
                Write-Host "  $_" -ForegroundColor White
            }

            # Export to CSV if requested
            if ($ExportCsv) {
                try {
                    $allResults | Export-Csv -Path $ExportCsv -NoTypeInformation -Force
                    Write-Host "`n✓ Results exported to: $ExportCsv" -ForegroundColor Green
                } catch {
                    Write-Error "Failed to export CSV: $_"
                }
            }

            # Block immediately if requested
            if ($BlockImmediately -and $allUrls.Count -gt 0) {
                Write-Host "`n⚠️  Proceeding with immediate URL blocking..." -ForegroundColor Yellow

                try {
                    Add-PhishIRDefenderURLBlock `
                        -Urls $allUrls `
                        -ThreatType Phishing `
                        -Description "Extracted from Excel phishing attachment" `
                        -BlockConfirmation $BlockConfirmation `
                        -ErrorAction Stop | Out-Null

                    Write-Host "✓ Successfully submitted $($allUrls.Count) URL(s) for blocking" -ForegroundColor Green
                    Write-Host "  Indicators will propagate within 2 hours" -ForegroundColor Cyan

                } catch {
                    Write-Error "Failed to block URLs: $_"
                }
            }

            # Optional incident logging
            if ($LogIncident -and $allResults.Count -gt 0) {
                $incidentActions = @{ UrlsExtracted = $allUrls.Count; BlockAttempted = [bool]$BlockImmediately }
                
                # Include recipient and email metadata if provided
                if ($Recipients) {
                    $incidentActions['RecipientCount'] = $Recipients.Count
                    $incidentActions['Recipients'] = $Recipients -join '; '
                }
                if ($EmailSubject) {
                    $incidentActions['EmailSubject'] = $EmailSubject
                }
                if ($EmailDeliveryTime) {
                    $incidentActions['EmailDeliveryTime'] = $EmailDeliveryTime.ToString('o')
                }
                
                try {
                    $incidentRecord = @{
                        IncidentType = 'ExcelHyperlinkExtraction'
                        SourceFiles = $FilePath
                        ExtractedUrls = $allUrls
                        Actions = $incidentActions
                        ApprovedBy = $IncidentApprovedBy
                        Severity = $IncidentSeverity
                        Status = $IncidentStatus
                        Notes = $IncidentNotes
                        Tags = ($IncidentTags + 'PhishIR')
                        StorePath = $StorePath
                        PassThru = $false
                        ErrorAction = 'Stop'
                    }
                    
                    Add-PhishIRIncidentRecord @incidentRecord | Out-Null
                    Write-Host "✓ Incident record logged (ExcelHyperlinkExtraction)" -ForegroundColor Green
                }
                catch {
                    Write-Warning "Incident logging failed: $($PSItem.Exception.Message)"
                }
            }

            # Check user sign-in activity if requested
            if ($CheckSignIns -and $Recipients -and $Recipients.Count -gt 0) {
                Write-Host "`n=== Checking Sign-In Activity ===" -ForegroundColor Cyan
                Write-Host "Querying Microsoft Entra ID sign-in logs for $($Recipients.Count) recipient(s)..." -ForegroundColor Cyan
                
                try {
                    # Load sign-in helper function
                    $signInFunc = Join-Path $PSScriptRoot '..' 'Private' 'Get-PhishIRUserSignInHistory.ps1'
                    if (Test-Path $signInFunc) {
                        . $signInFunc
                    }
                    
                    $signInParams = @{
                        UserPrincipalNames = $Recipients
                        DaysBack = $SignInDaysBack
                        IncludeRiskySignIns = $true
                    }
                    
                    # Filter sign-ins after email delivery if timestamp provided
                    $signIns = Get-PhishIRUserSignInHistory @signInParams
                    
                    if ($EmailDeliveryTime) {
                        $signIns = $signIns | Where-Object { 
                            [datetime]$_.CreatedDateTime -gt $EmailDeliveryTime 
                        }
                        Write-Host "Filtered to sign-ins after email delivery ($EmailDeliveryTime)" -ForegroundColor Cyan
                    }
                    
                    if ($signIns.Count -gt 0) {
                        Write-Host "`n✓ Found $($signIns.Count) sign-in(s) for recipients" -ForegroundColor Green
                        
                        # Display summary
                        $riskySignIns = $signIns | Where-Object { $_.RiskLevelAggregated -ne 'none' }
                        if ($riskySignIns.Count -gt 0) {
                            Write-Host "⚠ WARNING: $($riskySignIns.Count) risky sign-in(s) detected!" -ForegroundColor Yellow
                            Write-Host "`nRisky Sign-Ins:" -ForegroundColor Red
                            $riskySignIns | Format-Table UserPrincipalName, CreatedDateTime, IPAddress, Location, RiskLevelAggregated -AutoSize
                        }
                        
                        # Display all sign-ins
                        Write-Host "`nAll Sign-Ins:" -ForegroundColor Cyan
                        $signIns | Format-Table UserPrincipalName, CreatedDateTime, IPAddress, Location, AppDisplayName, Status -AutoSize
                        
                        # Export sign-ins to separate CSV if main export was requested
                        if ($ExportCsv) {
                            $signInCsv = $ExportCsv -replace '\.csv$', '-signins.csv'
                            $signIns | Export-Csv -Path $signInCsv -NoTypeInformation -Force
                            Write-Host "✓ Sign-ins exported to: $signInCsv" -ForegroundColor Green
                        }
                    }
                    else {
                        Write-Host "ℹ No sign-in activity found for recipients in specified timeframe" -ForegroundColor Cyan
                    }
                }
                catch {
                    Write-Warning "Failed to retrieve sign-in history: $($_.Exception.Message)"
                    Write-Warning "Ensure you're connected to Microsoft Graph with AuditLog.Read.All scope"
                }
            }
        }

        # Return results object
        return $allResults
    }
}

