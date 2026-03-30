param(
  [Parameter(Mandatory)][string]$ConfigPath,
  [string[]]$Senders,
  [string[]]$SubjectKeywords,
  [datetime]$StartUtc = ([datetime]::UtcNow.Date),
  [datetime]$EndUtc   = ([datetime]::UtcNow.Date.AddDays(1)),
  [ValidateSet('SoftDelete','HardDelete')][string]$PurgeType = 'SoftDelete',
  [switch]$Execute,
  [int]$PilotSampleCount = 0,
  [string]$ConfirmPhrase
)

Import-Module (Join-Path $PSScriptRoot '..' 'PhishIR' 'PhishIR.psd1') -Force

if (-not (Test-Path $ConfigPath)) { throw "Config file not found: $ConfigPath" }
$config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
if (-not $config -or -not $config.Tenants) { throw 'Invalid config: missing Tenants array' }

function Test-PurgeCapability {
  try {
    $null = New-ComplianceSearchAction -SearchName ("_noop_" + [guid]::NewGuid()) -Purge -PurgeType SoftDelete -WhatIf -ErrorAction Stop
    return $true
  } catch {
    if ($_.Exception.Message -match "matches parameter name 'Purge'") {
      Write-Warning "Current principal lacks Purview 'Search And Purge' capability. Assign role in Microsoft Purview and retry."
      return $false
    }
    Write-Verbose ("Preflight purge capability check warning: {0}" -f $_.Exception.Message)
    return $true
  }
}

foreach ($t in $config.Tenants) {
  $tenantName = $t.DisplayName
  $tenantId   = $t.TenantId
  $mailboxes  = @($t.Mailboxes)
  $outDirRoot = if ($t.OutputRoot) { $t.OutputRoot } else { (Join-Path $env:TEMP 'ComplianceReports') }
  $tenantOut  = Join-Path $outDirRoot ("${tenantName}-" + (Get-Date -Format 'yyyyMMdd'))
  $null = New-Item -ItemType Directory -Force -Path $tenantOut -ErrorAction SilentlyContinue

  Write-Host "=== Tenant: $tenantName ($tenantId) ===" -ForegroundColor Cyan
  if ($tenantId) {
    try { Connect-ExchangeOnline -Organization $tenantId -ShowBanner:$false -ErrorAction Stop | Out-Null }
    catch { Write-Warning "Connect-ExchangeOnline failed for $tenantName: $($_.Exception.Message)" }
    try { Connect-IPPSSession -Organization $tenantId -EnableSearchOnlySession -ErrorAction Stop | Out-Null }
    catch { Write-Warning "Connect-IPPSSession failed for $tenantName: $($_.Exception.Message)" }
  } else {
    Write-Warning 'No TenantId provided; using current context.'
  }

  # Apply per-tenant pilot limiting if requested (CLI switch overrides config)
  $effectivePilot = if ($PilotSampleCount -gt 0) { $PilotSampleCount } elseif ($t.PilotSampleCount) { [int]$t.PilotSampleCount } else { 0 }
  if ($effectivePilot -gt 0 -and $mailboxes.Count -gt $effectivePilot) {
    Write-Warning ("Pilot mode active for tenant {0}: limiting mailboxes from {1} to first {2}" -f $tenantName, $mailboxes.Count, $effectivePilot)
    $mailboxes = $mailboxes | Select-Object -First $effectivePilot
  }

  $scopeSummary = [PSCustomObject]@{
    TenantName  = $tenantName
    TenantId    = ($tenantId ? ($tenantId.Substring(0,8) + '…') : 'current-context')
    MailboxCount= $mailboxes.Count
    PurgeType   = $PurgeType
    StartUtc    = $StartUtc.ToString('o')
    EndUtc      = $EndUtc.ToString('o')
    Senders     = ($Senders -join '; ')
    Subjects    = ($SubjectKeywords -join '; ')
  }

  if ($Execute.IsPresent) {
    $expected = "CONFIRM: proceed with purge on $tenantName"
    if (-not $ConfirmPhrase -or $ConfirmPhrase -ne $expected) {
      Write-Host "Safety check: to execute for tenant '$tenantName', supply -ConfirmPhrase exactly:" -ForegroundColor Yellow
      Write-Host $expected -ForegroundColor Cyan
      throw "Execution blocked for tenant '$tenantName': missing or incorrect -ConfirmPhrase."
    }
    if (-not (Test-PurgeCapability)) { throw "Execution blocked for tenant '$tenantName': missing Purview Search And Purge capability." }
  }

  # Write tenant-scoped change plan file
  $changePlan = [PSCustomObject]@{
    Goal   = "Remove malicious messages via compliance purge (multi-tenant)"
    Scope  = $scopeSummary
    Steps  = @(
      'WhatIf preview run and evidence collection',
      'If safe, execute purge cycles with status polling',
      'Post-action verification (Recoverable Items sampling)',
      'Export reports and audit trail'
    )
    Rollback = 'Halt subsequent waves; investigate false positives; restore if applicable; remove temporary filters'
    Owners   = @('IR Operator')
    Created  = (Get-Date).ToUniversalTime().ToString('o')
  }
  $cpPath = Join-Path $tenantOut ("ChangePlan-" + (Get-Date -Format 'yyyyMMddTHHmmss') + ".json")
  $changePlan | ConvertTo-Json -Depth 6 | Set-Content -Path $cpPath -Encoding UTF8
  Write-Host ("Change plan saved: {0}" -f $cpPath) -ForegroundColor DarkCyan

  $preview = -not $Execute.IsPresent
  Invoke-MailPurge -Mailboxes $mailboxes -Senders $Senders -SubjectKeywords $SubjectKeywords `
    -StartUtc $StartUtc -EndUtc $EndUtc -PurgeType $PurgeType -PreviewOnly:$preview -OutputDir $tenantOut -Confirm:$false
}

Write-Host 'All tenants processed.' -ForegroundColor Green