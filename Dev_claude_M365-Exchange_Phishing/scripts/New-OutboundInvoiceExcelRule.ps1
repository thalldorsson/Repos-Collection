<#!
.SYNOPSIS
Creates or updates a pilot Exchange Online mail flow (transport) rule that targets outbound messages with invoice-like subjects and Excel attachments.

.DESCRIPTION
This script creates (or updates) a transport rule to help reduce outbound phish/lure risk:
- Conditions (AND): SubjectContainsWords + AttachmentExtensionMatchesWords
- Scope: FromScope=InOrganization AND SentToScope=NotInOrganization
- Properties: Mode=Audit by default, StopRuleProcessing=$true
- Actions: In Enforce mode, reject with 5.7.1 and a clear reason. In Audit modes, set audit severity.
- Optional exception: ExceptIfFromMemberOf for a trusted allow group (e.g., Finance)

By default, the rule is created disabled and in Audit mode for safe validation.

.PARAMETER RuleName
Display name of the transport rule.

.PARAMETER Subjects
Subject phrases that indicate suspicious invoice content. Multiple values allowed.

.PARAMETER Extensions
Attachment extensions to match (case-insensitive). Multiple values allowed. Defaults to Excel variants.

.PARAMETER IncludeLegacyExcelExtensions
When present, includes legacy Excel extensions (xls, xlt) in addition to the default extensions.

.PARAMETER AllowGroup
Optional group to exclude from this rule (ExceptIfFromMemberOf). Use a well-known identity (name, alias, email, or GUID).

.PARAMETER Mode
Rule mode: Audit, AuditAndNotify, or Enforce. Defaults to Audit.

.PARAMETER MatchPasswordProtectedAttachments
When present, adds the AttachmentIsPasswordProtected condition (true) in addition to extension matching.

.PARAMETER AuditSeverity
Audit severity to set when in Audit/AuditAndNotify modes. Valid: DoNotAudit, Low, Medium, High. Defaults to High.

.PARAMETER RejectStatusCode
Enhanced status code used for rejection in Enforce mode. Defaults to 5.7.1.

.PARAMETER RejectReasonText
Reason text used for rejection in Enforce mode.

.PARAMETER Enable
When present, creates/enables the rule. Otherwise the rule is created disabled.

.PARAMETER UpdateIfExists
When present, updates an existing rule with the same name instead of failing.

.PARAMETER WhatIf
Pass-through WhatIf to underlying cmdlets.

.NOTES
Requires an active connection to Exchange Online PowerShell (Connect-ExchangeOnline) with sufficient RBAC (e.g., Transport Hygiene or Organization Management).

.EXAMPLE
scripts/New-OutboundInvoiceExcelRule.ps1 -AllowGroup "Finance Outbound Allow"

.EXAMPLE
scripts/New-OutboundInvoiceExcelRule.ps1 -Mode Enforce -Enable -UpdateIfExists -AllowGroup "Finance Outbound Allow"
#>

