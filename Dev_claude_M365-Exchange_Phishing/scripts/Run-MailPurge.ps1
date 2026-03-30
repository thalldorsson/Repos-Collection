param(
  [string[]]$Mailboxes,
  [string[]]$Senders,
  [string[]]$SubjectKeywords,
  [datetime]$StartUtc = ([datetime]::UtcNow.Date),
  [datetime]$EndUtc   = ([datetime]::UtcNow.Date.AddDays(1)),
  [ValidateSet('SoftDelete','HardDelete')][string]$PurgeType = 'SoftDelete',
  [switch]$Execute,
  [string]$OutputDir,
  [int]$PilotSampleCount = 0,
  [string]$ConfirmPhrase
)

Import-Module (Join-Path $PSScriptRoot '..' 'PhishIR' 'PhishIR.psd1') -Force

# --- Helper: minimal preflight permission check for Purge capability (Purview role) ---
function Test-PurgeCapability {
  try {
    # This should validate that the -Purge parameter is recognized in the current session.
    # We use -WhatIf to avoid side effects; if role is missing, a parameter binding error is thrown.
    $null = New-ComplianceSearchAction -SearchName ("_noop_" + [guid]::NewGuid()) -Purge -PurgeType SoftDelete -WhatIf -ErrorAction Stop
    return $true
  } catch {
    if ($_.Exception.Message -match "matches parameter name 'Purge'") {
      Write-Warning "Current principal lacks Purview 'Search And Purge' capability. Assign role in Microsoft Purview and retry."
      return $false
    }
    # Other errors can be transient (e.g., not connected) – warn but allow script to proceed
    Write-Verbose ("Preflight purge capability check warning: {0}" -f $_.Exception.Message)
    return $true
  }
}

if (-not $Mailboxes -or $Mailboxes.Count -eq 0) { throw 'Specify -Mailboxes' }
if (-not $Senders -and -not $SubjectKeywords) { throw 'Specify -Senders and/or -SubjectKeywords' }

# Pilot scoping (safety): limit to a small sample for first run if requested
if ($PilotSampleCount -gt 0 -and $Mailboxes.Count -gt $PilotSampleCount) {
  Write-Warning ("Pilot mode active: limiting mailboxes from {0} to first {1}" -f $Mailboxes.Count, $PilotSampleCount)
  $Mailboxes = $Mailboxes | Select-Object -First $PilotSampleCount
}

$scopeSummary = [PSCustomObject]@{
  MailboxCount = $Mailboxes.Count
  PurgeType    = $PurgeType
  StartUtc     = $StartUtc.ToString('o')
  EndUtc       = $EndUtc.ToString('o')
  Senders      = ($Senders -join '; ')
  Subjects     = ($SubjectKeywords -join '; ')
}

# Default is preview (dry-run). If Execute is requested, enforce exact confirmation phrase.
if ($Execute.IsPresent) {
  $expected = "CONFIRM: proceed with purge on $($scopeSummary.MailboxCount) mailboxes"
  if (-not $ConfirmPhrase -or $ConfirmPhrase -ne $expected) {
    Write-Host "Safety check: to execute, supply -ConfirmPhrase exactly:" -ForegroundColor Yellow
    Write-Host $expected -ForegroundColor Cyan
    throw 'Execution blocked: missing or incorrect -ConfirmPhrase.'
  }
  if (-not (Test-PurgeCapability)) { throw 'Execution blocked: missing Purview Search And Purge capability.' }
}

# Persist a change plan JSON for audit/change control
$changePlan = [PSCustomObject]@{
  Goal   = "Remove malicious messages via compliance purge"
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
$outDir = if ($OutputDir) { $OutputDir } else { (Join-Path $env:TEMP 'ComplianceReports') }
$null = New-Item -ItemType Directory -Force -Path $outDir -ErrorAction SilentlyContinue
$cpPath = Join-Path $outDir ("ChangePlan-" + (Get-Date -Format 'yyyyMMddTHHmmss') + ".json")
$changePlan | ConvertTo-Json -Depth 6 | Set-Content -Path $cpPath -Encoding UTF8
Write-Host ("Change plan saved: {0}" -f $cpPath) -ForegroundColor DarkCyan

$preview = -not $Execute.IsPresent

Invoke-MailPurge -Mailboxes $Mailboxes -Senders $Senders -SubjectKeywords $SubjectKeywords `
  -StartUtc $StartUtc -EndUtc $EndUtc -PurgeType $PurgeType -PreviewOnly:$preview `
  -OutputDir $outDir -Verbose:$false -Confirm:$false

Write-Host 'Done.' -ForegroundColor Green