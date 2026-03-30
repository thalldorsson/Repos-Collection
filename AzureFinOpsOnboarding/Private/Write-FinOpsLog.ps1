function Write-FinOpsLog {
    <#
    .SYNOPSIS
        Writes structured log entries with multiple output sinks.
    
    .DESCRIPTION
        Provides structured logging with severity levels, JSON output, and multiple sinks
        (file, event log, console). Supports Log Analytics ingestion format.
        
        Log entries include timestamp, level, category, message, context, and metadata.
    
    .PARAMETER Level
        Log severity level: Debug, Info, Warning, Error, Critical.
    
    .PARAMETER Message
        Human-readable log message.
    
    .PARAMETER Context
        Additional structured data (hashtable) to include with log entry.
    
    .PARAMETER Category
        Log category for filtering (e.g., 'APICall', 'Authentication', 'Performance').
    
    .PARAMETER Exception
        Optional exception object to include in log entry.
    
    .EXAMPLE
        Write-FinOpsLog -Level 'Info' -Message 'Starting onboarding' -Context @{
            Customer = 'Contoso'
            TenantId = '12345678-1234-1234-1234-123456789012'
        }
    
    .EXAMPLE
        Write-FinOpsLog -Level 'Error' -Message 'API call failed' -Context @{
            Endpoint = 'https://management.azure.com/...'
            StatusCode = 429
        } -Category 'APICall' -Exception $_.Exception
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Debug', 'Info', 'Warning', 'Error', 'Critical')]
        [string]$Level = 'Info',
        
        [Parameter(Mandatory)]
        [string]$Message,
        
        [Parameter()]
        [hashtable]$Context = @{},
        
        [Parameter()]
        [string]$Category = 'General',
        
        [Parameter()]
        [System.Exception]$Exception
    )
    
    # Initialize module logging settings if not set
    if (-not $script:FinOpsLogSettings) {
        $script:FinOpsLogSettings = @{
            LogToFile = $false
            LogFilePath = $null
            LogToEventLog = $false
            LogToConsole = $true
            MinimumLevel = 'Info'
            CorrelationId = $null
        }
    }
    
    # Check minimum log level
    $levelOrder = @{
        'Debug' = 0
        'Info' = 1
        'Warning' = 2
        'Error' = 3
        'Critical' = 4
    }
    
    if ($levelOrder[$Level] -lt $levelOrder[$script:FinOpsLogSettings.MinimumLevel]) {
        return  # Don't log below minimum level
    }
    
    # Build structured log entry
    $logEntry = @{
        Timestamp = (Get-Date).ToUniversalTime().ToString('o')
        Level = $Level
        Category = $Category
        Message = $Message
        Context = $Context
        ModuleVersion = '1.6.0'
        PSVersion = $PSVersionTable.PSVersion.ToString()
        Machine = $env:COMPUTERNAME
        User = $env:USERNAME
    }
    
    # Mask sensitive data in message and context
    $maskedMessage = Hide-FinOpsSensitiveData -Text $Message
    $maskedContext = @{}
    foreach ($key in $Context.Keys) {
        $value = $Context[$key]
        if ($value -is [string] -and (Test-FinOpsSensitiveData -Text $value)) {
            $maskedContext[$key] = Hide-FinOpsSensitiveData -Text $value
        }
        else {
            $maskedContext[$key] = $value
        }
    }
    
    # Update log entry with masked data
    $logEntry.Message = $maskedMessage
    $logEntry.Context = $maskedContext
    
    # Add correlation ID if available
    if ($script:FinOpsLogSettings.CorrelationId) {
        $logEntry.CorrelationId = $script:FinOpsLogSettings.CorrelationId
    }
    
    # Add exception details if provided
    if ($Exception) {
        $logEntry.Exception = @{
            Type = $Exception.GetType().FullName
            Message = $Exception.Message
            StackTrace = $Exception.StackTrace
            InnerException = if ($Exception.InnerException) { $Exception.InnerException.Message } else { $null }
        }
    }
    
    # Output to file sink (JSON Lines format)
    if ($script:FinOpsLogSettings.LogToFile -and $script:FinOpsLogSettings.LogFilePath) {
        try {
            $logJson = $logEntry | ConvertTo-Json -Compress -Depth 10
            Add-Content -Path $script:FinOpsLogSettings.LogFilePath -Value $logJson -ErrorAction Stop
        }
        catch {
            Write-Warning "Failed to write to log file: $_"
        }
    }
    
    # Output to Event Log sink (Windows only)
    if ($script:FinOpsLogSettings.LogToEventLog -and $IsWindows) {
        try {
            # Map log level to event log entry type
            $entryType = switch ($Level) {
                'Debug' { 'Information' }
                'Info' { 'Information' }
                'Warning' { 'Warning' }
                'Error' { 'Error' }
                'Critical' { 'Error' }
            }
            
            # Create event log source if it doesn't exist
            $sourceName = 'AzureFinOpsOnboarding'
            if (-not [System.Diagnostics.EventLog]::SourceExists($sourceName)) {
                Write-Verbose "Event log source '$sourceName' does not exist. Skipping event log write."
            }
            else {
                $eventMessage = "$Category - $Message`n`n$(($Context | ConvertTo-Json -Depth 5))"
                Write-EventLog -LogName 'Application' -Source $sourceName -EntryType $entryType -EventId 1000 -Message $eventMessage -ErrorAction Stop
            }
        }
        catch {
            Write-Verbose "Failed to write to event log: $_"
        }
    }
    
    # Output to console sink with color coding
    if ($script:FinOpsLogSettings.LogToConsole) {
        $timestamp = (Get-Date).ToString('HH:mm:ss')
        
        $color = switch ($Level) {
            'Debug' { 'Gray' }
            'Info' { 'White' }
            'Warning' { 'Yellow' }
            'Error' { 'Red' }
            'Critical' { 'DarkRed' }
        }
        
        $icon = switch ($Level) {
            'Debug' { '🔍' }
            'Info' { 'ℹ️' }
            'Warning' { '⚠️' }
            'Error' { '❌' }
            'Critical' { '🔥' }
        }
        
        # Format context for console (abbreviated, already masked)
        $contextString = ''
        if ($maskedContext.Count -gt 0) {
            $contextPairs = $maskedContext.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
            $contextString = " [$($contextPairs -join ', ')]"
        }
        
        Write-Host "[$timestamp][$Level]$icon $maskedMessage$contextString" -ForegroundColor $color
    }
}

