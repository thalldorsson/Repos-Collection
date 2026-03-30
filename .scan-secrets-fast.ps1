Set-Location "C:/Git-Repos-Sensa/Repos-Collection"

$excludeDirPattern = '\\(node_modules|\.git|dist|build|bin|obj|coverage|.next|out)\\'
$exts = @('*.env','*.txt','*.md','*.json','*.yml','*.yaml','*.xml','*.config','*.ini','*.ps1','*.psm1','*.sh','*.bash','*.zsh','*.cmd','*.bat','*.js','*.ts','*.tsx','*.jsx','*.py','*.java','*.cs','*.go','*.rb','*.php','*.tf','*.bicep','*.sql','Dockerfile','docker-compose*.yml')

$patterns = @(
  @{ Type='PrivateKey'; Regex='-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----' },
  @{ Type='AWSAccessKey'; Regex='\b(AKIA|ASIA)[0-9A-Z]{16}\b' },
  @{ Type='GitHubPAT'; Regex='\bghp_[A-Za-z0-9]{36,}\b|\bgithub_pat_[A-Za-z0-9_]{20,}\b' },
  @{ Type='SlackToken'; Regex='\bxox[baprs]-[A-Za-z0-9-]{10,}\b' },
  @{ Type='GoogleAPIKey'; Regex='\bAIzaSy[0-9A-Za-z\-_]{20,}\b' },
  @{ Type='AzureStorageConnString'; Regex='DefaultEndpointsProtocol=[^\r\n;]+;[^\r\n]*AccountKey=<REDACTED>;\r\n]+' },
  @{ Type='SecretAssignment'; Regex='(?i)(accountkey|sharedaccesskey|client_secret|secret_key|api[_-]?key|access[_-]?token|auth[_-]?token)\s*[:=]\s*["'']?[A-Za-z0-9/+=._\-]{16,}' },
  @{ Type='PasswordAssignment'; Regex='(?i)\b(password|pwd)\b\s*[:=]\s*["'']?[^"''\s]{10,}' },
  @{ Type='BearerToken'; Regex='(?i)bearer\s+[A-Za-z0-9\-_=\.]{20,}' }
)
$placeholder = '(?i)(example|sample|dummy|test|your[_-]?|changeme|placeholder|localhost|fake|notreal|<.*>|\{\{.*\}\})'

$files = foreach($e in $exts){ Get-ChildItem -Recurse -File -Filter $e -ErrorAction SilentlyContinue }
$files = $files | Where-Object {
  $_.FullName -notmatch $excludeDirPattern -and
  $_.Length -lt 2MB -and
  $_.Name -notlike '.secret-scan-*' -and
  $_.Name -ne 'SECRET_REDACTION_REPORT.md' -and
  $_.Name -notlike '.redact-secrets*' -and
  $_.Name -notlike '.scan-secrets*'
} | Sort-Object FullName -Unique

$hits = New-Object System.Collections.Generic.List[object]
foreach($file in $files){
  try{
    $content = Get-Content -LiteralPath $file.FullName -Encoding UTF8 -ErrorAction Stop
  } catch { continue }

  for($i=0; $i -lt $content.Count; $i++){
    $line = [string]$content[$i]
    if([string]::IsNullOrWhiteSpace($line)){ continue }
    if($line -match $placeholder){ continue }

    foreach($p in $patterns){
      $m = [regex]::Matches($line, $p.Regex)
      if($m.Count -gt 0){
        foreach($mm in $m){
          $hits.Add([PSCustomObject]@{
            Type = $p.Type
            Path = $file.FullName
            LineNumber = $i + 1
            Line = $line.Trim()
            Match = $mm.Value
          })
        }
      }
    }
  }
}

$hits = $hits | Sort-Object Path,LineNumber,Type,Match -Unique
$hits | ConvertTo-Json -Depth 6 | Set-Content -Path ".secret-scan-findings.json" -Encoding UTF8
Write-Output ("Scanned files: {0}" -f $files.Count)
Write-Output ("Findings count: {0}" -f $hits.Count)
$hits | Select-Object -First 120 Type,Path,LineNumber,Match | Format-Table -AutoSize | Out-String | Write-Output

