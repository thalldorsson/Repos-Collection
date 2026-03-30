<#
.SYNOPSIS
    Syncs device's migration wave group membership from Entra ID to local registry.

.DESCRIPTION
    This script queries Microsoft Graph API to determine which migration wave group
    (1-6 or Pilot) a device belongs to, then stores the result in the registry for
    local consumption by WinRE-Health-Detection script.
    
    Deployment Options:
    1. Intune PowerShell script (runs as SYSTEM, requires app registration)
    2. Azure Automation runbook with Managed Identity
    3. Scheduled Task with service account

.PARAMETER TenantId
    Azure AD Tenant ID

.PARAMETER ClientId
    Application (client) ID of registered app with DeviceManagementManagedDevices.Read.All

.PARAMETER ClientSecret
    Client secret for app authentication (use secure method in production)

.PARAMETER UseDeviceCode
    Use device code flow for interactive authentication (testing only)

.PARAMETER UseManagedIdentity
    Use Azure Managed Identity for authentication (Azure Automation/VM)

.EXAMPLE
    # Using app registration (for Intune deployment)
    .\Sync-MigrationWaveToRegistry.ps1 -TenantId "your-tenant-id" -ClientId "your-app-id" -ClientSecret "your-secret"

.EXAMPLE
    # Using Managed Identity (for Azure Automation)
    .\Sync-MigrationWaveToRegistry.ps1 -UseManagedIdentity

.NOTES
    Version: 1.0.0
    Author: WinRE Health Monitoring Team
    Created: 2025-11-28
    
    Required Graph API Permissions:
    - DeviceManagementManagedDevices.Read.All
    - GroupMember.Read.All
    - Device.Read.All
    
    Registry Key Created:
    HKLM:\SOFTWARE\Company\Migration
    - Wave (String): "Wave 1" through "Wave 6", "Pilot", or "Not Assigned"
    - LastSync (DateTime): Last successful sync timestamp
    - DeviceId (String): Azure AD Device Object ID
#>

[CmdletBinding(DefaultParameterSetName='AppAuth')]
param(
    [Parameter(Mandatory, ParameterSetName='AppAuth')]
    [string]$TenantId,
    
    [Parameter(Mandatory, ParameterSetName='AppAuth')]
    [string]$ClientId,
    
    [Parameter(Mandatory, ParameterSetName='AppAuth')]
    [string]$ClientSecret,
    
    [Parameter(ParameterSetName='DeviceCode')]
    [switch]$UseDeviceCode,
    
    [Parameter(ParameterSetName='ManagedIdentity')]
    [switch]$UseManagedIdentity,
    
    [string]$RegistryPath = 'HKLM:\SOFTWARE\Company\Migration',
    
    [string[]]$WaveGroupNames = @(
        'Migration-Wave-1-Pilot',
        'Migration-Wave-2',
        'Migration-Wave-3',
        'Migration-Wave-4',
        'Migration-Wave-5',
        'Migration-Wave-6'
    )
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

#region Helper Functions

function Write-Log {
    param([string]$Message, [string]$Level = 'Info')
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logMessage = "[$timestamp] [$Level] $Message"
    Write-Host $logMessage
    
    # Also log to Application event log
    $eventLogSource = 'WinREMigrationSync'
    if (-not [System.Diagnostics.EventLog]::SourceExists($eventLogSource)) {
        try {
            New-EventLog -LogName Application -Source $eventLogSource -ErrorAction SilentlyContinue
        } catch {}
    }
    
    $eventId = switch ($Level) {
        'Error' { 1001 }
        'Warning' { 1002 }
        default { 1000 }
    }
    
    try {
        Write-EventLog -LogName Application -Source $eventLogSource -EntryType $Level -EventId $eventId -Message $Message -ErrorAction SilentlyContinue
    } catch {}
}

function Get-AccessToken {
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret,
        [switch]$UseManagedIdentity
    )
    
    $resource = 'https://graph.microsoft.com'
    
    if ($UseManagedIdentity) {
        Write-Log "Authenticating using Managed Identity..."
        try {
            $response = Invoke-RestMethod -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fgraph.microsoft.com%2F' -Method GET -Headers @{Metadata="true"} -UseBasicParsing
            return $response.access_token
        } catch {
            Write-Log "Managed Identity authentication failed: $($_.Exception.Message)" -Level Error
            throw
        }
    }
    
    Write-Log "Authenticating using app credentials (Tenant: $TenantId, Client: $ClientId)..."
    $body = @{
        grant_type    = 'client_credentials'
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = 'https://graph.microsoft.com/.default'
    }
    
    $tokenEndpoint = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    
    try {
        $response = Invoke-RestMethod -Uri $tokenEndpoint -Method POST -Body $body -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing
        Write-Log "Authentication successful"
        return $response.access_token
    } catch {
        Write-Log "Authentication failed: $($_.Exception.Message)" -Level Error
        throw
    }
}

