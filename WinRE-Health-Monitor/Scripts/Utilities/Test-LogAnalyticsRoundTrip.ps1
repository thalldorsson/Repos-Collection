#Requires -Version 5.1
<#
.SYNOPSIS
  Sends a test record to Log Analytics (Data Collector API) and queries it back (Log Analytics Query API).

.DESCRIPTION
  1) Ingests a single JSON record using the Log Analytics HTTP Data Collector API (workspace id + shared key).
  2) Polls Log Analytics Query API until the record appears (requires an Entra ID access token for https://api.loganalytics.io/).

  This is intended as a lightweight, end-to-end "round trip" validation for WinRE Health monitoring ingestion.

.PARAMETER WorkspaceId
  Log Analytics Workspace ID (a GUID). If omitted, falls back to $env:la_workspace_id.

.PARAMETER WorkspaceKey
  Log Analytics Workspace shared key (Base64). If omitted, falls back to $env:la_workspace_key.

.PARAMETER LogType
  The Data Collector Log-Type header. Custom table becomes <LogType>_CL. Default: WinREHealth
.PARAMETER TableName
  Override the table name to query (defaults to <LogType>_CL).

.PARAMETER UseAzAccount
  If set (default), attempts to acquire a token using Az.Accounts (Get-AzAccessToken).

.PARAMETER AccessToken
  Optional Bearer token for Log Analytics Query API. If provided, Az.Accounts is not required.

.PARAMETER PollSeconds
  Total time to wait for the record to appear in queries (ingestion/query delay is normal). Default: 600

.PARAMETER PollIntervalSeconds
  Seconds between query attempts. Default: 30

.PARAMETER SkipQuery
  If set, only sends the record and prints the KQL query to run manually.

.EXAMPLE
  # Using env vars (recommended for local testing)
  $env:la_workspace_id  = '<workspace-guid>'
  $env:la_workspace_key = '<base64-key>'
  .\Scripts\Utilities\Test-LogAnalyticsRoundTrip.ps1

.EXAMPLE
  # Explicit parameters, query using your current Az login
  .\Scripts\Utilities\Test-LogAnalyticsRoundTrip.ps1 -WorkspaceId '<id>' -WorkspaceKey '<key>' -LogType 'WinREHealth'

  NOTE: Do NOT paste real Workspace IDs/Keys into this script. Use environment variables or secure secret storage.
.EXAMPLE
  # Provide your own token (no Az module needed)
  .\Scripts\Utilities\Test-LogAnalyticsRoundTrip.ps1 -AccessToken '<jwt>' -WorkspaceId '<id>' -WorkspaceKey '<key>'
#>

[CmdletBinding()]
param(
  [string]$WorkspaceId,
  [string]$WorkspaceKey,
  [string]$LogType = 'WinREHealthV2',
  [string]$TableName,
  [switch]$UseAzAccount = $true,
  [string]$AccessToken,
  [string]$TenantId,
  [switch]$ShowCredentials,
  [switch]$RevealWorkspaceKey,
  [ValidateSet('Auto','AzOperationalInsights','LogAnalyticsApi')]
  [string]$QueryMethod = 'Auto',
  [switch]$ShowTokenClaims,
  [switch]$UseAzureComEndpoint,
  [ValidateRange(0, 86400)]
  [int]$PollSeconds = 600,
  [ValidateRange(1, 3600)]
  [int]$PollIntervalSeconds = 30,
  [switch]$SkipQuery
)

$ErrorActionPreference = 'Stop'

# Load .env file if it exists (for local testing)
$envFile = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) '.env'
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        $line = $_.Trim()
        if (-not [string]::IsNullOrWhiteSpace($line) -and -not $line.StartsWith('#')) {
            if ($line -match '^([^=]+)=(.*)$') {
                $key = $matches[1].Trim()
                $value = $matches[2].Trim()
                # Remove quotes if present
                if (($value.StartsWith('"') -and $value.EndsWith('"')) -or 
                    ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                    $value = $value.Substring(1, $value.Length - 2)
                }
                [System.Environment]::SetEnvironmentVariable($key, $value, [System.EnvironmentVariableTarget]::Process)
            }
        }
    }
}

