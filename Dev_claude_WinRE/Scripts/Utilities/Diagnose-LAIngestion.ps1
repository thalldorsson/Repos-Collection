# Diagnose-LAIngestion.ps1
# Troubleshoots Log Analytics ingestion issues from WinRE detector
# Author: Thorsteinn Halldorsson
# Date: 2025-12-12

param(
    [string]$WorkspaceId,
    [string]$WorkspaceKey,
    [string]$LogType = 'WinREHealthV2'
)

$ErrorActionPreference = 'Continue'
$WarningPreference = 'Continue'

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

# Fall back to environment variables if not provided
if ([string]::IsNullOrWhiteSpace($WorkspaceId)) {
    $WorkspaceId = $env:la_workspace_id
}
if ([string]::IsNullOrWhiteSpace($WorkspaceKey)) {
    $WorkspaceKey = $env:la_workspace_key
}

Write-Host "=== Log Analytics Ingestion Diagnostics ===" -ForegroundColor Cyan
Write-Host ""

# 1. Verify credentials provided
Write-Host "[1] Checking Credentials..." -ForegroundColor Yellow
if ([string]::IsNullOrWhiteSpace($WorkspaceId)) {
    Write-Host "❌ ERROR: Workspace ID not provided and env:la_workspace_id not set" -ForegroundColor Red
    Write-Host "   Fix: Run with -WorkspaceId 'xxxx' or set `$env:la_workspace_id" -ForegroundColor Yellow
    exit 1
}
if ([string]::IsNullOrWhiteSpace($WorkspaceKey)) {
    Write-Host "❌ ERROR: Workspace Key not provided and env:la_workspace_key not set" -ForegroundColor Red
    Write-Host "   Fix: Run with -WorkspaceKey 'xxxx' or set `$env:la_workspace_key" -ForegroundColor Yellow
    exit 1
}
Write-Host "✅ Workspace ID: $WorkspaceId" -ForegroundColor Green
Write-Host "✅ Workspace Key length: $($WorkspaceKey.Length) chars" -ForegroundColor Green
Write-Host ""

# 2. Validate base64 key
Write-Host "[2] Validating Workspace Key Format..." -ForegroundColor Yellow
try {
    $keyBytes = [Convert]::FromBase64String($WorkspaceKey)
    Write-Host "✅ Key is valid Base64 ($($keyBytes.Length) bytes)" -ForegroundColor Green
} catch {
    Write-Host "❌ ERROR: Workspace Key is not valid Base64" -ForegroundColor Red
    Write-Host "   Fix: Copy the SECONDARY key from Azure Portal > Log Analytics > Agents" -ForegroundColor Yellow
    exit 1
}
Write-Host ""

# 3. Network connectivity test
Write-Host "[3] Testing Network Connectivity..." -ForegroundColor Yellow
$endpoint = "$WorkspaceId.ods.opinsights.azure.com"
try {
    $dnsResult = [System.Net.Dns]::GetHostAddresses($endpoint)
    Write-Host "✅ DNS Resolution OK: $endpoint → $($dnsResult[0].IPAddressToString)" -ForegroundColor Green
} catch {
    Write-Host "❌ ERROR: Cannot resolve $endpoint" -ForegroundColor Red
    Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "   Fix: Check firewall, proxy, DNS settings" -ForegroundColor Yellow
    exit 1
}

try {
    $tcpResult = Test-NetConnection -ComputerName $endpoint -Port 443 -WarningAction SilentlyContinue
    if ($tcpResult.TcpTestSucceeded) {
        Write-Host "✅ TCP Port 443 (HTTPS) reachable" -ForegroundColor Green
    } else {
        Write-Host "⚠️  WARNING: TCP Port 443 may not be reachable" -ForegroundColor Yellow
        Write-Host "   Detailed result: $($tcpResult.TcpTestSucceeded)" -ForegroundColor Yellow
    }
} catch {
    Write-Host "⚠️  WARNING: Test-NetConnection failed (expected on some systems): $($_.Exception.Message)" -ForegroundColor Yellow
}
Write-Host ""

