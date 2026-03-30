<#
.SYNOPSIS
    Legacy standalone script for email purge operations - now refactored to use PhishIR module.

.DESCRIPTION
    This script provides a simplified interface for email purge operations with support for:
    - Multi-tenant connections
    - Invoice + Excel macro-capable attachment hunting
    - Delegated to PhishIR module for actual purge operations

    REFACTORED VERSION: This script now uses the PhishIR module instead of duplicating code.
    For new deployments, prefer using the PhishIR module directly:
      Import-Module PhishIR
      Invoke-MailPurge -Mailboxes @(...) -Senders "..." -PurgeType SoftDelete

.PARAMETER Organization
    Organization/tenant domain for multi-tenant scenarios (e.g., contoso.onmicrosoft.com)

.PARAMETER TenantDomain
    Alias for Organization parameter

.PARAMETER TenantId
    Tenant ID (GUID) for multi-tenant scenarios

.PARAMETER PromptForTenant
    Interactively prompt for tenant information

.PARAMETER InvoiceExcelMacroMode
    Enable specialized hunting mode for invoice-themed emails with macro-capable Excel attachments

.PARAMETER InvoiceSubjects
    Subject keywords for InvoiceExcelMacroMode (defaults to common invoice phishing patterns)

.PARAMETER IncludeLegacyExcelExtensions
    Include legacy Excel extensions (.xls, .xltm, .xlt) in InvoiceExcelMacroMode

.EXAMPLE
    .\find email from x and delete from all mailboxes.ps1 -InvoiceExcelMacroMode

    Hunts for invoice-themed emails with macro-capable Excel attachments (today only)

.EXAMPLE
    .\find email from x and delete from all mailboxes.ps1 -Organization contoso.onmicrosoft.com

    Connects to specific tenant and runs purge

.NOTES
    This script is maintained for backward compatibility. For new deployments,
    use the PhishIR module directly for better functionality and support.
#>

param(
  [string]$Organization,
  [string]$TenantDomain,
  [string]$TenantId,
  [switch]$PromptForTenant,
  # Invoice + Excel macro-capable attachment hunt helper
  [switch]$InvoiceExcelMacroMode,
  [string[]]$InvoiceSubjects = @(
    'unpaid invoice','invoice overdue','overdue invoice','unpaid invoices','invoices overdue','invoice'
  ),
  [switch]$IncludeLegacyExcelExtensions
)

# Import PhishIR module
$ModulePath = Join-Path $PSScriptRoot "PhishIR\PhishIR.psm1"
if (-not (Test-Path $ModulePath)) {
    throw "PhishIR module not found at: $ModulePath. Please ensure the module is in the correct location."
}
Import-Module $ModulePath -Force

# Confirm ExchangeOnlineManagement 3.9.0+ is available
try {
    Import-Module ExchangeOnlineManagement -MinimumVersion 3.9.0 -Force -ErrorAction Stop
}
catch {
    Write-Warning "ExchangeOnlineManagement 3.9.0+ is recommended. Some features may not work correctly with older versions."
    Import-Module ExchangeOnlineManagement -Force
}

# Resolve tenant domain/id based on provided parameters; optionally prompt (single-tenant only)
$TargetTenantDomain = $null
if ($Organization) { $TargetTenantDomain = $Organization }
elseif ($TenantDomain) { $TargetTenantDomain = $TenantDomain }
$TargetTenantId = $TenantId

if ($PromptForTenant -and (-not $TargetTenantDomain) -and (-not $TargetTenantId)) {
  $maybeDomain = Read-Host 'Enter Tenant Domain (e.g., contoso.onmicrosoft.com) or press Enter to skip'
  if ($maybeDomain) { $TargetTenantDomain = $maybeDomain }
  if (-not $TargetTenantDomain) {
    $maybeId = Read-Host 'Enter Tenant ID (GUID) or press Enter to skip'
    if ($maybeId) { $TargetTenantId = $maybeId }
  }
}

# Connect to Security & Compliance (IPPS)
if ($TargetTenantDomain -or $TargetTenantId) {
  $tenantHint = if ($TargetTenantDomain) { $TargetTenantDomain } else { $TargetTenantId }
  Write-Host ("Connecting to IPPSSession for tenant: {0}" -f $tenantHint) -ForegroundColor Cyan
}
Connect-IPPSSession -EnableSearchOnlySession

# Connect to Exchange Online if tenant specified
if ($Organization -or $TargetTenantDomain -or $TargetTenantId) {
    $exoParams = @{ ShowBanner = $false }
    if ($Organization) { $exoParams['Organization'] = $Organization }
    elseif ($TargetTenantDomain) { $exoParams['Organization'] = $TargetTenantDomain }
    elseif ($TargetTenantId) { $exoParams['Organization'] = $TargetTenantId }

    Write-Host ("Connecting to Exchange Online: {0}" -f $exoParams['Organization']) -ForegroundColor Cyan
    Connect-ExchangeOnline @exoParams
}

