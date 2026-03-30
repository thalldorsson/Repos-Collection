# Region: In-memory registries for SQL & Key Vault endpoints
# These are per-session unless you export/import.

if (-not $script:AfoSqlConnections) { $script:AfoSqlConnections = @{} }
if (-not $script:AfoKeyVaults) { $script:AfoKeyVaults = @{} }
if (-not $script:AfoTenantId) { $script:AfoTenantId = $null }

function Set-FinOpsTenantId {
    <#
    .SYNOPSIS
        Sets the default tenant ID to use for Azure AD/Entra ID operations.

    .PARAMETER TenantId
        The Azure AD/Entra ID tenant ID (GUID).

    .EXAMPLE
        Set-FinOpsTenantId -TenantId "12345678-1234-1234-1234-123456789012"
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TenantId
    )
    $script:AfoTenantId = $TenantId
    Write-Verbose "[FinOps] Tenant ID set to: $TenantId"
    return [pscustomobject]@{ TenantId = $TenantId; Set = (Get-Date) }
}

function Get-FinOpsTenantId {
    <#
    .SYNOPSIS
        Gets the configured default tenant ID.

    .EXAMPLE
        Get-FinOpsTenantId
    #>
    [CmdletBinding()] param()
    return $script:AfoTenantId
}

function Test-FinOpsTenantId {
    <#
    .SYNOPSIS
        Tests the configured tenant ID for validity and optionally tests connectivity.

    .DESCRIPTION
        Validates that a tenant ID is configured and that it's in valid GUID format.
        Optionally tests connectivity to the tenant using Azure PowerShell.

    .PARAMETER TestConnectivity
        If specified, attempts to connect to the tenant to verify access.

    .EXAMPLE
        Test-FinOpsTenantId
        
        Validates the configured tenant ID format.

    .EXAMPLE
        Test-FinOpsTenantId -TestConnectivity
        
        Validates format and tests connectivity to the tenant.

    .OUTPUTS
        PSCustomObject with validation results including Success, TenantId, IsValidFormat, IsConnectable, and Message.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$TestConnectivity
    )

    $result = [PSCustomObject]@{
        Success        = $false
        TenantId       = $script:AfoTenantId
        IsValidFormat  = $false
        IsConnectable  = $null
        Message        = ""
        TestedAt       = Get-Date
    }

    # Check if tenant ID is configured
    if ([string]::IsNullOrWhiteSpace($script:AfoTenantId)) {
        $result.Message = "No tenant ID configured. Use Set-FinOpsTenantId to configure a tenant."
        Write-Verbose "[Test-FinOpsTenantId] $($result.Message)"
        return $result
    }

    # Validate GUID format
    try {
        $guid = [System.Guid]::Parse($script:AfoTenantId)
        $result.IsValidFormat = $true
        Write-Verbose "[Test-FinOpsTenantId] Tenant ID format is valid: $script:AfoTenantId"
    }
    catch {
        $result.Message = "Invalid tenant ID format. Must be a valid GUID."
        Write-Verbose "[Test-FinOpsTenantId] $($result.Message)"
        return $result
    }

    # Test connectivity if requested
    if ($TestConnectivity) {
        Write-Verbose "[Test-FinOpsTenantId] Testing connectivity to tenant: $script:AfoTenantId"
        try {
            # Check current context
            $currentContext = Get-AzContext -ErrorAction SilentlyContinue
            
            if ($currentContext -and $currentContext.Tenant.Id -eq $script:AfoTenantId) {
                # Already connected to the correct tenant
                Write-Verbose "[Test-FinOpsTenantId] Already connected to tenant: $script:AfoTenantId"
                $result.IsConnectable = $true
                $result.Success = $true
                $result.Message = "Tenant ID is valid and currently connected."
            }
            else {
                # Try to connect
                Write-Verbose "[Test-FinOpsTenantId] Attempting to connect to tenant: $script:AfoTenantId"
                $connectResult = Connect-AzAccount -TenantId $script:AfoTenantId -ErrorAction Stop
                
                if ($connectResult) {
                    $result.IsConnectable = $true
                    $result.Success = $true
                    $result.Message = "Tenant ID is valid and connectivity test succeeded."
                    Write-Verbose "[Test-FinOpsTenantId] Successfully connected to tenant: $script:AfoTenantId"
                }
            }
        }
        catch {
            $result.IsConnectable = $false
            $result.Success = $false
            $result.Message = "Tenant ID format is valid but connectivity test failed: $($_.Exception.Message)"
            Write-Verbose "[Test-FinOpsTenantId] Connectivity test failed: $($_.Exception.Message)"
        }
    }
    else {
        # Format validation only
        $result.Success = $true
        $result.Message = "Tenant ID format is valid. Use -TestConnectivity to verify access."
    }

    return $result
}

