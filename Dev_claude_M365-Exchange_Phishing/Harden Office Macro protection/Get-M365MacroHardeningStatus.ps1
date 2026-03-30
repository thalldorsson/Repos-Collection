param(
    [string]$ReportPath = "",
    [switch]$SkipSharePoint,
    [switch]$SkipDefender,
    [switch]$MachineReadable,
    [string]$TenantId,
    [string]$ExchangeOrganization,
    [string]$SharePointAdminUrl
)

# Container for report (include basic metadata for auditability)
$report = [ordered]@{
    ReportName              = "M365 Macro Hardening Status"
    ReportVersion           = "1.0.0"
    Timestamp               = (Get-Date).ToString("s")
    TenantId                = $TenantId
    ExchangeOrganization    = $ExchangeOrganization
    SharePointAdminUrl      = $SharePointAdminUrl
    TenantMacroRiskSummary  = @{}
    ExchangeOnline          = @{
        ModuleAvailable = $false
        Connected       = $false
    }
    DefenderForOffice       = @{
        ModuleAvailable = $false
        Connected       = $false
    }
    SharePointOnline        = @{
        ModuleAvailable = $false
        Connected       = $false
    }
}

function Add-ExoSection {
    try {
        if (-not (Get-Module ExchangeOnlineManagement -ListAvailable)) {
            $report.ExchangeOnline.ModuleAvailable = $false
            return
        } else {
            $report.ExchangeOnline.ModuleAvailable = $true
        }
        if (-not (Get-ConnectionInformation)) {
            if ([string]::IsNullOrWhiteSpace($ExchangeOrganization)) {
                Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop | Out-Null
            } else {
                Connect-ExchangeOnline -Organization $ExchangeOrganization -ShowBanner:$false -ErrorAction Stop | Out-Null
            }
        }
        if (Get-ConnectionInformation) { $report.ExchangeOnline.Connected = $true }

        if (Get-Command Get-SafeAttachmentPolicy -ErrorAction SilentlyContinue) {
            $report.ExchangeOnline.SafeAttachmentPolicies = Get-SafeAttachmentPolicy -ErrorAction SilentlyContinue
        }

        if (Get-Command Get-SafeLinksPolicy -ErrorAction SilentlyContinue) {
            $report.ExchangeOnline.SafeLinksPolicies = Get-SafeLinksPolicy -ErrorAction SilentlyContinue
        }

        if (Get-Command Get-MalwareFilterPolicy -ErrorAction SilentlyContinue) {
            $report.ExchangeOnline.MalwareFilterPolicies = Get-MalwareFilterPolicy -ErrorAction SilentlyContinue
        }

        if (Get-Command Get-TransportRule -ErrorAction SilentlyContinue) {
            $rules = Get-TransportRule -ErrorAction SilentlyContinue
            $macroExtensions = @('.docm','.xlsm','.pptm','.xlsb','.xlm','.doc','.xls')
            $macroRules = $rules | Where-Object {
                $text = ($_ | Out-String)
                foreach ($ext in $macroExtensions) {
                    if ($text -like "*$ext*") { return $true }
                }
                return $false
            }
            $report.ExchangeOnline.TransportRulesLikelyTouchingOfficeFiles = $macroRules
        }
    } catch {
        $report.ExchangeOnline.Error = $_.Exception.Message
    }
}

function Add-SpoSection {
    param(
        [switch]$Skip
    )
    if ($Skip) { return }
    try {
        if (-not (Get-Module Microsoft.Online.SharePoint.PowerShell -ListAvailable)) {
            $report.SharePointOnline.ModuleAvailable = $false
            return
        } else {
            $report.SharePointOnline.ModuleAvailable = $true
        }
        if (-not (Get-SPOTenant -ErrorAction SilentlyContinue)) {
            # Connect if not already connected, prefer provided URL
            $adminUrlToUse = $SharePointAdminUrl
            if ([string]::IsNullOrWhiteSpace($adminUrlToUse)) {
                $adminUrlToUse = Read-Host "Enter SharePoint admin URL (e.g. https://contoso-admin.sharepoint.com) or leave blank to skip"
            }
            if (-not [string]::IsNullOrWhiteSpace($adminUrlToUse)) {
                Connect-SPOService -Url $adminUrlToUse -ErrorAction Stop
                $report.SharePointAdminUrl = $adminUrlToUse
            }
        }
        $tenant = Get-SPOTenant -ErrorAction SilentlyContinue
        if ($tenant) {
            $report.SharePointOnline.TenantSettings = $tenant
            $report.SharePointOnline.Connected = $true
        }
    } catch {
        $report.SharePointOnline.Error = $_.Exception.Message
    }
}

