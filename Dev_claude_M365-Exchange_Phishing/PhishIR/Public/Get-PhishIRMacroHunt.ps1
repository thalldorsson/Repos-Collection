function Get-PhishIRMacroHunt {
    <#
    .SYNOPSIS
    Generate Advanced Hunting (KQL) queries to detect macro-enabled Excel attachments and user activity.

    .DESCRIPTION
    Returns KQL queries for Microsoft 365 Defender Advanced Hunting to:
    - Identify delivered macro-enabled Excel attachments (last 30 days)
    - Detect users who opened those attachments on endpoints
    - Build recipient watchlist
    - Detect outbound emails from watchlist containing macros or invoice subjects
    - Audit MFA/auth method changes

    .PARAMETER QueryType
    Type of hunting query to generate. Valid values:
    - DeliveredMacroAttachments: Find delivered macro Excel attachments
    - UserOpenedMacro: Correlate attachments with device file/process events
    - RecipientWatchlist: Build list of recipients who received macro attachments
    - OutboundDetection: Detect outbound emails with macros or invoice subjects
    - MFAChanges: Audit MFA/auth method changes
    - All: Return all queries

    .PARAMETER TimeRange
    Time range for hunting queries (e.g., "30d", "7d"). Default is 30d.

    .PARAMETER InvoiceKeywords
    Array of invoice-related keywords to detect. Default includes common phishing subjects.

    .PARAMETER MacroExtensions
    Array of macro-enabled Excel file extensions. Default includes .xlsm, .xlsb, .xltm, .xla.

    .EXAMPLE
    Get-PhishIRMacroHunt -QueryType DeliveredMacroAttachments

    .EXAMPLE
    Get-PhishIRMacroHunt -QueryType All -TimeRange "7d" | Out-File hunting_queries.kql

    .EXAMPLE
    $queries = Get-PhishIRMacroHunt -QueryType OutboundDetection
    # Copy to Defender Advanced Hunting portal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateSet('DeliveredMacroAttachments', 'UserOpenedMacro', 'RecipientWatchlist', 'OutboundDetection', 'MFAChanges', 'All')]
        [string]$QueryType = 'All',

        [Parameter(Mandatory = $false)]
        [string]$TimeRange = '30d',

        [Parameter(Mandatory = $false)]
        [string[]]$InvoiceKeywords = @(
            'unpaid invoice',
            'invoice overdue',
            'overdue invoice',
            'unpaid invoices',
            'invoices overdue'
        ),

        [Parameter(Mandatory = $false)]
        [string[]]$MacroExtensions = @('.xlsm', '.xlsb', '.xltm', '.xla')
    )

    $queries = @{}

    # Query 1: Delivered macro-enabled Excel attachments
    $deliveredMacroQuery = @"
// Find delivered macro-enabled Excel attachments (last $TimeRange)
let macroExt = dynamic($($MacroExtensions | ConvertTo-Json -Compress));
EmailAttachmentInfo
| where Timestamp >= ago($TimeRange)
| where FileName has_any (macroExt)
| project Timestamp, NetworkMessageId, Sender = SenderFromAddress, Recipient = RecipientEmailAddress, FileName, SHA256, FileSize
| order by Timestamp desc
"@
    $queries['DeliveredMacroAttachments'] = $deliveredMacroQuery

    # Query 2: Users who opened macro attachments on endpoints
    $userOpenedMacroQuery = @"
// Detect users who opened macro-enabled Excel attachments on endpoints
let macroExt = dynamic($($MacroExtensions | ConvertTo-Json -Compress));
let macros = EmailAttachmentInfo
    | where Timestamp >= ago($TimeRange)
    | where FileName has_any (macroExt)
    | project SHA256, FileName, Recipient = RecipientEmailAddress, NetworkMessageId, EmailTime = Timestamp;