function Get-DeviceAzureADId {
    Write-Log "Retrieving Azure AD Device ID from local registry..."
    
    # Try multiple registry locations
    $regPaths = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Enrollments'; Property = 'AadDeviceId' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Provisioning\Diagnostics\Autopilot'; Property = 'CloudAssignedTenantDomain' }
    )
    
    foreach ($regInfo in $regPaths) {
        if (Test-Path $regInfo.Path) {
            $enrollments = Get-ChildItem -Path $regInfo.Path -ErrorAction SilentlyContinue
            foreach ($enrollment in $enrollments) {
                $aadDeviceId = (Get-ItemProperty -Path $enrollment.PSPath -Name 'AadDeviceId' -ErrorAction SilentlyContinue).AadDeviceId
                if ($aadDeviceId) {
                    Write-Log "Found Azure AD Device ID: $aadDeviceId"
                    return $aadDeviceId
                }
            }
        }
    }
    
    # Fallback: Parse from dsregcmd
    Write-Log "Attempting to get Device ID via dsregcmd..."
    $dsreg = dsregcmd /status 2>$null
    $deviceId = ($dsreg | Select-String -Pattern 'DeviceId\s*:\s*(.*)' | ForEach-Object { $_.Matches.Groups[1].Value.Trim() })
    
    if ($deviceId) {
        Write-Log "Device ID from dsregcmd: $deviceId"
        return $deviceId
    }
    
    Write-Log "Failed to retrieve Azure AD Device ID" -Level Error
    throw "Device is not Azure AD joined or device ID is not available"
}

function Get-DeviceGroupMembership {
    param(
        [string]$DeviceId,
        [string]$AccessToken
    )
    
    Write-Log "Querying device group memberships for Device ID: $DeviceId"
    
    $headers = @{
        'Authorization' = "Bearer $AccessToken"
        'Content-Type'  = 'application/json'
    }
    
    # Get device's group memberships
    $uri = "https://graph.microsoft.com/v1.0/devices/$DeviceId/memberOf"
    
    try {
        $response = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers -UseBasicParsing
        $groups = $response.value
        
        Write-Log "Device is member of $($groups.Count) groups"
        
        # Extract group display names
        $groupNames = $groups | Select-Object -ExpandProperty displayName
        return $groupNames
        
    } catch {
        Write-Log "Failed to query group memberships: $($_.Exception.Message)" -Level Error
        throw
    }
}

function Get-MigrationWaveFromGroups {
    param([string[]]$GroupNames, [string[]]$WaveGroupNames)
    
    Write-Log "Analyzing group memberships for migration wave assignment..."
    Write-Log "Device groups: $($GroupNames -join ', ')"
    Write-Log "Wave groups to check: $($WaveGroupNames -join ', ')"
    
    foreach ($waveGroup in $WaveGroupNames) {
        if ($GroupNames -contains $waveGroup) {
            # Parse wave number from group name
            if ($waveGroup -match '(?i)pilot') {
                Write-Log "Device assigned to: Pilot"
                return "Pilot"
            }
            
            if ($waveGroup -match '(?i)wave[_\s-]*(\d)') {
                $waveNum = $matches[1]
                Write-Log "Device assigned to: Wave $waveNum"
                return "Wave $waveNum"
            }
        }
    }
    
    Write-Log "Device not assigned to any migration wave group"
    return "Not Assigned"
}

function Set-RegistryValue {
    param(
        [string]$Path,
        [hashtable]$Values
    )
    
    Write-Log "Writing migration wave to registry: $Path"
    
    # Create registry key if it doesn't exist
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
        Write-Log "Created registry key: $Path"
    }
    
    # Set values
    foreach ($key in $Values.Keys) {
        $value = $Values[$key]
        Set-ItemProperty -Path $Path -Name $key -Value $value -Force
        Write-Log "Set registry value: $key = $value"
    }
}

#endregion

#region Main Script

try {
    Write-Log "=== Migration Wave Sync Started ==="
    Write-Log "Computer: $env:COMPUTERNAME"
    Write-Log "User: $env:USERNAME"
    
    # Step 1: Get local device's Azure AD ID
    $deviceId = Get-DeviceAzureADId
    
    # Step 2: Authenticate to Graph API
    $accessToken = if ($UseManagedIdentity) {
        Get-AccessToken -UseManagedIdentity
    } else {
        Get-AccessToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
    }
    
    # Step 3: Query device's group memberships
    $deviceGroups = Get-DeviceGroupMembership -DeviceId $deviceId -AccessToken $accessToken
    
    # Step 4: Determine migration wave assignment
    $migrationWave = Get-MigrationWaveFromGroups -GroupNames $deviceGroups -WaveGroupNames $WaveGroupNames
    
    # Step 5: Write to registry
    $registryValues = @{
        Wave         = $migrationWave
        LastSync     = (Get-Date -Format 'o')
        DeviceId     = $deviceId
        GroupCount   = $deviceGroups.Count
    }
    
    Set-RegistryValue -Path $RegistryPath -Values $registryValues
    
    Write-Log "=== Migration Wave Sync Completed Successfully ==="
    Write-Log "Result: $migrationWave"
    
    exit 0
    
} catch {
    Write-Log "=== Migration Wave Sync Failed ===" -Level Error
    Write-Log "Error: $($_.Exception.Message)" -Level Error
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level Error
    
    # Write error to registry for troubleshooting
    try {
        if (-not (Test-Path $RegistryPath)) {
            New-Item -Path $RegistryPath -Force | Out-Null
        }
        Set-ItemProperty -Path $RegistryPath -Name 'Wave' -Value 'Unknown' -Force
        Set-ItemProperty -Path $RegistryPath -Name 'LastError' -Value $_.Exception.Message -Force
        Set-ItemProperty -Path $RegistryPath -Name 'LastErrorTime' -Value (Get-Date -Format 'o') -Force
    } catch {}
    
    exit 1
}

#endregion