function Add-DefenderSection {
    param(
        [switch]$Skip
    )
    if ($Skip) { return }
    try {
        if (-not (Get-Module Microsoft.Graph -ListAvailable)) {
            $report.DefenderForOffice.ModuleAvailable = $false
            return
        } else {
            $report.DefenderForOffice.ModuleAvailable = $true
        }
        $scopes = @('ThreatProtectionPolicy.Read.All')
        if ([string]::IsNullOrWhiteSpace($TenantId)) {
            Connect-MgGraph -Scopes $scopes -ErrorAction Stop | Out-Null
        } else {
            Connect-MgGraph -Scopes $scopes -TenantId $TenantId -ErrorAction Stop | Out-Null
        }
        $ctx = Get-MgContext
        if ($ctx) {
            $report.DefenderForOffice.Connected = $true
        }
    } catch {
        $report.DefenderForOffice.Error = $_.Exception.Message
    }
}

# Build sections
Add-ExoSection
Add-SpoSection -Skip:$SkipSharePoint
Add-DefenderSection -Skip:$SkipDefender

# High-level summary
$summary = [ordered]@{
    SafeAttachmentsConfigured   = $false
    SafeAttachmentsStrongMode   = $false
    SafeLinksConfigured         = $false
    SafeLinksForOffice          = $false
    MalwarePoliciesConfigured   = $false
    MacroRelatedTransportRules  = $false
    SPExternalSharingRestrict   = $null
}

if ($report.ExchangeOnline.SafeAttachmentPolicies) {
    $summary.SafeAttachmentsConfigured = $true
    $strongActions = @('Block','Replace','DynamicDelivery')
    if ($report.ExchangeOnline.SafeAttachmentPolicies | Where-Object { $_.Enabled -and $strongActions -contains $_.Action }) {
        $summary.SafeAttachmentsStrongMode = $true
    }
}

if ($report.ExchangeOnline.SafeLinksPolicies) {
    $summary.SafeLinksConfigured = $true
    if ($report.ExchangeOnline.SafeLinksPolicies | Where-Object { $_.Enabled -and $_.EnableSafeLinksForOffice }) {
        $summary.SafeLinksForOffice = $true
    }
}

if ($report.ExchangeOnline.MalwareFilterPolicies) {
    $summary.MalwarePoliciesConfigured = $true
}

if ($report.ExchangeOnline.TransportRulesLikelyTouchingOfficeFiles -and $report.ExchangeOnline.TransportRulesLikelyTouchingOfficeFiles.Count -gt 0) {
    $summary.MacroRelatedTransportRules = $true
}

if ($report.SharePointOnline.TenantSettings) {
    $sharing = $report.SharePointOnline.TenantSettings.SharingCapability
    $summary.SPExternalSharingRestrict = switch ($sharing) {
        0 { 'Disabled' }
        1 { 'NewAndExistingGuests' }
        2 { 'ExistingGuestsOnly' }
        3 { 'Anyone' }
        Default { "Unknown ($sharing)" }
    }
}

$report.TenantMacroRiskSummary = $summary

if ($MachineReadable -or $ReportPath -eq '-') {
    $report | ConvertTo-Json -Depth 6
} else {
    $json = $report | ConvertTo-Json -Depth 6
    if (-not $ReportPath) {
        $ReportPath = Join-Path -Path (Get-Location) -ChildPath "M365MacroHardeningStatus.json"
    }
    $json | Out-File -FilePath $ReportPath -Encoding UTF8
    Write-Host "Report written to $ReportPath"
}
