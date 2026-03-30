function New-PhishIRHuntingQuery {
    <#
    .SYNOPSIS
        Generates KQL queries for Advanced Hunting in Microsoft 365 Defender.
    
    .DESCRIPTION
        Creates pre-built or custom KQL queries for common phishing investigation scenarios.
        Supports email delivery chains, process execution, identity anomalies, and OAuth abuse patterns.
    
    .PARAMETER Scenario
        Predefined hunting scenario: EmailDelivery, MacroExecution, IdentityAnomaly, OAuthAbuse, MailboxRules
    
    .PARAMETER Sender
        Email sender address to hunt for (used with EmailDelivery scenario).
    
    .PARAMETER AttachmentHash
        SHA256 hash of suspicious attachment (used with EmailDelivery, MacroExecution scenarios).
    
    .PARAMETER Subject
        Email subject keyword or pattern (used with EmailDelivery scenario).
    
    .PARAMETER TimeWindow
        Time window in hours to search (default: 48 hours).
    
    .PARAMETER CustomQuery
        Custom KQL query string to use instead of predefined scenarios.
    
    .EXAMPLE
        New-PhishIRHuntingQuery -Scenario EmailDelivery -Sender 'evil@bad.com' -TimeWindow 24
        
        Generates KQL to find all emails from evil@bad.com in the last 24 hours.
    
    .EXAMPLE
        New-PhishIRHuntingQuery -Scenario MacroExecution -AttachmentHash '1a2b3c4d...'
        
        Generates KQL to find process execution following macro-enabled attachment delivery.
    
    .EXAMPLE
        $query = New-PhishIRHuntingQuery -Scenario MailboxRules -TimeWindow 72
        $query | Set-Clipboard
        
        Generate mailbox rule hunting query and copy to clipboard for Defender portal.
    
    .OUTPUTS
        String containing the KQL query ready for Advanced Hunting.
    #>
    [CmdletBinding(DefaultParameterSetName='Scenario')]
    param(
        [Parameter(Mandatory, ParameterSetName='Scenario')]
        [ValidateSet('EmailDelivery','MacroExecution','IdentityAnomaly','OAuthAbuse','MailboxRules','UrlClick')]
        [string]$Scenario,
        
        [Parameter(ParameterSetName='Scenario')]
        [string]$Sender,
        
        [Parameter(ParameterSetName='Scenario')]
        [string]$AttachmentHash,
        
        [Parameter(ParameterSetName='Scenario')]
        [string]$Subject,
        
        [Parameter(ParameterSetName='Scenario')]
        [Parameter(ParameterSetName='Custom')]
        [int]$TimeWindow = 48,
        
        [Parameter(Mandatory, ParameterSetName='Custom')]
        [string]$CustomQuery
    )
    
    if ($PSCmdlet.ParameterSetName -eq 'Custom') {
        return $CustomQuery
    }
    
    $timeFilter = "Timestamp > ago($($TimeWindow)h)"
    
    switch ($Scenario) {
        'EmailDelivery' {
            $filters = @($timeFilter)
            if ($Sender) { $filters += "SenderFromAddress == '$Sender'" }
            if ($Subject) { $filters += "Subject contains '$Subject'" }
            if ($AttachmentHash) {
                $query = @"
// Email delivery with attachment hash
EmailAttachmentInfo
| where $($filters -join ' and ')
    and SHA256 == '$AttachmentHash'
| join EmailEvents on NetworkMessageId
| project Timestamp, RecipientEmailAddress, SenderFromAddress, Subject, AttachmentCount, SHA256, DeliveryAction, DeliveryLocation
| sort by Timestamp desc
"@
            } else {
                $query = @"
// Email delivery tracking
EmailEvents
| where $($filters -join ' and ')
| project Timestamp, RecipientEmailAddress, SenderFromAddress, Subject, AttachmentCount, DeliveryAction, DeliveryLocation, ThreatTypes
| sort by Timestamp desc
"@
            }
        }
        
        'MacroExecution' {
            $query = @"
// Macro-enabled Office app spawning suspicious processes
let macroDelivery = EmailAttachmentInfo
    | where $timeFilter
"@
            if ($AttachmentHash) { $query += "`n    and SHA256 == '$AttachmentHash'" }
            if ($Sender) { $query += "`n    and SenderFromAddress == '$Sender'" }
            $query += @"

    | where FileName endswith '.xls' or FileName endswith '.xlsm' or FileName endswith '.doc' or FileName endswith '.docm'
    | join EmailEvents on NetworkMessageId
    | project DeliveryTime=Timestamp, RecipientEmailAddress, SenderFromAddress, Subject, FileName, SHA256;
DeviceProcessEvents
| where $timeFilter
    and InitiatingProcessFileName in~ ('EXCEL.EXE','WINWORD.EXE','POWERPNT.EXE')
    and FileName in~ ('powershell.exe','cmd.exe','wscript.exe','mshta.exe','rundll32.exe','regsvr32.exe')
| join kind=leftouter macroDelivery on `$left.AccountUpn == `$right.RecipientEmailAddress
| project Timestamp, DeviceName, AccountUpn, InitiatingProcessFileName, FileName, ProcessCommandLine, DeliveryTime, SenderFromAddress, Subject
| sort by Timestamp desc
"@
        }
        
        'IdentityAnomaly' {
            $query = @"
// Risky sign-ins and legacy auth following email delivery
IdentityLogonEvents
| where $timeFilter
    and (LogonType == 'interactiveLogon' or LogonType == 'remoteInteractive')
    and (RiskLevelDuringSignIn in ('high','medium') or isnotempty(FailureReason))
| project Timestamp, AccountUpn, Application, LogonType, IPAddress, Location, RiskLevelDuringSignIn, FailureReason
| sort by Timestamp desc
"@
        }
        
        'OAuthAbuse' {
            $query = @"
// OAuth app consent and suspicious app activity
CloudAppEvents
| where $timeFilter
    and ActionType in ('Consent to application.','Add service principal.','Update application.','Add app role assignment to service principal.')
| extend AppId = tostring(parse_json(RawEventData).AppId)
| extend Permissions = tostring(parse_json(RawEventData).Scope)
| project Timestamp, AccountObjectId, AccountDisplayName, ActionType, AppId, Permissions, IPAddress, CountryCode
| sort by Timestamp desc
"@
        }
        
        'MailboxRules' {
            $query = @"
// Suspicious inbox rules (forwarding, deletion, hidden)
OfficeActivity
| where $timeFilter
    and Operation in ('New-InboxRule','Set-InboxRule')
| extend RuleActions = tostring(parse_json(Parameters)[0].Value)
| where RuleActions contains 'ForwardTo' or RuleActions contains 'RedirectTo' or RuleActions contains 'DeleteMessage'
| project Timestamp, UserId, Operation, RuleActions, ClientIP, OriginatingServer
| sort by Timestamp desc
"@
        }
        
        'UrlClick' {
            $query = @"
// Safe Links URL clicks following email delivery
UrlClickEvents
| where $timeFilter
"@
            if ($Sender) { $query += "`n    and AccountUpn in (EmailEvents | where SenderFromAddress == '$Sender' | distinct RecipientEmailAddress)" }
            $query += @"

| project Timestamp, AccountUpn, Url, ClickTime=Timestamp, IsClickedThrough, ThreatTypes
| sort by Timestamp desc
"@
        }
    }
    
    return $query
}