function Register-FinOpsSqlConnection {
    <#
    .SYNOPSIS
        Registers a named SQL connection string (up to any number, typical use: 3).

    .PARAMETER Name
        Logical name (e.g. 'Primary','Secondary','Analytics').

    .PARAMETER ConnectionString
        ADO.NET connection string (secure info is your responsibility; consider using integrated auth / managed identity where possible).

    .PARAMETER Overwrite
        Replace existing entry if it exists.

    .EXAMPLE
        Register-FinOpsSqlConnection -Name Primary -ConnectionString "Server=tcp:server1.database.windows.net;Database=FinOps;Authentication=Active Directory Default;Encrypt=True;"
    .EXAMPLE
        # Overwrite an existing connection definition
        Register-FinOpsSqlConnection -Name Primary -ConnectionString "Server=tcp:newserver.database.windows.net;Database=FinOps;Authentication=Active Directory Default;Encrypt=True;" -Overwrite
    .EXAMPLE
        # Export then import all connections
        Export-FinOpsConnectionConfig -Path .\afo-connections.json
        Import-FinOpsConnectionConfig -Path .\afo-connections.json
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ConnectionString,
        [switch]$Overwrite
    )
    if ($script:AfoSqlConnections.ContainsKey($Name) -and -not $Overwrite) { throw "SQL connection '$Name' already exists. Use -Overwrite to replace." }
    $script:AfoSqlConnections[$Name] = [pscustomobject]@{ Name = $Name; ConnectionString = $ConnectionString; Registered = (Get-Date) }
    return $script:AfoSqlConnections[$Name]
}

function Get-FinOpsSqlConnection {
    <#
    .SYNOPSIS
        Retrieves one or all registered SQL connections.
    .EXAMPLE
        # Get single by name
        (Get-FinOpsSqlConnection -Name Primary).ConnectionString
    .EXAMPLE
        # List all
        Get-FinOpsSqlConnection | Format-Table Name,Registered
    #>
    [CmdletBinding()] param(
        [string]$Name
    )
    if ($Name) { return $script:AfoSqlConnections[$Name] }
    $script:AfoSqlConnections.Values
}

function Register-FinOpsKeyVault {
    <#
    .SYNOPSIS
        Registers a Key Vault logical alias with its vault name and optional default secret prefix.
    .EXAMPLE
        Register-FinOpsKeyVault -Name Core -VaultName kv-core-prd-we-001 -DefaultSecretPrefix 'core-'
    .EXAMPLE
        # Replace an existing alias
        Register-FinOpsKeyVault -Name Core -VaultName kv-core-prd-we-002 -Overwrite

    .PARAMETER Name
        Alias (e.g. 'Core','Customer','Security','Archive').

    .PARAMETER VaultName
        Actual Azure Key Vault DNS prefix (without https:// and domain).

    .PARAMETER DefaultSecretPrefix
        Optional prefix to help build secret names programmatically.

    .PARAMETER Overwrite
        Replace existing registration.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$VaultName,
        [string]$DefaultSecretPrefix,
        [switch]$Overwrite
    )
    if ($script:AfoKeyVaults.ContainsKey($Name) -and -not $Overwrite) { throw "Key Vault '$Name' already registered. Use -Overwrite to replace." }
    $script:AfoKeyVaults[$Name] = [pscustomobject]@{
        Name = $Name
        VaultName = $VaultName
        DefaultSecretPrefix = $DefaultSecretPrefix
        Registered = (Get-Date)
    }
    return $script:AfoKeyVaults[$Name]
}

function Get-FinOpsKeyVault {
    <#
    .SYNOPSIS
        Retrieves one or all registered Key Vault definitions.
    .EXAMPLE
        Get-FinOpsKeyVault -Name Core
    .EXAMPLE
        Get-FinOpsKeyVault | Format-Table Name,VaultName,Registered
    #>
    [CmdletBinding()] param(
        [string]$Name
    )
    if ($Name) { return $script:AfoKeyVaults[$Name] }
    $script:AfoKeyVaults.Values
}