# 4. Test HMAC signature generation
Write-Host "[4] Testing HMAC Signature Generation..." -ForegroundColor Yellow
try {
    $testData = @{ test = "data"; timestamp = (Get-Date -Format o) }
    $json = $testData | ConvertTo-Json -Compress
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    
    $method = 'POST'
    $contentType = 'application/json'
    $resource = '/api/logs'
    $rfc1123date = [DateTime]::UtcNow.ToString('r')
    $xHeaders = "x-ms-date:${rfc1123date}"
    $stringToHash = "$method`n$($bodyBytes.Length)`n$contentType`n$xHeaders`n$resource"
    $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($WorkspaceKey)
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($keyBytes)
    $sigBytes = $hmac.ComputeHash($bytesToHash)
    $encodedHash = [Convert]::ToBase64String($sigBytes)
    $auth = ('SharedKey {0}:{1}' -f $WorkspaceId, $encodedHash)
    
    Write-Host "✅ HMAC-SHA256 signature generated" -ForegroundColor Green
    Write-Host "   Signature preview: $($auth.Substring(0, 50))..." -ForegroundColor Gray
} catch {
    Write-Host "❌ ERROR: Failed to generate HMAC signature" -ForegroundColor Red
    Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Yellow
    exit 1
}
Write-Host ""

# 5. Test actual API call
Write-Host "[5] Testing Log Analytics API Call..." -ForegroundColor Yellow

# Ensure TLS 1.2 is enabled
Write-Host "   Ensuring TLS 1.2 is enabled..." -ForegroundColor Gray
try {
    if ($PSVersionTable.PSVersion.Major -le 5) {
        $sp = [Net.ServicePointManager]::SecurityProtocol
        if (($sp -band [Net.SecurityProtocolType]::Tls12) -eq 0) {
            [Net.ServicePointManager]::SecurityProtocol = $sp -bor [Net.SecurityProtocolType]::Tls12
            Write-Host "✅ TLS 1.2 enabled" -ForegroundColor Green
        } else {
            Write-Host "✅ TLS 1.2 already enabled" -ForegroundColor Green
        }
    } else {
        Write-Host "✅ PowerShell Core detected - TLS 1.2+ is default" -ForegroundColor Green
    }
} catch {
    Write-Host "⚠️  WARNING: TLS 1.2 enforcement failed: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "   Continuing anyway..." -ForegroundColor Yellow
}
Write-Host ""