function New-LogAnalyticsSignature {
  param(
    [Parameter(Mandatory=$true)][string]$WorkspaceId,
    [Parameter(Mandatory=$true)][string]$WorkspaceKey,
    [Parameter(Mandatory=$true)][string]$Method,
    [Parameter(Mandatory=$true)][string]$ContentType,
    [Parameter(Mandatory=$true)][string]$Resource,
    [Parameter(Mandatory=$true)][byte[]]$BodyBytes,
    [Parameter(Mandatory=$true)][string]$Rfc1123Date
  )

  $xHeaders = "x-ms-date:$Rfc1123Date"
  $stringToHash = "$Method`n$($BodyBytes.Length)`n$ContentType`n$xHeaders`n$Resource"

  $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
  $keyBytes = [Convert]::FromBase64String($WorkspaceKey)
  $hmac = [System.Security.Cryptography.HMACSHA256]::new($keyBytes)
  $sigBytes = $hmac.ComputeHash($bytesToHash)
  $encodedHash = [Convert]::ToBase64String($sigBytes)

  return ('SharedKey {0}:{1}' -f $WorkspaceId, $encodedHash)
}

function Send-LogAnalyticsRecord {
  param(
    [Parameter(Mandatory=$true)][string]$WorkspaceId,
    [Parameter(Mandatory=$true)][string]$WorkspaceKey,
    [Parameter(Mandatory=$true)][string]$LogType,
    [Parameter(Mandatory=$true)][hashtable]$Record,
    [string]$TimeGeneratedField = 'Timestamp'
  )

  # PowerShell 5.1 on older hosts may default to TLS 1.0/1.1. The Data Collector API requires TLS 1.2.
  try {
    if ($PSVersionTable.PSVersion.Major -le 5) {
      $sp = [Net.ServicePointManager]::SecurityProtocol
      if (($sp -band [Net.SecurityProtocolType]::Tls12) -eq 0) {
        [Net.ServicePointManager]::SecurityProtocol = $sp -bor [Net.SecurityProtocolType]::Tls12
      }
    }
  } catch {
    # best-effort only
  }

  $resource = '/api/logs'
  $contentType = 'application/json'
  $method = 'POST'

  $records = @($Record)
  $json = $records | ConvertTo-Json -Depth 12 -Compress
  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($json)

  $rfc1123date = [DateTime]::UtcNow.ToString('r')
  $auth = New-LogAnalyticsSignature -WorkspaceId $WorkspaceId -WorkspaceKey $WorkspaceKey -Method $method -ContentType $contentType -Resource $resource -BodyBytes $bodyBytes -Rfc1123Date $rfc1123date

  $uri = "https://$WorkspaceId.ods.opinsights.azure.com/api/logs?api-version=2016-04-01"

  $headers = @{
    'Authorization' = $auth
    'Log-Type'      = $LogType
    'x-ms-date'     = $rfc1123date
    'time-generated-field' = $TimeGeneratedField
  }

  try {
    Invoke-RestMethod -Method $method -Uri $uri -Headers $headers -ContentType $contentType -Body $bodyBytes -TimeoutSec 30 | Out-Null
    return $true
  }
  catch {
    $statusCode = $_.Exception.Response.StatusCode.Value__ 2>$null
    $reasonPhrase = $_.Exception.Response.ReasonPhrase 2>$null
    Write-Error ("Log Analytics ingestion failed (HTTP {0} {1}): {2}" -f $statusCode, $reasonPhrase, $_.Exception.Message)
    throw
  }
}

function Convert-LAQueryResponseToObjects {
  param(
    [Parameter(Mandatory=$true)]$Response
  )

  if (-not $Response.tables -or $Response.tables.Count -lt 1) {
    return @()
  }

  $table = $Response.tables[0]
  $colNames = @($table.columns | ForEach-Object { $_.name })

  $objects = @()
  foreach ($row in $table.rows) {
    $o = [ordered]@{}
    for ($i = 0; $i -lt $colNames.Count; $i++) {
      $o[$colNames[$i]] = $row[$i]
    }
    $objects += [pscustomobject]$o
  }

  return $objects
}