function Set-FinOpsLogSettings {
    <#
    .SYNOPSIS
        Configures logging settings for the FinOps module.
    
    .DESCRIPTION
        Sets up logging configuration including output sinks, minimum level, and file paths.
    
    .PARAMETER LogToFile
        Enable file-based logging (JSON Lines format).
    
    .PARAMETER LogFilePath
        Path to log file. Directory will be created if it doesn't exist.
    
    .PARAMETER LogToEventLog
        Enable Windows Event Log logging.
    
    .PARAMETER LogToConsole
        Enable console output with color coding. Default is true.
    
    .PARAMETER MinimumLevel
        Minimum log level to output. Default is 'Info'.
    
    .PARAMETER CorrelationId
        Optional correlation ID to include in all log entries.
    
    .EXAMPLE
        Set-FinOpsLogSettings -LogToFile -LogFilePath 'C:\Logs\finops.log' -MinimumLevel 'Debug'
    
    .EXAMPLE
        # Enable all sinks
        Set-FinOpsLogSettings -LogToFile -LogFilePath 'C:\Logs\finops.log' `
            -LogToEventLog -LogToConsole -MinimumLevel 'Info'
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$LogToFile,
        
        [Parameter()]
        [string]$LogFilePath,
        
        [Parameter()]
        [switch]$LogToEventLog,
        
        [Parameter()]
        [switch]$LogToConsole = $true,
        
        [Parameter()]
        [ValidateSet('Debug', 'Info', 'Warning', 'Error', 'Critical')]
        [string]$MinimumLevel = 'Info',
        
        [Parameter()]
        [string]$CorrelationId
    )
    
    # Initialize settings if not exists
    if (-not $script:FinOpsLogSettings) {
        $script:FinOpsLogSettings = @{}
    }
    
    $script:FinOpsLogSettings.LogToFile = $LogToFile
    $script:FinOpsLogSettings.LogToEventLog = $LogToEventLog
    $script:FinOpsLogSettings.LogToConsole = $LogToConsole
    $script:FinOpsLogSettings.MinimumLevel = $MinimumLevel
    $script:FinOpsLogSettings.CorrelationId = $CorrelationId
    
    # Set up log file path
    if ($LogToFile -and $LogFilePath) {
        # Create directory if it doesn't exist
        $logDir = Split-Path -Parent $LogFilePath
        if (-not (Test-Path $logDir)) {
            New-Item -Path $logDir -ItemType Directory -Force | Out-Null
        }
        
        $script:FinOpsLogSettings.LogFilePath = $LogFilePath
        Write-Verbose "Log file configured: $LogFilePath"
    }
    
    # Set up Event Log source (requires admin)
    if ($LogToEventLog -and $IsWindows) {
        $sourceName = 'AzureFinOpsOnboarding'
        try {
            if (-not [System.Diagnostics.EventLog]::SourceExists($sourceName)) {
                Write-Warning "Event log source '$sourceName' does not exist."
                Write-Warning "To create it, run as Administrator: New-EventLog -LogName Application -Source $sourceName"
            }
        }
        catch {
            Write-Warning "Cannot verify event log source: $_"
        }
    }
    
    Write-Verbose "Logging configured: File=$LogToFile, EventLog=$LogToEventLog, Console=$LogToConsole, MinLevel=$MinimumLevel"
}

function Get-FinOpsLogSettings {
    <#
    .SYNOPSIS
        Gets current logging configuration.
    
    .DESCRIPTION
        Returns the current logging settings as a hashtable.
    
    .EXAMPLE
        $settings = Get-FinOpsLogSettings
        Write-Host "Log file: $($settings.LogFilePath)"
    #>
    [CmdletBinding()]
    param()
    
    if (-not $script:FinOpsLogSettings) {
        return @{
            LogToFile = $false
            LogFilePath = $null
            LogToEventLog = $false
            LogToConsole = $true
            MinimumLevel = 'Info'
            CorrelationId = $null
        }
    }
    
    return $script:FinOpsLogSettings.Clone()
}
