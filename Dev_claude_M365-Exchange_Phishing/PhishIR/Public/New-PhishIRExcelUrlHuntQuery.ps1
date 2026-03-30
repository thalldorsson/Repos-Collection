function New-PhishIRExcelUrlHuntQuery {
    <#
    .SYNOPSIS
    Generate KQL query for hunting Excel attachment URLs in Microsoft Defender Advanced Hunting.

    .DESCRIPTION
    Creates Kusto Query Language (KQL) queries to correlate Excel attachments with extracted URLs
    across Microsoft 365 Defender tables including EmailEvents, EmailUrlInfo, EmailAttachmentInfo,
    and UrlClickEvents. Enables server-side hyperlink extraction without downloading files.

    Supports multiple query modes:
    - UrlExtraction: Find emails with Excel attachments and any embedded URLs
    - ClickCorrelation: Identify users who clicked URLs in Excel attachments
    - ThreatHunting: Find suspicious Excel+URL patterns (obfuscation, external relationships)

    .PARAMETER QueryType
    Type of hunting query to generate:
    - UrlExtraction: Extract all URLs from emails with Excel attachments
    - ClickCorrelation: Find URL clicks from Excel attachment emails
    - ThreatHunting: Identify suspicious patterns (obfuscation, rare domains)

    .PARAMETER TimeRange
    Lookback time window (e.g., "7d", "24h", "30d"). Default is 7d.

    .PARAMETER FileName
    Optional file name pattern to filter (e.g., "invoice*.xlsx").

    .PARAMETER Domain
    Optional domain to filter URL results (e.g., "linode.com", "amazonaws.com").

    .PARAMETER IncludeContext
    Include additional context fields (sender, recipient, subject, timestamps).

    .EXAMPLE
    New-PhishIRExcelUrlHuntQuery -QueryType UrlExtraction -TimeRange "7d"

    Generate query to find all URLs in Excel attachments from last 7 days.

    .EXAMPLE
    New-PhishIRExcelUrlHuntQuery -QueryType ClickCorrelation -FileName "invoice*.xlsx" -IncludeContext

    Find users who clicked URLs from Excel files matching invoice pattern with full context.

    .EXAMPLE
    $query = New-PhishIRExcelUrlHuntQuery -QueryType ThreatHunting -Domain "linodeobjects.com"
    $query | Set-Clipboard
    # Paste into Advanced Hunting portal

    .NOTES
    Requires:
    - Microsoft 365 Defender Advanced Hunting access
    - EmailEvents, EmailAttachmentInfo, EmailUrlInfo, UrlClickEvents tables

    Run generated query in:
    https://security.microsoft.com/v2/advanced-hunting
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('UrlExtraction', 'ClickCorrelation', 'ThreatHunting')]
        [string]$QueryType,

        [Parameter()]
        [ValidatePattern('^\d+[dhms]$')]
        [string]$TimeRange = '7d',

        [Parameter()]
        [string]$FileName,

        [Parameter()]
        [string]$Domain,

        [Parameter()]
        [switch]$IncludeContext
    )

    $queries = @{
        UrlExtraction = @"
// Excel Attachment URL Extraction
// Finds emails with Excel attachments and extracts embedded URLs
// TimeRange: $TimeRange

let ExcelEmails = EmailAttachmentInfo
| where Timestamp > ago($TimeRange)
| where FileName endswith ".xlsx" or FileName endswith ".xlsm" or FileName endswith ".xls"
$(if ($FileName) { "| where FileName has '$FileName'" })
| project NetworkMessageId, FileName, FileSize, SHA256, Timestamp
| distinct NetworkMessageId, FileName, SHA256;

EmailEvents
| where Timestamp > ago($TimeRange)
| join kind=inner ExcelEmails on NetworkMessageId
| join kind=inner (
    EmailUrlInfo
    | where Timestamp > ago($TimeRange)
    $(if ($Domain) { "| where Url has '$Domain'" })
) on NetworkMessageId
$(if ($IncludeContext) {
@"
| project 
    Timestamp,
    NetworkMessageId,
    SenderFromAddress,
    RecipientEmailAddress,
    Subject,
    FileName,
    SHA256,
    Url,
    UrlDomain,
    UrlLocation
"@
} else {
@"
| project Timestamp, NetworkMessageId, FileName, Url, UrlDomain
"@
})
| order by Timestamp desc
"@

        ClickCorrelation = @"
// Excel Attachment URL Click Correlation
// Identifies users who clicked URLs embedded in Excel attachments
// TimeRange: $TimeRange

let ExcelEmailsWithUrls = EmailAttachmentInfo
| where Timestamp > ago($TimeRange)
| where FileName endswith ".xlsx" or FileName endswith ".xlsm" or FileName endswith ".xls"
$(if ($FileName) { "| where FileName has '$FileName'" })
| project NetworkMessageId, FileName, SHA256, Timestamp
| join kind=inner (
    EmailUrlInfo
    | where Timestamp > ago($TimeRange)
    $(if ($Domain) { "| where Url has '$Domain'" })
) on NetworkMessageId
| project NetworkMessageId, FileName, SHA256, Url, UrlDomain, EmailTimestamp = Timestamp
| distinct NetworkMessageId, FileName, SHA256, Url, UrlDomain;

UrlClickEvents
| where Timestamp > ago($TimeRange)
| join kind=inner ExcelEmailsWithUrls on `$left.Url == `$right.Url
$(if ($IncludeContext) {
@"
| project
    ClickTimestamp = Timestamp,
    AccountUpn,
    Url,
    UrlDomain,
    FileName,
    SHA256,
    ActionType,
    IsClickedThrough
"@
} else {
@"
| project ClickTimestamp = Timestamp, AccountUpn, Url, FileName
"@
})
| order by ClickTimestamp desc
"@

        ThreatHunting = @"
// Excel Attachment Threat Hunting
// Advanced patterns: suspicious URLs, obfuscation, rare domains
// TimeRange: $TimeRange

let SuspiciousTLDs = pack_array("tk", "ml", "ga", "cf", "gq", "xyz", "top", "pw", "cc");

let ExcelWithSuspiciousUrls = EmailAttachmentInfo
| where Timestamp > ago($TimeRange)
| where FileName endswith ".xlsx" or FileName endswith ".xlsm" or FileName endswith ".xls"
$(if ($FileName) { "| where FileName has '$FileName'" })
| project NetworkMessageId, FileName, SHA256, AttachmentTimestamp = Timestamp
| join kind=inner (
    EmailUrlInfo
    | where Timestamp > ago($TimeRange)
    $(if ($Domain) { "| where Url has '$Domain'" })
    // Suspicious URL patterns
    | extend 
        HasIPAddress = Url matches regex @"https?://\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}",
        HasSuspiciousTLD = UrlDomain has_any (SuspiciousTLDs),
        ExcessiveSubdomains = array_length(split(UrlDomain, ".")) > 5,
        HasObfuscation = Url has "%" or Url has "&#" or Url has "\\x"
    | where HasIPAddress or HasSuspiciousTLD or ExcessiveSubdomains or HasObfuscation
) on NetworkMessageId
| join kind=inner EmailEvents on NetworkMessageId
$(if ($IncludeContext) {
@"
| project
    Timestamp = AttachmentTimestamp,
    NetworkMessageId,
    SenderFromAddress,
    RecipientEmailAddress,
    Subject,
    FileName,
    SHA256,
    Url,
    UrlDomain,
    ThreatFlags = pack_array(
        iff(HasIPAddress, "IP-Address", ""),
        iff(HasSuspiciousTLD, "Suspicious-TLD", ""),
        iff(ExcessiveSubdomains, "Excessive-Subdomains", ""),
        iff(HasObfuscation, "Obfuscation", "")
    )
"@
} else {
@"
| project Timestamp = AttachmentTimestamp, FileName, Url, UrlDomain, HasIPAddress, HasSuspiciousTLD, ExcessiveSubdomains
"@
})
| order by Timestamp desc
"@
    }

    $selectedQuery = $queries[$QueryType]

    Write-Host "`n=== KQL Query Generated: $QueryType ===" -ForegroundColor Green
    Write-Host "TimeRange: $TimeRange" -ForegroundColor Cyan
    if ($FileName) { Write-Host "FileName filter: $FileName" -ForegroundColor Cyan }
    if ($Domain) { Write-Host "Domain filter: $Domain" -ForegroundColor Cyan }
    Write-Host "`nCopy query below and paste into Advanced Hunting:" -ForegroundColor Yellow
    Write-Host "https://security.microsoft.com/v2/advanced-hunting`n" -ForegroundColor Yellow

    return $selectedQuery
}