try {
    $testRecord = @{
        ComputerName = $env:COMPUTERNAME
        Timestamp = (Get-Date -Format o)
        TestMessage = "Diagnostic test at $(Get-Date)"
        DiagnosticTest = $true
    }
    
    $records = @($testRecord)
    $json = $records | ConvertTo-Json -Depth 12 -Compress
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    
    $method = 'POST'
    $contentType = 'application/json'
    $resource = '/api/logs'
    $rfc1123date = [DateTime]::UtcNow.ToString('r')
    $xHeaders = "x-ms-date:${rfc1123date}"
    $stringToHash = "$method`n$($bodyBytes.Length)`n$contentType`n$xHeaders`n$resource"
    $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($WorkspaceKey)
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($keyBytes)
    $sigBytes = $hmac.ComputeHash($bytesToHash)
    $encodedHash = [Convert]::ToBase64String($sigBytes)
    $auth = ('SharedKey {0}:{1}' -f $WorkspaceId, $encodedHash)
    
    $uriBuilder = [System.UriBuilder]::new()
    $uriBuilder.Scheme = 'https'
    $uriBuilder.Host = "$WorkspaceId.ods.opinsights.azure.com"
    $uriBuilder.Path = $resource.TrimStart('/')
    $uriBuilder.Query = 'api-version=2016-04-01'
    $uriObj = $uriBuilder.Uri
    
    Write-Host "   URI: $($uriObj.AbsoluteUri)" -ForegroundColor Gray
    Write-Host "   Payload size: $($bodyBytes.Length) bytes" -ForegroundColor Gray
    Write-Host "   Log type: $LogType" -ForegroundColor Gray
    
    $headers = @{
        'Authorization' = $auth
        'Log-Type' = $LogType
        'x-ms-date' = $rfc1123date
        'time-generated-field' = 'Timestamp'
    }
    
    $response = Invoke-RestMethod -Method $method -Uri $uriObj -Headers $headers `
        -ContentType $contentType -Body $bodyBytes -TimeoutSec 30 -ErrorAction Stop
    
    Write-Host "✅ API call successful (HTTP 200)" -ForegroundColor Green
    Write-Host "   Response: $response" -ForegroundColor Gray
} catch {
    $statusCode = $_.Exception.Response.StatusCode.Value__ 2>$null
    $reasonPhrase = $_.Exception.Response.ReasonPhrase 2>$null
    
    Write-Host "❌ ERROR: API call failed" -ForegroundColor Red
    Write-Host "   HTTP Status: $statusCode - $reasonPhrase" -ForegroundColor Yellow
    Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Yellow
    
    # Provide specific troubleshooting for common status codes
    switch ($statusCode) {
        401 {
            Write-Host "   Cause: Authentication failed (invalid workspace ID or key)" -ForegroundColor Yellow
            Write-Host "   Fix: Verify Workspace ID and Key from Azure Portal" -ForegroundColor Yellow
        }
        403 {
            Write-Host "   Cause: Access denied (permissions issue)" -ForegroundColor Yellow
            Write-Host "   Fix: Ensure key has read/write permissions in Log Analytics" -ForegroundColor Yellow
        }
        404 {
            Write-Host "   Cause: Endpoint not found (invalid workspace)" -ForegroundColor Yellow
            Write-Host "   Fix: Verify Workspace ID is correct and exists" -ForegroundColor Yellow
        }
        429 {
            Write-Host "   Cause: Rate throttled (too many requests)" -ForegroundColor Yellow
            Write-Host "   Fix: Reduce frequency of ingestion or check LA pricing tier" -ForegroundColor Yellow
        }
        500 {
            Write-Host "   Cause: Server error (Azure service issue)" -ForegroundColor Yellow
            Write-Host "   Fix: Retry later or check Azure service status" -ForegroundColor Yellow
        }
    }
    
    Write-Host ""
    Write-Host "   Full error response:" -ForegroundColor Yellow
    try {
        $streamReader = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
        $errorBody = $streamReader.ReadToEnd()
        $streamReader.Close()
        Write-Host "   $errorBody" -ForegroundColor Gray
    } catch {}
    
    exit 1
}
Write-Host ""

# 6. Query recent ingested data
Write-Host "[6] Querying Recent Ingested Data..." -ForegroundColor Yellow
Write-Host "   (Typically 5-15 minutes delay before data appears in queries)" -ForegroundColor Gray

# Build KQL query to check table existence
$kqlQuery = @"
WinREHealth_CL
| where TimeGenerated > ago(24h)
| summarize Count=count(), Latest=max(TimeGenerated)
| project Count, Latest
"@

Write-Host "   KQL Query: WinREHealth_CL | where TimeGenerated > ago(24h) | summarize..." -ForegroundColor Gray
Write-Host ""
Write-Host "   To verify data ingestion manually:" -ForegroundColor Cyan
Write-Host "   1. Go to Azure Portal > Log Analytics Workspace > Logs" -ForegroundColor Cyan
Write-Host "   2. Paste query: WinREHealth_CL | where TimeGenerated > ago(1h) | top 10 by TimeGenerated" -ForegroundColor Cyan
Write-Host "   3. Run query and check if data appears" -ForegroundColor Cyan
Write-Host ""

# 7. Summary
Write-Host "[7] Troubleshooting Summary" -ForegroundColor Yellow
Write-Host ""
Write-Host "Common causes of LA ingestion failure:" -ForegroundColor Cyan
Write-Host "  1. Invalid Workspace ID or Key (check Azure Portal)" -ForegroundColor White
Write-Host "  2. Network connectivity issue (firewall, proxy blocking HTTPS)" -ForegroundColor White
Write-Host "  3. Workspace Key is wrong (should be SECONDARY key, not primary)" -ForegroundColor White
Write-Host "  4. Table schema mismatch (custom field names don't match LogType)" -ForegroundColor White
Write-Host "  5. Log Analytics workspace doesn't exist or is deleted" -ForegroundColor White
Write-Host "  6. Credentials are not being passed to detector script" -ForegroundColor White
Write-Host ""

Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Check NinjaOne Script Variables (LA_WORKSPACE_ID, LA_WORKSPACE_KEY) are set" -ForegroundColor White
Write-Host "  2. Run detector with verbose logging: Set `$env:winre_testmode='true'" -ForegroundColor White
Write-Host "  3. Check detector logs in C:\ProgramData\WinREHealth\WinREHealthDetection.log" -ForegroundColor White
Write-Host "  4. Verify table WinREHealth_CL exists in Log Analytics workspace" -ForegroundColor White
Write-Host "  5. If data is old, check device clocks are synchronized with Azure" -ForegroundColor White
Write-Host ""

Write-Host "✅ Diagnostic complete" -ForegroundColor Green
