function Write-FinOpsAuditLog {
    <#
    .SYNOPSIS
        Writes audit log entries for compliance and security tracking.
    
    .DESCRIPTION
        Records audit trail for all significant operations including onboarding starts,
        completions, failures, and configuration changes. Audit logs include user,
        machine, timestamp, action, resource, and detailed context.
        
        Audit logs are written in JSON Lines format for easy ingestion into SIEM
        systems, Log Analytics, or Splunk.
    
    .PARAMETER Action
        Action being performed (e.g., 'OnboardingStarted', 'OnboardingCompleted').
    
    .PARAMETER Resource
        Resource being acted upon (e.g., customer name, tenant ID).
    
    .PARAMETER Details
        Additional structured details about the action.
    
    .PARAMETER User
        User performing the action. Defaults to current Windows user.
    
    .PARAMETER Success
        Whether the action was successful. Default is true.
    
    .PARAMETER CorrelationId
        Optional correlation ID to link related audit entries.
    
    .EXAMPLE
        Write-FinOpsAuditLog -Action 'OnboardingStarted' -Resource 'Contoso' -Details @{
            TenantId = '12345678-1234-1234-1234-123456789012'
            SubscriptionCount = 15
        }
    
    .EXAMPLE
        Write-FinOpsAuditLog -Action 'OnboardingFailed' -Resource 'Fabrikam' -Success $false -Details @{
            Error = 'Authentication failed'
            Duration = 45.2
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Action,
        
        [Parameter(Mandatory)]
        [string]$Resource,
        
        [Parameter()]
        [hashtable]$Details = @{},
        
        [Parameter()]
        [string]$User = $env:USERNAME,
        
        [Parameter()]
        [bool]$Success = $true,
        
        [Parameter()]
        [string]$CorrelationId
    )
    
    # Initialize audit log settings if not set
    if (-not $script:FinOpsAuditSettings) {
        $script:FinOpsAuditSettings = @{
            Enabled = $true
            AuditFilePath = $null
            SendToLogAnalytics = $false
            WorkspaceId = $null
            SharedKey = $null
        }
    }
    
    if (-not $script:FinOpsAuditSettings.Enabled) {
        return
    }
    
    # Build audit entry
    $auditEntry = [ordered]@{
        Timestamp = (Get-Date).ToUniversalTime().ToString('o')
        User = $User
        Machine = $env:COMPUTERNAME
        ProcessId = $PID
        Action = $Action
        Resource = $Resource
        Success = $Success
        Details = $Details
        ModuleVersion = '1.6.0'
        PSVersion = $PSVersionTable.PSVersion.ToString()
    }
    
    # Add correlation ID if provided
    if ($CorrelationId) {
        $auditEntry.CorrelationId = $CorrelationId
    }
    elseif ($script:FinOpsLogSettings -and $script:FinOpsLogSettings.CorrelationId) {
        $auditEntry.CorrelationId = $script:FinOpsLogSettings.CorrelationId
    }
    
    # Mask sensitive data in details
    $maskedDetails = @{}
    foreach ($key in $Details.Keys) {
        $value = $Details[$key]
        if ($value -is [string] -and (Test-FinOpsSensitiveData -Text $value)) {
            $maskedDetails[$key] = Hide-FinOpsSensitiveData -Text $value
        }
        else {
            $maskedDetails[$key] = $value
        }
    }
    $auditEntry.Details = $maskedDetails
    
    # Write to audit file (JSON Lines format)
    if ($script:FinOpsAuditSettings.AuditFilePath) {
        try {
            $auditJson = $auditEntry | ConvertTo-Json -Compress -Depth 10
            Add-Content -Path $script:FinOpsAuditSettings.AuditFilePath -Value $auditJson -ErrorAction Stop
        }
        catch {
            Write-Warning "Failed to write audit log: $_"
        }
    }
    else {
        # Default to Output directory if not configured
        $defaultAuditPath = Join-Path (Join-Path $PSScriptRoot '..' | Join-Path -ChildPath 'Output') 'audit.jsonl'
        $auditDir = Split-Path -Parent $defaultAuditPath
        
        if (-not (Test-Path $auditDir)) {
            New-Item -Path $auditDir -ItemType Directory -Force | Out-Null
        }
        
        try {
            $auditJson = $auditEntry | ConvertTo-Json -Compress -Depth 10
            Add-Content -Path $defaultAuditPath -Value $auditJson -ErrorAction Stop
        }
        catch {
            Write-Warning "Failed to write audit log to default location: $_"
        }
    }
    
    # Send to Log Analytics if configured
    if ($script:FinOpsAuditSettings.SendToLogAnalytics -and 
        $script:FinOpsAuditSettings.WorkspaceId -and 
        $script:FinOpsAuditSettings.SharedKey) {
        
        try {
            Send-FinOpsLogAnalyticsData -WorkspaceId $script:FinOpsAuditSettings.WorkspaceId `
                -SharedKey $script:FinOpsAuditSettings.SharedKey `
                -LogType 'FinOpsAudit' `
                -Body ($auditEntry | ConvertTo-Json -Depth 10)
        }
        catch {
            Write-Verbose "Failed to send audit log to Log Analytics: $_"
        }
    }
    
    # Also log to standard logging
    $auditMessage = "Audit: $Action on $Resource by $User"
    $logLevel = if ($Success) { 'Info' } else { 'Warning' }
    Write-FinOpsLog -Level $logLevel -Message $auditMessage -Context $maskedDetails -Category 'Audit'
}

function Set-FinOpsAuditSettings {
    <#
    .SYNOPSIS
        Configures audit logging settings.
    
    .DESCRIPTION
        Sets up audit logging configuration including file path and Log Analytics integration.
    
    .PARAMETER Enabled
        Enable or disable audit logging. Default is true.
    
    .PARAMETER AuditFilePath
        Path to audit log file. Defaults to Output/audit.jsonl.
    
    .PARAMETER SendToLogAnalytics
        Enable sending audit logs to Azure Log Analytics.
    
    .PARAMETER WorkspaceId
        Log Analytics workspace ID (required if SendToLogAnalytics is true).
    
    .PARAMETER SharedKey
        Log Analytics shared key (required if SendToLogAnalytics is true).
    
    .EXAMPLE
        Set-FinOpsAuditSettings -Enabled -AuditFilePath 'C:\Logs\finops-audit.jsonl'
    
    .EXAMPLE
        # Enable Log Analytics integration
        Set-FinOpsAuditSettings -Enabled -SendToLogAnalytics `
            -WorkspaceId '12345678-1234-...' `
            -SharedKey 'your-shared-key'
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$Enabled = $true,
        
        [Parameter()]
        [string]$AuditFilePath,
        
        [Parameter()]
        [switch]$SendToLogAnalytics,
        
        [Parameter()]
        [string]$WorkspaceId,
        
        [Parameter()]
        [SecureString]$SharedKey
    )
    
    if (-not $script:FinOpsAuditSettings) {
        $script:FinOpsAuditSettings = @{}
    }
    
    $script:FinOpsAuditSettings.Enabled = $Enabled
    $script:FinOpsAuditSettings.SendToLogAnalytics = $SendToLogAnalytics
    
    if ($AuditFilePath) {
        # Create directory if it doesn't exist
        $auditDir = Split-Path -Parent $AuditFilePath
        if (-not (Test-Path $auditDir)) {
            New-Item -Path $auditDir -ItemType Directory -Force | Out-Null
        }
        $script:FinOpsAuditSettings.AuditFilePath = $AuditFilePath
    }
    
    if ($SendToLogAnalytics) {
        if (-not $WorkspaceId -or -not $SharedKey) {
            throw "WorkspaceId and SharedKey are required when SendToLogAnalytics is enabled"
        }
        $script:FinOpsAuditSettings.WorkspaceId = $WorkspaceId
        $script:FinOpsAuditSettings.SharedKey = $SharedKey
    }
    
    Write-Verbose "Audit logging configured: Enabled=$Enabled, File=$AuditFilePath, LogAnalytics=$SendToLogAnalytics"
}

function Send-FinOpsLogAnalyticsData {
    <#
    .SYNOPSIS
        Sends data to Azure Log Analytics workspace.
    
    .DESCRIPTION
        Internal helper function to send JSON data to Log Analytics HTTP Data Collector API.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceId,
        
        [Parameter(Mandatory)]
        [SecureString]$SharedKey,
        
        [Parameter(Mandatory)]
        [string]$LogType,
        
        [Parameter(Mandatory)]
        [string]$Body
    )
    
    # Convert SecureString to plain text
    $sharedKeyPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SharedKey)
    )
    
    # Build authorization signature
    $method = 'POST'
    $contentType = 'application/json'
    $resource = '/api/logs'
    $rfc1123date = [DateTime]::UtcNow.ToString('r')
    $contentLength = $Body.Length
    
    $xHeaders = "x-ms-date:$rfc1123date"
    $stringToHash = "$method`n$contentLength`n$contentType`n$xHeaders`n$resource"
    
    $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($sharedKeyPlain)
    
    $sha256 = New-Object System.Security.Cryptography.HMACSHA256
    $sha256.Key = $keyBytes
    $calculatedHash = $sha256.ComputeHash($bytesToHash)
    $encodedHash = [Convert]::ToBase64String($calculatedHash)
    $authorization = "SharedKey ${WorkspaceId}:$encodedHash"
    
    # Build and send request
    $uri = "https://${WorkspaceId}.ods.opinsights.azure.com${resource}?api-version=2016-04-01"
    $headers = @{
        'Authorization' = $authorization
        'Log-Type' = $LogType
        'x-ms-date' = $rfc1123date
    }
    
    Invoke-RestMethod -Uri $uri -Method Post -ContentType $contentType -Headers $headers -Body $Body
}