function Get-LogAnalyticsAccessToken {
  param(
    [switch]$UseAzAccount,
    [string]$AccessToken,
    [string]$TenantId
  )

  if (-not [string]::IsNullOrWhiteSpace($AccessToken)) {
    return $AccessToken
  }

  if (-not $UseAzAccount) {
    return $null
  }

  try {
    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
      return $null
    }

    Import-Module Az.Accounts -ErrorAction Stop | Out-Null

    # This uses your current Az context/session. If you are not logged in, run Connect-AzAccount first.
    # Try both URL variants (some environments behave differently with trailing slash).
    $resourceUrls = @('https://api.loganalytics.io', 'https://api.loganalytics.io/')

    foreach ($ru in $resourceUrls) {
      try {
        if ([string]::IsNullOrWhiteSpace($TenantId)) {
          $token = Get-AzAccessToken -ResourceUrl $ru -ErrorAction Stop
        } else {
          $token = Get-AzAccessToken -ResourceUrl $ru -TenantId $TenantId -ErrorAction Stop
        }

        if ($token -and -not [string]::IsNullOrWhiteSpace($token.Token)) {
          return $token.Token
        }
      } catch {
        # continue
      }
    }

    return $null
  }
  catch {
    return $null
  }
}

function ConvertFrom-Base64Url {
  param([Parameter(Mandatory=$true)][string]$Value)
  $s = $Value.Replace('-', '+').Replace('_', '/')
  switch ($s.Length % 4) {
    2 { $s += '==' }
    3 { $s += '=' }
    0 { }
    default { }
  }
  return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s))
}

function Get-JwtClaimsSummary {
  param([Parameter(Mandatory=$true)][string]$Jwt)
  try {
    $parts = $Jwt.Split('.')
    if ($parts.Count -lt 2) { return $null }
    $payloadJson = ConvertFrom-Base64Url -Value $parts[1]
    $payload = $payloadJson | ConvertFrom-Json

    $expUtc = $null
    if ($payload.exp) {
      $expUtc = [DateTimeOffset]::FromUnixTimeSeconds([int64]$payload.exp).UtcDateTime
    }

    return [pscustomobject]@{
      aud = $payload.aud
      tid = $payload.tid
      appid = $payload.appid
      upn = $payload.upn
      oid = $payload.oid
      expUtc = $expUtc
    }
  } catch {
    return $null
  }
}

