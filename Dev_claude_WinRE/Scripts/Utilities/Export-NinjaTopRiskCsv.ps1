#Requires -Version 5.1

<#
.SYNOPSIS
  Export top-risk WinRE devices from NinjaOne to CSV using the NinjaOne API.

.DESCRIPTION
  Queries NinjaOne for devices with WinRE custom fields, filters for high-risk devices
  (low free space, KB5034441 vulnerable, critical severity), and exports to CSV.
  
  Requires NinjaOne API credentials (Client ID and Secret) with read access to
  device custom fields.

.PARAMETER ClientId
  NinjaOne API Client ID (from Admin → Apps → API).

.PARAMETER ClientSecret
  NinjaOne API Client Secret.

.PARAMETER Region
  NinjaOne region (us, eu, oc, ca). Default: us.

.PARAMETER OrganizationId
  Optional: filter to specific organization ID.

.PARAMETER OutputPath
  Path to save CSV. Default: ./WinRE-TopRisk-<timestamp>.csv

.PARAMETER TopCount
  Number of top-risk devices to export. Default: 50.

.PARAMETER MinFreeSpaceMB
  Threshold for low free space (MB). Default: 100.

.EXAMPLE
  .\Export-NinjaTopRiskCsv.ps1 -ClientId "abc123" -ClientSecret "xyz789"
  
.EXAMPLE
  .\Export-NinjaTopRiskCsv.ps1 -ClientId $id -ClientSecret $secret -OrganizationId 86 -TopCount 25

.NOTES
  Author: Thorsteinn Halldorsson
  Version: 1.0.0
  Date: 2025-12-12
  
  Prerequisites:
  - NinjaOne API credentials with device read access
  - Device Custom Fields populated (winre* fields)
  
  API Documentation: https://app.ninjarmm.com/apidocs
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ClientId,
    
    [Parameter(Mandatory=$true)]
    [string]$ClientSecret,
    
    [ValidateSet('us','eu','oc','ca')]
    [string]$Region = 'us',
    
    [int]$OrganizationId,
    
    [string]$OutputPath,
    
    [int]$TopCount = 50,
    
    [int]$MinFreeSpaceMB = 100
)

#region Configuration
$ErrorActionPreference = 'Stop'

# NinjaOne API endpoints by region
$RegionEndpoints = @{
    'us' = 'https://app.ninjarmm.com'
    'eu' = 'https://eu.ninjarmm.com'
    'oc' = 'https://oc.ninjarmm.com'
    'ca' = 'https://ca.ninjarmm.com'
}

$BaseUrl = $RegionEndpoints[$Region]
$TokenUrl = "$BaseUrl/ws/oauth/token"
$DevicesUrl = "$BaseUrl/v2/devices"

# Default output path
if (-not $OutputPath) {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputPath = ".\WinRE-TopRisk-$timestamp.csv"
}

Write-Host "=== NinjaOne WinRE Top Risk Export ===" -ForegroundColor Cyan
Write-Host "Region: $Region" -ForegroundColor Gray
Write-Host "Output: $OutputPath" -ForegroundColor Gray
Write-Host ""
#endregion

#region Functions
function Get-NinjaAccessToken {
    param(
        [string]$ClientId,
        [string]$ClientSecret,
        [string]$TokenUrl
    )
    
    Write-Host "Authenticating with NinjaOne API..." -ForegroundColor Yellow
    
    $body = @{
        grant_type = 'client_credentials'
        client_id = $ClientId
        client_secret = <REDACTED>
        scope = 'monitoring'
    }
    
    try {
        $response = Invoke-RestMethod -Uri $TokenUrl -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded'
        Write-Host "  ✅ Authentication successful" -ForegroundColor Green
        return $response.access_token
    } catch {
        Write-Host "  ❌ Authentication failed: $($_.Exception.Message)" -ForegroundColor Red
        throw "Failed to authenticate with NinjaOne API. Check ClientId/Secret and region."
    }
}

