function Send-ToLogAnalytics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Alias('Record','Payload')]
        [object]$Data,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceId,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceKey,

        [Parameter()]
        [string]$LogType = 'WinREHealth',

        [Parameter()]
        [string]$TimeGeneratedField = 'Timestamp',

        [Parameter()]
        [int]$RetryCount = 3,

        [Parameter()]
        [int]$RetryDelaySeconds = 2
    )

    try {
        # Ensure array body as expected by the Data Collector API
        $records = @()
        if ($null -ne $Data) {
            if ($Data -is [System.Collections.IEnumerable] -and -not ($Data -is [string])) {
                $records = @($Data)
            } else {
                $records = @($Data)
            }
        }

        $json = $records | ConvertTo-Json -Depth 15 -Compress
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($json)

        $method = 'POST'
        $contentType = 'application/json'
        $resource = '/api/logs'

        $attempt = 0
        do {
            $attempt++
            $rfc1123date = [DateTime]::UtcNow.ToString('r')
            $xHeaders = "x-ms-date:$rfc1123date"
            $stringToHash = "$method`n$($bodyBytes.Length)`n$contentType`n$xHeaders`n$resource"

            $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
            $keyBytes = [Convert]::FromBase64String($WorkspaceKey)
            $hmac = [System.Security.Cryptography.HMACSHA256]::new($keyBytes)
            $signatureBytes = $hmac.ComputeHash($bytesToHash)
            $encodedHash = [Convert]::ToBase64String($signatureBytes)
            $authorization = "SharedKey $WorkspaceId:$encodedHash"

            $uri = "https://$WorkspaceId.ods.opinsights.azure.com$resource?api-version=2016-04-01"
            $headers = @{
                'Authorization'        = $authorization
                'Log-Type'             = $LogType
                'x-ms-date'            = $rfc1123date
                'time-generated-field' = $TimeGeneratedField
            }

            try {
                $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $bodyBytes -UseBasicParsing -ErrorAction Stop
                if ($response.StatusCode -eq 200) {
                    Write-Verbose "Send-ToLogAnalytics: success (attempt $attempt)."
                    return $true
                } else {
                    Write-Verbose "Send-ToLogAnalytics: non-200 status $($response.StatusCode) (attempt $attempt)."
                }
            } catch {
                $status = $_.Exception.Response.StatusCode.Value__ 2>$null
                $isRetryable = $false
                if ($status -ge 500 -or $status -eq 408 -or $status -eq 429) { $isRetryable = $true }
                if ($attempt -lt $RetryCount -and $isRetryable) {
                    Start-Sleep -Seconds $RetryDelaySeconds
                } else {
                    throw $_
                }
            }
        } while ($attempt -lt $RetryCount)

        return $false
    } catch {
        Write-Verbose ("Send-ToLogAnalytics: failure - " + $_.Exception.Message)
        return $false
    }
}

# End of file
