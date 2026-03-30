#Requires -Version 5.1

<#
.SYNOPSIS
    Structured logging module for PhishIR operations

.DESCRIPTION
    Provides structured logging with multiple output targets:
    - Console (color-coded)
    - File (JSON structured logs)
    - Syslog (RFC 5424 format)
    - Audit trail for compliance
#>

# Module-level variables
$script:LogFilePath = $null
$script:SyslogServer = $null
$script:SyslogPort = 514
$script:CorrelationId = [guid]::NewGuid().ToString()
$script:LogLevel = 'Info'
$script:AuditLogPath = $null

function Initialize-PhishIRLogging {
    <#
    .SYNOPSIS
        Initialize the logging system

    .PARAMETER LogFilePath
        Path to log file (optional)

    .PARAMETER SyslogServer
        Syslog server hostname or IP (optional)

    .PARAMETER SyslogPort
        Syslog server port (default: 514)

    .PARAMETER LogLevel
        Minimum log level: Debug, Info, Warning, Error (default: Info)

    .PARAMETER AuditLogPath
        Path to audit log file for compliance (optional)

    .PARAMETER CorrelationId
        Custom correlation ID for related operations (default: auto-generated GUID)
    #>
    [CmdletBinding()]
    param(
        [string]$LogFilePath,
        [string]$SyslogServer,
        [int]$SyslogPort = 514,
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string]$LogLevel = 'Info',
        [string]$AuditLogPath,
        [string]$CorrelationId
    )

    if ($LogFilePath) {
        $script:LogFilePath = $LogFilePath
        $logDir = Split-Path -Parent $LogFilePath
        if ($logDir -and -not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
    }

    if ($SyslogServer) {
        $script:SyslogServer = $SyslogServer
        $script:SyslogPort = $SyslogPort
    }

    if ($AuditLogPath) {
        $script:AuditLogPath = $AuditLogPath
        $auditDir = Split-Path -Parent $AuditLogPath
        if ($auditDir -and -not (Test-Path $auditDir)) {
            New-Item -ItemType Directory -Path $auditDir -Force | Out-Null
        }
    }

    $script:LogLevel = $LogLevel

    if ($CorrelationId) {
        $script:CorrelationId = $CorrelationId
    }

    Write-PhishIRLog -Level Info -Message "Logging initialized" -Properties @{
        LogFile = $script:LogFilePath
        SyslogServer = $script:SyslogServer
        LogLevel = $script:LogLevel
        CorrelationId = $script:CorrelationId
    }
}

function Write-PhishIRLog {
    <#
    .SYNOPSIS
        Write a structured log entry

    .PARAMETER Level
        Log level: Debug, Info, Warning, Error

    .PARAMETER Message
        Log message

    .PARAMETER Properties
        Additional properties to include in structured log

    .PARAMETER Exception
        Exception object to log
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message,

        [hashtable]$Properties = @{},

        [System.Exception]$Exception
    )

    # Check if log level meets minimum threshold
    $logLevels = @{
        'Debug' = 0
        'Info' = 1
        'Warning' = 2
        'Error' = 3
    }

    if ($logLevels[$Level] -lt $logLevels[$script:LogLevel]) {
        return  # Skip logs below threshold
    }

    # Build log entry
    $logEntry = [ordered]@{
        Timestamp = (Get-Date).ToUniversalTime().ToString('o')
        Level = $Level
        Message = $Message
        CorrelationId = $script:CorrelationId
        User = $env:USERNAME
        Machine = $env:COMPUTERNAME
    }

    # Add custom properties
    foreach ($key in $Properties.Keys) {
        $logEntry[$key] = $Properties[$key]
    }

    # Add exception details if provided
    if ($Exception) {
        $logEntry['ExceptionType'] = $Exception.GetType().FullName
        $logEntry['ExceptionMessage'] = $Exception.Message
        $logEntry['StackTrace'] = $Exception.StackTrace
    }

    # Console output (color-coded)
    Write-LogToConsole -Level $Level -Message $Message -LogEntry $logEntry

    # File output (JSON structured)
    if ($script:LogFilePath) {
        Write-LogToFile -LogEntry $logEntry
    }

    # Syslog output
    if ($script:SyslogServer) {
        Write-LogToSyslog -Level $Level -Message $Message -LogEntry $logEntry
    }
}