function Get-NinjaDevices {
    param(
        [string]$AccessToken,
        [string]$DevicesUrl,
        [int]$OrganizationId
    )
    
    Write-Host "Fetching devices from NinjaOne..." -ForegroundColor Yellow
    
    $headers = @{
        'Authorization' = "Bearer $AccessToken"
        'Accept' = 'application/json'
    }
    
    $queryParams = @()
    if ($OrganizationId) {
        $queryParams += "organizationId=$OrganizationId"
    }
    
    $url = $DevicesUrl
    if ($queryParams.Count -gt 0) {
        $url += "?" + ($queryParams -join '&')
    }
    
    try {
        $devices = Invoke-RestMethod -Uri $url -Method Get -Headers $headers
        Write-Host "  ✅ Retrieved $($devices.Count) devices" -ForegroundColor Green
        return $devices
    } catch {
        Write-Host "  ❌ Failed to fetch devices: $($_.Exception.Message)" -ForegroundColor Red
        throw "Failed to retrieve devices from NinjaOne API."
    }
}

function Get-DeviceCustomFields {
    param(
        [string]$AccessToken,
        [string]$BaseUrl,
        [int]$DeviceId
    )
    
    $url = "$BaseUrl/v2/device/$DeviceId/custom-fields"
    $headers = @{
        'Authorization' = "Bearer $AccessToken"
        'Accept' = 'application/json'
    }
    
    try {
        $fields = Invoke-RestMethod -Uri $url -Method Get -Headers $headers
        return $fields
    } catch {
        Write-Warning "Failed to fetch custom fields for device $DeviceId : $($_.Exception.Message)"
        return $null
    }
}

function ConvertTo-RiskScore {
    param(
        [object]$Device,
        [hashtable]$CustomFields
    )
    
    # Calculate risk score (0-100, higher = more risk)
    $riskScore = 0
    
    # Severity (boolean: true=critical/warning)
    if ($CustomFields.ContainsKey('winreSeverity') -and $CustomFields['winreSeverity'] -eq $true) {
        $riskScore += 40
    }
    
    # KB5034441 vulnerable
    if ($CustomFields.ContainsKey('winreKB5034441Vulnerable') -and $CustomFields['winreKB5034441Vulnerable'] -eq $true) {
        $riskScore += 30
    }
    
    # Low free space
    if ($CustomFields.ContainsKey('winrePartitionFreeMB')) {
        $freeMB = [decimal]$CustomFields['winrePartitionFreeMB']
        if ($freeMB -lt 50) { $riskScore += 20 }
        elseif ($freeMB -lt 100) { $riskScore += 10 }
        elseif ($freeMB -lt 150) { $riskScore += 5 }
    }
    
    # WinRE disabled
    if ($CustomFields.ContainsKey('winreEnabled') -and $CustomFields['winreEnabled'] -eq $false) {
        $riskScore += 10
    }
    
    return $riskScore
}
#endregion

