Set-Location "C:/Git-Repos-Sensa/Repos-Collection"

if (!(Test-Path ".secret-scan-findings.json")) {
  throw "Missing .secret-scan-findings.json. Run scan first."
}

$hits = Get-Content ".secret-scan-findings.json" -Raw | ConvertFrom-Json
if ($null -eq $hits) { $hits = @() }

$targetFiles = $hits | Select-Object -ExpandProperty Path -Unique
$changes = New-Object System.Collections.Generic.List[object]

foreach ($file in $targetFiles) {
  if (!(Test-Path $file)) { continue }

  try {
    $content = Get-Content -LiteralPath $file -Raw -Encoding UTF8 -ErrorAction Stop
  } catch {
    continue
  }

  $updated = $content

  # 1) Azure storage connection strings
  $updated = [regex]::Replace($updated, '(?i)(DefaultEndpointsProtocol=[^;\r\n]+;[^\r\n]*?AccountKey=)([^;\r\n]+)', '$1<REDACTED>')

  # 2) Quoted JSON/YAML style assignments
  $updated = [regex]::Replace(
    $updated,
    '(?im)("(?:accountkey|sharedaccesskey|client_secret|secret_key|api[_-]?key|access[_-]?token|auth[_-]?token|password|pwd)"\s*:\s*")([^"]+)(")',
    '$1<REDACTED>$3'
  )

  # 3) General key=value / key: value assignments
  $updated = [regex]::Replace(
    $updated,
    '(?im)\b(accountkey|sharedaccesskey|client_secret|secret_key|api[_-]?key|access[_-]?token|auth[_-]?token|password|pwd)\b(\s*[:=]\s*)(["'']?)([^\r\n"'';#\s]{6,})(\3)',
    '$1$2$3<REDACTED>$5'
  )

  # 4) Bearer tokens and known token formats
  $updated = [regex]::Replace($updated, '(?i)(bearer\s+)[A-Za-z0-9\-_=\.]{20,}', '$1<REDACTED>')
  $updated = [regex]::Replace($updated, '\bghp_[A-Za-z0-9]{36,}\b', '<REDACTED_GITHUB_PAT>')
  $updated = [regex]::Replace($updated, '\bgithub_pat_[A-Za-z0-9_]{20,}\b', '<REDACTED_GITHUB_PAT>')
  $updated = [regex]::Replace($updated, '\b(AKIA|ASIA)[0-9A-Z]{16}\b', '<REDACTED_AWS_KEY>')
  $updated = [regex]::Replace($updated, '\bAIzaSy[0-9A-Za-z\-_]{20,}\b', '<REDACTED_GOOGLE_KEY>')
  $updated = [regex]::Replace($updated, '\bxox[baprs]-[A-Za-z0-9-]{10,}\b', '<REDACTED_SLACK_TOKEN>')

  if ($updated -ne $content) {
    Set-Content -LiteralPath $file -Value $updated -Encoding UTF8
    $changes.Add([PSCustomObject]@{ Path=$file; Status='Redacted' })
  }
}

# Build report with original finding locations (values intentionally not included)
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$reportLines = @()
$reportLines += "# Secret Redaction Report"
$reportLines += ""
$reportLines += "Generated: $timestamp"
$reportLines += ""
$reportLines += "## Summary"
$reportLines += "- Findings scanned: $($hits.Count)"
$reportLines += "- Files with applied redactions: $($changes.Count)"
$reportLines += ""
$reportLines += "## Findings (locations)"
$reportLines += "| Type | File | Line | Action |"
$reportLines += "|---|---|---:|---|"
foreach($h in ($hits | Sort-Object Path, LineNumber)){
  $rel = $h.Path.Replace((Get-Location).Path + '\\','')
  $reportLines += "| $($h.Type) | $rel | $($h.LineNumber) | Redacted value |"
}

Set-Content -Path "SECRET_REDACTION_REPORT.md" -Value ($reportLines -join "`r`n") -Encoding UTF8

Write-Output ("Files changed: {0}" -f $changes.Count)
$changes | Select-Object -First 200 Path, Status | Format-Table -AutoSize | Out-String | Write-Output