function Get-MaskedSecret {
  param([Parameter(Mandatory=$true)][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return '<missing>' }
  $len = $Value.Length
  if ($len -le 8) { return ('*' * $len) }
  $prefix = $Value.Substring(0,4)
  $suffix = $Value.Substring($len - 4, 4)
  $maskLen = [Math]::Max(4, $len - 8)
  $mask = -join ((1..$maskLen) | ForEach-Object { '*' })
  return "$prefix$mask$suffix"
}

function Invoke-LogAnalyticsQueryViaAzOperationalInsights {
  param(
    [Parameter(Mandatory=$true)][string]$WorkspaceId,
    [Parameter(Mandatory=$true)][string]$Query
  )

  if (-not (Get-Module -ListAvailable -Name Az.OperationalInsights)) {
    throw 'Az.OperationalInsights module not available for query fallback.'
  }

  Import-Module Az.OperationalInsights -ErrorAction Stop | Out-Null

  # Invoke-AzOperationalInsightsQuery uses ARM-backed auth/RBAC and often avoids api.loganalytics.io token issues.
  # If WorkspaceId is just a GUID, it may fail with BadRequest. Try to use it directly first; if it fails, suggest the full ARM resource ID.
  try {
    $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $Query -ErrorAction Stop
    if ($null -eq $result -or $null -eq $result.Results) {
      return @()
    }
    return @($result.Results)
  }
  catch {
    $errText = $_.Exception.Message
    if ($errText -match 'BadRequest|workspace') {
      Write-Warning "Query failed with BadRequest using WorkspaceId '$WorkspaceId'. Attempting to resolve full ARM resource ID and retry..."
      try {
        if (-not (Get-Module -ListAvailable -Name Az.OperationalInsights)) { throw 'Az.OperationalInsights not available.' }
        Import-Module Az.OperationalInsights -ErrorAction Stop | Out-Null
        $workspaces = Get-AzOperationalInsightsWorkspace -ErrorAction Stop
        $match = $null
        # Match either by CustomerId GUID or by ResourceId equality if a resourceId was passed
        foreach ($ws in $workspaces) {
          if ($ws.CustomerId -eq $WorkspaceId -or $ws.ResourceId -eq $WorkspaceId) { $match = $ws; break }
        }
        if ($null -ne $match -and -not [string]::IsNullOrWhiteSpace($match.ResourceId)) {
          Write-Host "Retrying query with ResourceId: $($match.ResourceId)" -ForegroundColor Gray
          $result2 = Invoke-AzOperationalInsightsQuery -WorkspaceId $match.ResourceId -Query $Query -ErrorAction Stop
          if ($null -ne $result2 -and $null -ne $result2.Results) { return @($result2.Results) }
          return @()
        } else {
          Write-Warning "Unable to resolve workspace ResourceId automatically. Ensure you have access and consider supplying the full ResourceId."
        }
      } catch {
        Write-Warning "ResourceId resolution or retry failed: $($_.Exception.Message)"
      }
      Write-Warning "Original error: $errText"
    }
    throw
  }
}

function Invoke-LogAnalyticsQuery {
  param(
    [Parameter(Mandatory=$true)][string]$WorkspaceId,
    [Parameter(Mandatory=$true)][string]$Token,
    [Parameter(Mandatory=$true)][string]$Query
  )

  # PowerShell 5.1 compatible conditional (no ternary operator)
  if ($UseAzureComEndpoint.IsPresent) {
    $base = 'https://api.loganalytics.azure.com'
  } else {
    $base = 'https://api.loganalytics.io'
  }
  $uri = "$base/v1/workspaces/$WorkspaceId/query"
  $headers = @{ Authorization = "Bearer $Token" }
  $body = @{ query = $Query } | ConvertTo-Json -Compress

  try {
    $resp = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 60
    return (Convert-LAQueryResponseToObjects -Response $resp)
  }
  catch {
    $statusCode = $_.Exception.Response.StatusCode.Value__ 2>$null
    $reasonPhrase = $_.Exception.Response.ReasonPhrase 2>$null
    $bodyText = $null
    try {
      $responseBody = $_.Exception.Response.GetResponseStream()
      if ($responseBody) {
        $reader = [System.IO.StreamReader]::new($responseBody)
        $bodyText = $reader.ReadToEnd()
        $reader.Close()
      }
    } catch { }
    
    $errorMsg = "Log Analytics Query failed (HTTP $statusCode $reasonPhrase)"
    if ($bodyText) { $errorMsg += ": $bodyText" }
    
    Write-Warning $errorMsg
    throw $errorMsg
  }
}

# --- Resolve inputs ---
$workspaceIdSource = $null
$workspaceKeySource = $null

if ([string]::IsNullOrWhiteSpace($WorkspaceId)) {
  if (-not [string]::IsNullOrWhiteSpace($env:la_workspace_id)) {
    $WorkspaceId = $env:la_workspace_id
    $workspaceIdSource = 'env:la_workspace_id'
  } elseif (-not [string]::IsNullOrWhiteSpace($env:LA_WORKSPACE_ID)) {
    $WorkspaceId = $env:LA_WORKSPACE_ID
    $workspaceIdSource = 'env:LA_WORKSPACE_ID'
  }
}

if ([string]::IsNullOrWhiteSpace($WorkspaceKey)) {
  if (-not [string]::IsNullOrWhiteSpace($env:la_workspace_key)) {
    $WorkspaceKey = $env:la_workspace_key
    $workspaceKeySource = 'env:la_workspace_key'
  } elseif (-not [string]::IsNullOrWhiteSpace($env:LA_WORKSPACE_KEY)) {
    $WorkspaceKey = $env:LA_WORKSPACE_KEY
    $workspaceKeySource = 'env:LA_WORKSPACE_KEY'
  }
}

if ([string]::IsNullOrWhiteSpace($WorkspaceId)) {
  throw 'WorkspaceId is required (param -WorkspaceId or env:la_workspace_id / env:LA_WORKSPACE_ID).'
}
if ([string]::IsNullOrWhiteSpace($WorkspaceKey)) {
  throw 'WorkspaceKey is required (param -WorkspaceKey or env:la_workspace_key / env:LA_WORKSPACE_KEY).'
}

# Validate workspace ID format (must be a GUID)
if ($WorkspaceId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
  throw "WorkspaceId format is invalid. Expected GUID format (e.g., 12345678-1234-1234-1234-123456789012), got: $WorkspaceId"
}

# Validate workspace key is Base64
try {
  $keyBytes = [Convert]::FromBase64String($WorkspaceKey)
  if ($keyBytes.Length -lt 32) {
    Write-Warning "WorkspaceKey seems too short ($($keyBytes.Length) bytes). Ensure you copied the full key from Azure Portal."
  }
} catch {
  throw "WorkspaceKey is not valid Base64. Ensure you copied the entire key from Azure Portal > Log Analytics > Agents."
}

if ([string]::IsNullOrWhiteSpace($TableName)) { $TableName = "${LogType}_CL" }

$testId = [Guid]::NewGuid().ToString()
$nowUtc = (Get-Date).ToUniversalTime().ToString('o')

$record = [ordered]@{
  ComputerName = $env:COMPUTERNAME
  Timestamp    = $nowUtc
  TestId       = $testId
  TestMessage  = "Log Analytics round-trip test at $nowUtc"
  Source       = 'Test-LogAnalyticsRoundTrip.ps1'
}

Write-Host "=== Log Analytics Round Trip Test ===" -ForegroundColor Cyan
Write-Host "WorkspaceId: $WorkspaceId" -ForegroundColor Gray
Write-Host "LogType:     $LogType (table: $TableName)" -ForegroundColor Gray
Write-Host "TestId:      $testId" -ForegroundColor Gray
if ($workspaceIdSource) { Write-Host "WorkspaceId source: $workspaceIdSource" -ForegroundColor DarkGray }
if ($workspaceKeySource) { Write-Host "WorkspaceKey source: $workspaceKeySource" -ForegroundColor DarkGray }
Write-Host "" 

# Optionally display credentials for troubleshooting. Key is masked by default unless -RevealWorkspaceKey specified.
if ($ShowCredentials) {
  Write-Host "--- Credentials (diagnostic) ---" -ForegroundColor Yellow
  Write-Host "WorkspaceId: $WorkspaceId" -ForegroundColor Gray
  if ($RevealWorkspaceKey) {
    Write-Host "WorkspaceKey: $WorkspaceKey" -ForegroundColor Gray
  } else {
    $maskedKey = Get-MaskedSecret $WorkspaceKey
    $keyLen = if ($null -ne $WorkspaceKey) { $WorkspaceKey.Length } else { 0 }
    Write-Host "WorkspaceKey: $maskedKey (length: $keyLen chars)" -ForegroundColor Gray
  }
  Write-Host "" 
}

Write-Host "[1/2] Sending test record to Data Collector API..." -ForegroundColor Yellow
$sent = Send-LogAnalyticsRecord -WorkspaceId $WorkspaceId -WorkspaceKey $WorkspaceKey -LogType $LogType -Record $record
if ($sent) {
  Write-Host "[OK] Sent successfully (HTTP 200)." -ForegroundColor Green
}

# KQL uses the suffix convention for custom tables (e.g., TestId_g). This is the most reliable way to match.
$kql = "$TableName | where TimeGenerated > ago(2h) | where TestId_g == `"$testId`" | top 5 by TimeGenerated desc"

Write-Host "" 
Write-Host "KQL to verify:" -ForegroundColor Cyan
Write-Host $kql -ForegroundColor White

if ($SkipQuery) {
  Write-Host "" 
  Write-Host "Skipping query step (-SkipQuery specified)." -ForegroundColor Yellow
  exit 0
}

Write-Host "" 
Write-Host "[2/2] Querying Log Analytics (may take several minutes for data to appear)..." -ForegroundColor Yellow

$effectiveQueryMethod = $QueryMethod
if ($effectiveQueryMethod -eq 'Auto') {
  # Prefer ARM-backed query cmdlet if available; it's less sensitive to api.loganalytics.io audience/tenant issues.
  if (Get-Module -ListAvailable -Name Az.OperationalInsights) {
    $effectiveQueryMethod = 'AzOperationalInsights'
  } else {
    $effectiveQueryMethod = 'LogAnalyticsApi'
  }
}

$token = $null
if ($effectiveQueryMethod -eq 'LogAnalyticsApi') {
  $token = Get-LogAnalyticsAccessToken -UseAzAccount:$UseAzAccount -AccessToken $AccessToken -TenantId $TenantId
  if ([string]::IsNullOrWhiteSpace($token)) {
    Write-Warning "No access token available for Log Analytics Query API (api.loganalytics.io)."
    Write-Warning "Options:"
    Write-Warning "  - Login and use Az.Accounts: Connect-AzAccount (optionally -TenantId), then rerun."
    Write-Warning "  - Provide -AccessToken (token) for resource https://api.loganalytics.io/."
    Write-Warning "  - Or rerun with -QueryMethod AzOperationalInsights (requires Az.OperationalInsights)."
    Write-Warning "  - Or rerun with -SkipQuery and execute the KQL manually in the portal."
    exit 2
  }

  if ($ShowTokenClaims) {
    $claims = Get-JwtClaimsSummary -Jwt $token
    if ($claims) {
      Write-Host "Token claims (summary): aud=$($claims.aud) tid=$($claims.tid) expUtc=$($claims.expUtc)" -ForegroundColor Gray
    } else {
      Write-Host "Token claims (summary): <unavailable>" -ForegroundColor Gray
    }
  }
}

$deadline = (Get-Date).AddSeconds($PollSeconds)
$attempt = 0
$found = @()

while ((Get-Date) -lt $deadline) {
  $attempt++
  try {
    if ($effectiveQueryMethod -eq 'AzOperationalInsights') {
      $found = Invoke-LogAnalyticsQueryViaAzOperationalInsights -WorkspaceId $WorkspaceId -Query $kql
    } else {
      $found = Invoke-LogAnalyticsQuery -WorkspaceId $WorkspaceId -Token $token -Query $kql
    }
  } catch {
    $msg = $_.Exception.Message

    # Improve common troubleshooting for 401 from api.loganalytics.io
    if ($msg -match '401') {
      Write-Warning "Query attempt $attempt failed: $msg"
      if ($effectiveQueryMethod -eq 'LogAnalyticsApi') {
        Write-Warning "401 usually means the token is not accepted (wrong tenant/audience) or you lack access via the current identity."
        Write-Warning "Try: Connect-AzAccount -Tenant <tenantId>; ensure you have Log Analytics Reader/Contributor on this workspace."
        Write-Warning "Or rerun with: -QueryMethod AzOperationalInsights (ARM-backed)."
      }
    } else {
      Write-Warning "Query attempt $attempt failed: $msg"
    }

    $found = @()
  }

  if ($found -and $found.Count -gt 0) {
    Write-Host "[OK] Found $($found.Count) matching record(s) in Log Analytics." -ForegroundColor Green
    $found | Select-Object -First 5 | Format-Table -AutoSize | Out-String | Write-Host
    exit 0
  }

  Write-Host "No results yet (attempt $attempt). Waiting $PollIntervalSeconds seconds..." -ForegroundColor Gray
  Start-Sleep -Seconds $PollIntervalSeconds
}

Write-Warning "Timed out after $PollSeconds seconds. Ingestion may still be processing."
Write-Warning "Run the KQL above in Log Analytics Logs, or rerun with larger -PollSeconds (e.g., 1200)."
exit 3