DeviceFileEvents
| where Timestamp >= ago($TimeRange)
| where SHA256 in (macros | project SHA256)
| project DeviceTime = Timestamp, DeviceName, DeviceId, AccountName, FileName, SHA256, FolderPath, InitiatingProcessFileName, InitiatingProcessCommandLine
| join kind=inner (macros) on SHA256
| project EmailTime, Recipient, NetworkMessageId, DeviceTime, DeviceName, DeviceId, AccountName, FileName, FolderPath, InitiatingProcessFileName, InitiatingProcessCommandLine
| order by EmailTime desc
// Alternative: Use DeviceProcessEvents if you prefer process-based detection
// DeviceProcessEvents
// | where Timestamp >= ago($TimeRange)
// | where ProcessName =~ "EXCEL.EXE"
// | where ProcessCommandLine has_any (macroExt)
"@
    $queries['UserOpenedMacro'] = $userOpenedMacroQuery

    # Query 3: Build recipient watchlist
    $recipientWatchlistQuery = @"
// Build recipient watchlist: recipients who received macro-enabled Excel in last $TimeRange
let macroExt = dynamic($($MacroExtensions | ConvertTo-Json -Compress));
EmailAttachmentInfo
| where Timestamp >= ago($TimeRange)
| where FileName has_any (macroExt)
| summarize ReceivedCount = count(), FirstSeen = min(Timestamp), LastSeen = max(Timestamp), FileNames = make_set(FileName), Senders = make_set(SenderFromAddress) by Recipient = RecipientEmailAddress
| where ReceivedCount >= 1
| order by ReceivedCount desc
"@
    $queries['RecipientWatchlist'] = $recipientWatchlistQuery

    # Query 4: Detect outbound emails from watchlist with macros or invoice subjects
    $outboundDetectionQuery = @"
// Detect outbound emails from watchlist containing macro Excel attachments or invoice-like subjects
let invoiceWords = dynamic($($InvoiceKeywords | ConvertTo-Json -Compress));
let macroExt = dynamic($($MacroExtensions | ConvertTo-Json -Compress));
// First, build watchlist (or supply manually)
let watchlist = EmailAttachmentInfo
    | where Timestamp >= ago($TimeRange)
    | where FileName has_any (macroExt)
    | distinct Recipient = RecipientEmailAddress;
EmailEvents
| where Timestamp >= ago($TimeRange)
| where SenderFromAddress in (watchlist)
| where EmailDirection == "Outbound" or SenderFromDomain endswith ".onmicrosoft.com" // Adjust for your tenant
| where (Subject has_any (invoiceWords)) or (AttachmentCount > 0)
| join kind=leftouter (
    EmailAttachmentInfo
    | where Timestamp >= ago($TimeRange)
    | where FileName has_any (macroExt)
    | project NetworkMessageId, MacroFileName = FileName, MacroSHA256 = SHA256
) on NetworkMessageId
| where isnotempty(MacroFileName) or Subject has_any (invoiceWords)
| project Timestamp, Sender = SenderFromAddress, Recipients = RecipientEmailAddress, Subject, AttachmentCount, MacroFileName, MacroSHA256, NetworkMessageId
| order by Timestamp desc
"@
    $queries['OutboundDetection'] = $outboundDetectionQuery

    # Query 5: Audit MFA/auth method changes
    $mfaChangesQuery = @"
// Audit MFA/auth method changes (Azure AD Audit logs)
// Note: Requires CloudAppEvents or IdentityDirectoryEvents table (varies by licensing)
CloudAppEvents
| where Timestamp >= ago($TimeRange)
| where Application == "Microsoft Entra ID" or Application == "Azure Active Directory"
| where ActivityType has_any ("Add authentication method", "Delete authentication method", "Update authentication method", "Add phone authentication method", "Delete phone authentication method")
| project Timestamp, AccountDisplayName, AccountObjectId, ActivityType, RawEventData, IPAddress, CountryCode
| order by Timestamp desc
// Alternative if CloudAppEvents not available:
// IdentityDirectoryEvents
// | where Timestamp >= ago($TimeRange)
// | where ActionType has_any ("Authentication method added", "Authentication method deleted")
// | project Timestamp, TargetAccountDisplayName, ActionType, AdditionalFields
"@
    $queries['MFAChanges'] = $mfaChangesQuery

    # Return requested queries
    if ($QueryType -eq 'All') {
        $output = @"
// ========================================
// PhishIR Macro Hunting Queries
// Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
// Time Range: $TimeRange
// ========================================

"@
        foreach ($key in $queries.Keys | Sort-Object) {
            $output += "`n// === $key ===`n"
            $output += $queries[$key]
            $output += "`n"
        }
        return $output
    }
    else {
        return $queries[$QueryType]
    }
}