#region Main Execution
try {
    # Step 1: Authenticate
    $accessToken = <REDACTED> -ClientId $ClientId -ClientSecret $ClientSecret -TokenUrl $TokenUrl
    
    # Step 2: Fetch devices
    $devices = Get-NinjaDevices -AccessToken $accessToken -DevicesUrl $DevicesUrl -OrganizationId $OrganizationId
    
    if ($devices.Count -eq 0) {
        Write-Host "No devices found. Exiting." -ForegroundColor Yellow
        exit 0
    }
    
    # Step 3: Fetch custom fields for each device and calculate risk
    Write-Host "Analyzing device risk (this may take a while)..." -ForegroundColor Yellow
    
    $riskDevices = @()
    $processed = 0
    
    foreach ($device in $devices) {
        $processed++
        if ($processed % 10 -eq 0) {
            Write-Host "  Progress: $processed / $($devices.Count)" -ForegroundColor Gray
        }
        
        # Fetch custom fields
        $customFields = Get-DeviceCustomFields -AccessToken $accessToken -BaseUrl $BaseUrl -DeviceId $device.id
        
        if (-not $customFields) { continue }
        
        # Convert to hashtable for easier access
        $fieldsHash = @{}
        foreach ($field in $customFields) {
            $fieldsHash[$field.name] = $field.value
        }
        
        # Filter: only include devices with risk indicators
        $isRisk = $false
        
        # Check severity
        if ($fieldsHash.ContainsKey('winreSeverity') -and $fieldsHash['winreSeverity'] -eq $true) {
            $isRisk = $true
        }
        
        # Check KB vulnerability
        if ($fieldsHash.ContainsKey('winreKB5034441Vulnerable') -and $fieldsHash['winreKB5034441Vulnerable'] -eq $true) {
            $isRisk = $true
        }
        
        # Check free space
        if ($fieldsHash.ContainsKey('winrePartitionFreeMB')) {
            $freeMB = [decimal]$fieldsHash['winrePartitionFreeMB']
            if ($freeMB -lt $MinFreeSpaceMB) {
                $isRisk = $true
            }
        }
        
        if (-not $isRisk) { continue }
        
        # Calculate risk score
        $riskScore = ConvertTo-RiskScore -Device $device -CustomFields $fieldsHash
        
        # Build output object
        $riskDevice = [PSCustomObject]@{
            DeviceName = $device.systemName
            OrganizationId = $device.organizationId
            RiskScore = $riskScore
            Severity = if ($fieldsHash.ContainsKey('winreSeverity')) { if ($fieldsHash['winreSeverity'] -eq $true) { 'Warning/Critical' } else { 'Healthy' } } else { 'Unknown' }
            WinREEnabled = if ($fieldsHash.ContainsKey('winreEnabled')) { $fieldsHash['winreEnabled'] } else { $null }
            KB5034441Vulnerable = if ($fieldsHash.ContainsKey('winreKB5034441Vulnerable')) { $fieldsHash['winreKB5034441Vulnerable'] } else { $null }
            PartitionSizeMB = if ($fieldsHash.ContainsKey('winrePartitionSizeMB')) { $fieldsHash['winrePartitionSizeMB'] } else { $null }
            PartitionFreeMB = if ($fieldsHash.ContainsKey('winrePartitionFreeMB')) { $fieldsHash['winrePartitionFreeMB'] } else { $null }
            ConfidenceScore = if ($fieldsHash.ContainsKey('winreConfidenceScore')) { $fieldsHash['winreConfidenceScore'] } else { $null }
            Recommendation = if ($fieldsHash.ContainsKey('winreRecommendation')) { $fieldsHash['winreRecommendation'] } else { '' }
            LastCheck = if ($fieldsHash.ContainsKey('winreLastCheck')) { $fieldsHash['winreLastCheck'] } else { '' }
            SecureBoot = if ($fieldsHash.ContainsKey('winreSecureBoot')) { $fieldsHash['winreSecureBoot'] } else { $null }
            Windows11Ready = if ($fieldsHash.ContainsKey('winreWindows11Ready')) { $fieldsHash['winreWindows11Ready'] } else { $null }
            PendingReboot = if ($fieldsHash.ContainsKey('winrePendingReboot')) { $fieldsHash['winrePendingReboot'] } else { $null }
            RemediationReady = if ($fieldsHash.ContainsKey('winreRemediationReady')) { $fieldsHash['winreRemediationReady'] } else { $null }
        }
        
        $riskDevices += $riskDevice
    }
    
    Write-Host "  ✅ Analyzed $processed devices; found $($riskDevices.Count) at-risk" -ForegroundColor Green
    
    if ($riskDevices.Count -eq 0) {
        Write-Host "No at-risk devices found. Exiting." -ForegroundColor Yellow
        exit 0
    }
    
    # Step 4: Sort by risk score and take top N
    $topRisk = $riskDevices | Sort-Object -Property RiskScore -Descending | Select-Object -First $TopCount
    
    Write-Host ""
    Write-Host "Top $TopCount at-risk devices:" -ForegroundColor Cyan
    $topRisk | Format-Table -Property DeviceName, RiskScore, Severity, PartitionFreeMB, KB5034441Vulnerable -AutoSize
    
    # Step 5: Export to CSV
    Write-Host ""
    Write-Host "Exporting to CSV..." -ForegroundColor Yellow
    
    $topRisk | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    
    Write-Host "  ✅ CSV exported: $OutputPath" -ForegroundColor Green
    Write-Host ""
    Write-Host "=== Export Complete ===" -ForegroundColor Cyan
    Write-Host "Devices exported: $($topRisk.Count)" -ForegroundColor Gray
    Write-Host "CSV location: $OutputPath" -ForegroundColor Gray
    
} catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    exit 1
}
#endregion