function Write-LogToConsole {
    [CmdletBinding()]
    param(
        [string]$Level,
        [string]$Message,
        [hashtable]$LogEntry
    )

    $color = switch ($Level) {
        'Debug'   { 'Gray' }
        'Info'    { 'Cyan' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
    }

    $timestamp = ([datetime]$LogEntry.Timestamp).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
    $formattedMessage = "[$timestamp] [$Level] $Message"

    Write-Host $formattedMessage -ForegroundColor $color
}

function Write-LogToFile {
    [CmdletBinding()]
    param(
        [hashtable]$LogEntry
    )

    try {
        $json = $LogEntry | ConvertTo-Json -Compress -Depth 5
        $json | Add-Content -Path $script:LogFilePath -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to write to log file: $_"
    }
}

function Write-LogToSyslog {
    [CmdletBinding()]
    param(
        [string]$Level,
        [string]$Message,
        [hashtable]$LogEntry
    )

    try {
        # RFC 5424 severity levels
        $severity = switch ($Level) {
            'Debug'   { 7 }  # Debug
            'Info'    { 6 }  # Informational
            'Warning' { 4 }  # Warning
            'Error'   { 3 }  # Error
        }

        # Facility 16 = local use 0
        $priority = (16 * 8) + $severity

        $hostname = $env:COMPUTERNAME
        $appName = 'PhishIR'
        $timestamp = ([datetime]$LogEntry.Timestamp).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

        # RFC 5424 format: <priority>version timestamp hostname app-name procid msgid structured-data msg
        $syslogMessage = "<$priority>1 $timestamp $hostname $appName - - - $Message"

        # Send via UDP
        $udpClient = New-Object System.Net.Sockets.UdpClient
        $encoding = [System.Text.Encoding]::UTF8
        $bytes = $encoding.GetBytes($syslogMessage)
        $null = $udpClient.Send($bytes, $bytes.Length, $script:SyslogServer, $script:SyslogPort)
        $udpClient.Close()
    }
    catch {
        Write-Warning "Failed to send syslog message: $_"
    }
}

function Write-PhishIRAuditLog {
    <#
    .SYNOPSIS
        Write an audit trail entry for compliance

    .DESCRIPTION
        Writes critical operations to a separate audit log for compliance and forensics

    .PARAMETER Action
        Action performed (e.g., 'PurgeStarted', 'PurgeCompleted', 'SearchCreated')

    .PARAMETER Details
        Hashtable with operation details
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Action,

        [Parameter(Mandatory)]
        [hashtable]$Details
    )

    $auditEntry = [ordered]@{
        Timestamp = (Get-Date).ToUniversalTime().ToString('o')
        Action = $Action
        User = $env:USERNAME
        UserDomain = $env:USERDOMAIN
        Machine = $env:COMPUTERNAME
        CorrelationId = $script:CorrelationId
    }

    # Add operation details
    foreach ($key in $Details.Keys) {
        $auditEntry[$key] = $Details[$key]
    }

    # Write to main log
    Write-PhishIRLog -Level Info -Message "AUDIT: $Action" -Properties $Details

    # Write to audit log if configured
    if ($script:AuditLogPath) {
        try {
            $json = $auditEntry | ConvertTo-Json -Compress -Depth 8
            $json | Add-Content -Path $script:AuditLogPath -Encoding UTF8 -ErrorAction Stop
        }
        catch {
            Write-Warning "Failed to write to audit log: $_"
        }
    }
}

function Get-PhishIRCorrelationId {
    <#
    .SYNOPSIS
        Get the current correlation ID
    #>
    return $script:CorrelationId
}

function Set-PhishIRCorrelationId {
    <#
    .SYNOPSIS
        Set a new correlation ID for related operations
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CorrelationId
    )

    $script:CorrelationId = $CorrelationId
    Write-PhishIRLog -Level Debug -Message "Correlation ID updated" -Properties @{
        NewCorrelationId = $CorrelationId
    }
}

# Convenience functions with original interface
function Write-Info {
    [CmdletBinding()]
    param([string]$Message)
    Write-PhishIRLog -Level Info -Message $Message
}

function Write-Success {
    [CmdletBinding()]
    param([string]$Message)
    Write-PhishIRLog -Level Info -Message $Message
    Write-Host $Message -ForegroundColor Green
}

function Write-Warn {
    [CmdletBinding()]
    param([string]$Message)
    Write-PhishIRLog -Level Warning -Message $Message
}

function Write-Error {
    [CmdletBinding()]
    param([string]$Message)
    Write-PhishIRLog -Level Error -Message $Message
}

# Export functions
Export-ModuleMember -Function @(
    'Initialize-PhishIRLogging',
    'Write-PhishIRLog',
    'Write-PhishIRAuditLog',
    'Get-PhishIRCorrelationId',
    'Set-PhishIRCorrelationId',
    'Write-Info',
    'Write-Success',
    'Write-Warn'
)
