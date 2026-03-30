Set-Location "C:/Git-Repos-Sensa/Repos-Collection"

$exclude = '\\(node_modules|\.git|dist|build|bin|obj)\\'
$patterns = @(
  @{ Type='PrivateKey'; Regex='-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----' },
  @{ Type='AWSAccessKey'; Regex='\b(AKIA|ASIA)[0-9A-Z]{16}\b' },
  @{ Type='GitHubPAT'; Regex='\bghp_[A-Za-z0-9]{36,}\b|\bgithub_pat_[A-Za-z0-9_]{20,}\b' },
  @{ Type='SlackToken'; Regex='\bxox[baprs]-[A-Za-z0-9-]{10,}\b' },
  @{ Type='GoogleAPIKey'; Regex='\bAIzaSy[0-9A-Za-z\-_]{20,}\b' },
  @{ Type='AzureStorageConnString'; Regex='DefaultEndpointsProtocol=[^\r\n;]+;[^\r\n]*AccountKey=<REDACTED>;\r\n]+' },
  @{ Type='AccountKeyAssignment'; Regex='(?i)(accountkey|sharedaccesskey|client_secret|secret_key|api[_-]?key)\s*[:=]\s*["'']?[A-Za-z0-9/+=._\-]{12,}' },
  @{ Type='PasswordAssignment'; Regex='(?i)\b(password|pwd)\b\s*[:=]\s*["'']?[^"''\s]{8,}' },
  @{ Type='BearerToken'; Regex='(?i)bearer\s+[A-Za-z0-9\-_=\.]{20,}' }
)
$placeholder = '(?i)(example|sample|dummy|test|your[_-]?|changeme|placeholder|localhost|fake|notreal)'

$files = Get-ChildItem -Recurse -File | Where-Object {
  $_.FullName -notmatch $exclude -and $_.Length -lt 5MB
}

$hits = @()
foreach($p in $patterns){
  try {
    $matches = Select-String -Path $files.FullName -Pattern $p.Regex -AllMatches -Encoding UTF8 -ErrorAction SilentlyContinue
    foreach($x in $matches){
      if($x.Line -match $placeholder){ continue }
      foreach($mm in $x.Matches){
        $hits += [PSCustomObject]@{
          Type       = $p.Type
          Path       = $x.Path
          LineNumber = $x.LineNumber
          Line       = $x.Line.Trim()
          Match      = $mm.Value
        }
      }
    }
  } catch {}
}

$hits = $hits | Sort-Object Path,LineNumber,Type -Unique
$hits | ConvertTo-Json -Depth 6 | Set-Content -Path ".secret-scan-findings.json" -Encoding UTF8
Write-Output ("Findings count: {0}" -f $hits.Count)
$hits | Select-Object -First 120 Type,Path,LineNumber,Match | Format-Table -AutoSize | Out-String | Write-Output