function Export-FinOpsConnectionConfig {
    <#
    .SYNOPSIS
        Exports current SQL and Key Vault registrations to a JSON file (no secrets stored—only names & connection strings).
    .EXAMPLE
        Export-FinOpsConnectionConfig -Path .\afo-connections.json

    .PARAMETER Path
        Target JSON file path.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)][string]$Path
    )
    $payload = [pscustomobject]@{
        SqlConnections = $script:AfoSqlConnections.Values
        KeyVaults = $script:AfoKeyVaults.Values
        TenantId = $script:AfoTenantId
        ExportedUtc = (Get-Date).ToUniversalTime().ToString('o')
        Version = '1.0'
    }
    $json = $payload | ConvertTo-Json -Depth 6
    Set-Content -Path $Path -Value $json -Encoding UTF8
    Get-Item -Path $Path
}

function Import-FinOpsConnectionConfig {
    <#
    .SYNOPSIS
        Imports registrations from a JSON file previously created by Export-FinOpsConnectionConfig.
    .EXAMPLE
        Import-FinOpsConnectionConfig -Path .\afo-connections.json

    .PARAMETER Path
        Source JSON file path.

    .PARAMETER Merge
        Merge with existing (default). If not specified, clears existing first.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Merge
    )
    if (-not (Test-Path -Path $Path)) { throw "Config file not found: $Path" }
    $raw = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $Merge) { $script:AfoSqlConnections = @{}; $script:AfoKeyVaults = @{} }

    foreach ($c in ($raw.SqlConnections | Where-Object { $_ })) { $script:AfoSqlConnections[$c.Name] = $c }
    foreach ($v in ($raw.KeyVaults | Where-Object { $_ })) { $script:AfoKeyVaults[$v.Name] = $v }
    if ($raw.TenantId) { $script:AfoTenantId = $raw.TenantId }

    [pscustomobject]@{
        SqlCount = $script:AfoSqlConnections.Count
        VaultCount = $script:AfoKeyVaults.Count
        TenantId = $script:AfoTenantId
        ImportedUtc = (Get-Date).ToUniversalTime().ToString('o')
        SourcePath = (Resolve-Path $Path).Path
    }
}

# --- Auto-default initialization ---------------------------------------------------------
# These defaults are registered automatically unless AFO_SKIP_DEFAULTS=1 is set in the environment.
if (-not $env:AFO_SKIP_DEFAULTS) {
    if (-not $script:AfoDefaultsApplied) {
        $script:AfoDefaultsApplied = $true
        Write-Verbose '[AzureFinOpsOnboarding] Applying default SQL & Key Vault registrations.'
        try {
            # SQL Connections
            # AWS Cost Control SQL (renamed from duplicate acc name to avoid overwrite)
            Register-FinOpsSqlConnection -Name 'sqlserver-awscc-prd-001' -ConnectionString "Data Source=sql-awscc-prd-001.database.windows.net,1433;Initial Catalog=sqldb-awscc-prd-001;Pooling=False;Connect Timeout=30;Encrypt=True;Trust Server Certificate=False;Authentication=ActiveDirectoryInteractive;Application Name=vscode-mssql;Connect Retry Count=1;Connect Retry Interval=10;Command Timeout=30" -Overwrite 2>$null
            Register-FinOpsSqlConnection -Name 'sqlserver-acc-prd-we-001' -ConnectionString "Data Source=sqlserver-acc-prd-we-001.database.windows.net;Initial Catalog=sqldb-acc-prd-001;Pooling=False;Connect Timeout=30;Encrypt=True;Authentication=ActiveDirectoryInteractive;Application Name=vscode-mssql;Application Intent=ReadWrite;Command Timeout=30" -Overwrite 2>$null
            Register-FinOpsSqlConnection -Name 'sqlserver-m365-prd-we-001' -ConnectionString "Data Source=sqlserver-m365-prd-we-001.database.windows.net;Initial Catalog=sqldb-m365-prd-001;Pooling=False;Connect Timeout=30;Encrypt=True;Authentication=ActiveDirectoryInteractive;Application Name=vscode-mssql;Application Intent=ReadWrite;Command Timeout=30" -Overwrite 2>$null

            # Key Vaults
            Register-FinOpsKeyVault -Name 'acc-prd-we-001'  -VaultName 'kv-acc-prd-we-001'  -DefaultSecretPrefix '-ACCSecret'  -Overwrite 2>$null
            Register-FinOpsKeyVault -Name 'aws-prd-we-001'  -VaultName 'kv-aws-prd-we-001'  -DefaultSecretPrefix '-AWSSecret'  -Overwrite 2>$null
            Register-FinOpsKeyVault -Name 'm365-prd-we-001' -VaultName 'kv-m365-prd-we-001' -DefaultSecretPrefix '-M365Secret' -Overwrite 2>$null
        }
        catch { Write-Warning "Failed applying default registrations: $($_.Exception.Message)" }
    }
}