# =============================================================================
# EDIT THIS SECTION WITH YOUR SEARCH CRITERIA
# =============================================================================

# Multiple mailboxes to search
$Mailboxes = @(
    # Add mailbox addresses here, e.g.:
    # "user1@contoso.com",
    # "user2@contoso.com"
)

# Sender address (used when InvoiceExcelMacroMode is not enabled)
$FromAddress = ""

# Purge settings
$PurgeType   = 'SoftDelete'   # Use 'HardDelete' for permanent deletion (requires legal approval)
$PreviewOnly = $false         # Set to $true to preview without purging

# Date range (defaults to today UTC)
$DayStart    = (Get-Date).ToUniversalTime().Date
$DayEnd      = $DayStart.AddDays(1)

# =============================================================================
# BUILD QUERY BASED ON MODE
# =============================================================================

if ($InvoiceExcelMacroMode) {
    Write-Host "`n[InvoiceExcelMacroMode] Building specialized query for invoice + Excel macro attachments" -ForegroundColor Yellow

    # Build subject keywords
    $validSubjects = $InvoiceSubjects | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if ($validSubjects.Count -eq 0) {
        throw "InvoiceExcelMacroMode requires at least one invoice subject keyword"
    }

    # Build macro-capable Excel extensions list
    $macroExtensions = @('xlsm','xlsb','xlam')
    if ($IncludeLegacyExcelExtensions) {
        $macroExtensions += @('xls','xltm','xlt')
        Write-Host "  Including legacy Excel extensions: xls, xltm, xlt" -ForegroundColor Gray
    }

    # Build advanced KQL query
    # Format: (subject:"invoice" OR subject:"overdue") AND hasattachment:true AND (attachmentnames:*.xlsm OR ...) AND (received>=DATE AND received<DATE)
    $subjectTerms = $validSubjects | ForEach-Object { "subject:`"$_`"" }
    $subjectClause = "(" + ($subjectTerms -join ' OR ') + ")"

    $attTerms = $macroExtensions | ForEach-Object { "attachmentnames:*.$_" }
    $attClause = "(" + ($attTerms -join ' OR ') + ")"

    $dateClause = "(received>=$($DayStart.ToString('yyyy-MM-dd')) AND received<$($DayEnd.ToString('yyyy-MM-dd')))"

    $AdvancedQuery = "$subjectClause AND hasattachment:true AND $attClause AND $dateClause"

    Write-Host "  Query: $AdvancedQuery" -ForegroundColor Gray
    Write-Host "  Date range: $($DayStart.ToString('yyyy-MM-dd')) to $($DayEnd.ToString('yyyy-MM-dd'))" -ForegroundColor Gray
    Write-Host ""

    # Invoke PhishIR module with advanced query
    Invoke-MailPurge `
        -Mailboxes $Mailboxes `
        -AdvancedQuery $AdvancedQuery `
        -StartUtc $DayStart `
        -EndUtc $DayEnd `
        -PurgeType $PurgeType `
        -PreviewOnly:$PreviewOnly `
        -Verbose
}
else {
    # Standard mode: use sender-based query
    if ([string]::IsNullOrWhiteSpace($FromAddress)) {
        Write-Warning "No sender address specified. Building date-only query."
        Write-Warning "This may match a large number of emails. Consider adding sender criteria."

        $AdvancedQuery = "(received>=$($DayStart.ToString('yyyy-MM-dd')) AND received<$($DayEnd.ToString('yyyy-MM-dd')))"

        Invoke-MailPurge `
            -Mailboxes $Mailboxes `
            -AdvancedQuery $AdvancedQuery `
            -StartUtc $DayStart `
            -EndUtc $DayEnd `
            -PurgeType $PurgeType `
            -PreviewOnly:$PreviewOnly `
            -Verbose
    }
    else {
        # Use sender-based search
        $Senders = @($FromAddress)

        Invoke-MailPurge `
            -Mailboxes $Mailboxes `
            -Senders $Senders `
            -StartUtc $DayStart `
            -EndUtc $DayEnd `
            -PurgeType $PurgeType `
            -PreviewOnly:$PreviewOnly `
            -Verbose
    }
}

Write-Host "`nScript completed. All operations delegated to PhishIR module." -ForegroundColor Green
Write-Host "For future operations, consider using the module directly:" -ForegroundColor Cyan
Write-Host "  Import-Module PhishIR" -ForegroundColor Gray
Write-Host "  Get-Help Invoke-MailPurge -Full" -ForegroundColor Gray