[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
Param(
    [Parameter()] [string] $RuleName = "Pilot - Outbound: suspicious invoice subject + Excel attachment",

    [Parameter()] [string[]] $Subjects = @(
        'unpaid invoice','invoice overdue','overdue invoice','unpaid invoices','invoices overdue','invoice'
    ),

    [Parameter()] [string[]] $Extensions = @(
        'xlsm','xlsb','xlam','xlsx'
    ),

    [Parameter()] [switch] $IncludeLegacyExcelExtensions,

    [Parameter()] [string] $AllowGroup,

    [Parameter()] [ValidateSet('Audit','AuditAndNotify','Enforce')] [string] $Mode = 'Audit',

    [Parameter()] [switch] $MatchPasswordProtectedAttachments,

    [Parameter()] [ValidateSet('DoNotAudit','Low','Medium','High')] [string] $AuditSeverity = 'High',

    [Parameter()] [string] $RejectStatusCode = '5.7.1',

    [Parameter()] [string] $RejectReasonText = 'Blocked by policy: suspicious invoice subject with Excel attachment',

    [Parameter()] [switch] $Enable,

    [Parameter()] [switch] $UpdateIfExists,

    [Parameter()] [switch] $WhatIf
)

function Write-Info {
    Param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-WarnMsg {
    Param([string]$Message)
    Write-Warning $Message
}

function Write-ErrMsg {
    Param([string]$Message)
    Write-Error $Message
}

try {
    Write-Info "Preparing pilot transport rule '$RuleName' with Mode=$Mode and Enabled=$($Enable.IsPresent)."

    # Build extensions list
    $exts = @()
    foreach ($e in $Extensions) { if ($null -ne $e -and $e -ne '') { $exts += $e } }
    if ($IncludeLegacyExcelExtensions) {
        $exts += @('xls','xlt')
    }
    # De-duplicate and normalize
    $exts = ($exts | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)

    if ($exts.Count -eq 0) {
        throw "No attachment extensions provided after processing."
    }

    if ($Subjects.Count -eq 0) {
        throw "No subject phrases provided."
    }

    $comments = "Pilot rule generated to control outbound invoice-like subjects with Excel attachments. Start in Audit. Updated $(Get-Date -Format s)."

    $baseSplat = @{
        SubjectContainsWords             = $Subjects
        AttachmentExtensionMatchesWords  = $exts
        FromScope                        = 'InOrganization'
        SentToScope                      = 'NotInOrganization'
        StopRuleProcessing               = $true
        Mode                             = $Mode
        Comments                         = $comments
    }

    if ($MatchPasswordProtectedAttachments) {
        $baseSplat["AttachmentIsPasswordProtected"] = $true
        Write-Info "Requiring AttachmentIsPasswordProtected = true"
    }

    if ($AllowGroup -and $AllowGroup -ne '') {
        $baseSplat["ExceptIfFromMemberOf"] = $AllowGroup
        Write-Info "Adding exception: ExceptIfFromMemberOf = $AllowGroup"
    }

    # Action defaults by mode
    $actionSplat = @{}
    if ($Mode -eq 'Enforce') {
        $actionSplat['RejectMessageReasonText'] = $RejectReasonText
        $actionSplat['RejectMessageEnhancedStatusCode'] = $RejectStatusCode
    } else {
        $actionSplat['SetAuditSeverity'] = $AuditSeverity
    }

    # Existence check
    $existing = $null
    try {
        $existing = Get-TransportRule -Identity $RuleName -ErrorAction Stop
    } catch {
        $existing = $null
    }

    if ($null -eq $existing) {
        Write-Info "Creating new transport rule '$RuleName' (Enabled=$($Enable.IsPresent), Mode=$Mode)."
        $newSplat = @{
            Name     = $RuleName
            Enabled  = [bool]$Enable
            WhatIf   = [bool]$WhatIf
        }
        $newSplat += $baseSplat
        $newSplat += $actionSplat

        if ($PSCmdlet.ShouldProcess($RuleName, "New-TransportRule")) {
            New-TransportRule @newSplat | Out-Null
        }

        Write-Info "Rule '$RuleName' created. Note: It can take up to ~30 minutes to take effect across the service."
    } else {
        if (-not $UpdateIfExists) {
            Write-WarnMsg "Rule '$RuleName' already exists. Use -UpdateIfExists to modify it."
            return
        }

        Write-Info "Updating existing transport rule '$RuleName' (Mode=$Mode)."
        $setSplat = @{
            Identity = $RuleName
            WhatIf   = [bool]$WhatIf
        }
        $setSplat += $baseSplat
        $setSplat += $actionSplat

        if ($PSCmdlet.ShouldProcess($RuleName, "Set-TransportRule")) {
            Set-TransportRule @setSplat | Out-Null
        }

        if ($Enable) {
            if ($PSCmdlet.ShouldProcess($RuleName, "Enable-TransportRule")) { Enable-TransportRule -Identity $RuleName -WhatIf:$WhatIf | Out-Null }
        } else {
            if ($PSCmdlet.ShouldProcess($RuleName, "Disable-TransportRule")) { Disable-TransportRule -Identity $RuleName -WhatIf:$WhatIf | Out-Null }
        }

        Write-Info "Rule '$RuleName' updated."
    }

    # Display a quick summary
    $summary = Get-TransportRule -Identity $RuleName | Select-Object Name,State,Mode,Priority
    $summary | Format-List | Out-Host
    Write-Info "Validation tips: Use Message trace and Advanced Hunting (kql/pack.kql queries #1 and #9) to observe rule impact."
}
catch {
    Write-ErrMsg $_.Exception.Message
    throw
}
