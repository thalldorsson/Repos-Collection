$patterns = [ordered]@{
  "BEGIN_PRIVATE_KEY" = "BEGIN PRIVATE KEY"
  "AWS_AKIA" = "AKIA[0-9A-Z]{16}"
  "AWS_ASIA" = "ASIA[0-9A-Z]{16}"
  "GITHUB_GHP" = "ghp_[A-Za-z0-9]{36,}"
  "GITHUB_PAT" = "github_pat_[A-Za-z0-9_]{20,}"
  "SLACK_TOKEN" = "xox[baprs]-"
  "GOOGLE_API_KEY" = "AIzaSy[0-9A-Za-z-_]{20,}"
  "AZURE_CONN_STRING" = "DefaultEndpointsProtocol=.*AccountKey="
  "ACCOUNT_KEY" = "AccountKey="
  "SHARED_ACCESS_KEY" = "SharedAccessKey="
  "ENDPOINT_KEY" = "Endpoint=.*;Key="
  "PASSWORD_ASSIGN" = "(?i)\\bPassword\\b\\s*[:=]\\s*[\"''`]?[^\\s\"''`;]{6,}"
  "PWD_ASSIGN" = "(?i)\\bpwd\\b\\s*[:=]\\s*[\"''`]?[^\\s\"''`;]{6,}"
  "CLIENT_SECRET" = "(?i)\\bclient_secret\\b\\s*[:=]\\s*[\"''`]?[^\\s\"''`;]{6,}"
  "SECRET_KEY" = "(?i)\\bsecret_key\\b\\s*[:=]\\s*[\"''`]?[^\\s\"''`;]{6,}"
  "API_KEY_ASSIGN" = "(?i)\\bapi[_-]?key\\b\\s*[:=]\\s*[\"''`]?[^\\s\"''`;]{6,}"
  "TOKEN_ASSIGN" = "(?i)\\btoken\\b\\s*[:=]\\s*[\"''`]?[^\\s\"''`;]{6,}"
}
$placeholder = "(?i)(YOUR_KEY_HERE|example|dummy|test|sample|placeholder|fake|notreal|changeme|<[^>]*key[^>]*>)"
$exclude = "\\\\(node_modules|\\.git|dist|build|bin|obj)\\\\"
$results = New-Object System.Collections.Generic.List[string]
Get-ChildItem -Recurse -File -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -notmatch $exclude } |
  ForEach-Object {
    $rel = Resolve-Path -LiteralPath $_.FullName -Relative
    $lineNo = 0
    Get-Content -LiteralPath $_.FullName -ErrorAction SilentlyContinue | ForEach-Object {
      $lineNo++
      $line = $_
      if([string]::IsNullOrWhiteSpace($line)){ return }
      foreach($p in $patterns.GetEnumerator()){
        if([regex]::IsMatch($line, $p.Value)){
          if($line -match $placeholder){ continue }
          $snippet = $line.Trim()
          if($snippet.Length -gt 220){ $snippet = $snippet.Substring(0,220) }
          $results.Add("$rel:$lineNo:$($p.Key):$snippet")
        }
      }
    }
  }
$results | Sort-Object -Unique
