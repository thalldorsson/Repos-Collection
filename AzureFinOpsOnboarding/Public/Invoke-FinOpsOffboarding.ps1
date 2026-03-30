function Invoke-FinOpsOffboarding {
    <#
    .SYNOPSIS
    Offboards a customer from Azure FinOps by revoking Power BI access and marking as inactive in the database.

    .DESCRIPTION
    This function performs a complete offboarding workflow for FinOps customers:
    1. Removes an Entra ID group's access from a Power BI report via the Power BI REST API
    2. Updates the database to set IsActive = 0 for the specified customer record
    3. Optionally timestamps the ModifiedAt field

    The function follows the AzureFinOpsOnboarding module patterns and integrates with:
    - Power BI REST API for access revocation
    - SQL Server for customer status updates
    - Module logging and error handling patterns

    .PARAMETER WorkspaceId
    The GUID of the Power BI workspace containing the report.

    .PARAMETER ReportId
    The GUID of the Power BI report from which to revoke access.

    .PARAMETER AccessGroupObjectId
    The Entra ID (Azure AD) ObjectId of the group whose access should be revoked.

    .PARAMETER SqlConnectionString
    SQL Server connection string for the FinOps database.

    .PARAMETER KeyValue
    The primary key value (e.g., CustomerId) to identify the record to deactivate.

    .PARAMETER TableName
    Database table name. Defaults to 'Customers'.

    .PARAMETER KeyColumn
    Primary key column name. Defaults to 'CustomerId'.

    .PARAMETER UseServicePrincipal
    Use service principal authentication for Power BI instead of interactive login.

    .PARAMETER TenantId
    Azure AD Tenant ID (required when using service principal).

    .PARAMETER ClientId
    Application (Client) ID for service principal authentication.

    .PARAMETER ClientSecret
    Client secret for service principal authentication.

    .PARAMETER PassThru
    Return the offboarding result object to the pipeline.

    .EXAMPLE
    Invoke-FinOpsOffboarding -WorkspaceId "abc-123" -ReportId "def-456" `
        -AccessGroupObjectId "ghi-789" -SqlConnectionString $connStr -KeyValue "CUST001"

    Offboards customer CUST001 with interactive Power BI authentication.

    .EXAMPLE
    Invoke-FinOpsOffboarding -WorkspaceId $wsId -ReportId $rptId `
        -AccessGroupObjectId $grpId -SqlConnectionString $connStr -KeyValue "CUST002" `
        -UseServicePrincipal -TenantId $tenantId -ClientId $clientId -ClientSecret $secret `
        -PassThru

    Offboards customer CUST002 using service principal authentication and returns result.

    .OUTPUTS
    PSCustomObject with offboarding status if -PassThru is specified.
    #>
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string]$WorkspaceId,

        [Parameter(Mandatory=$true)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string]$ReportId,

        [Parameter(Mandatory=$true)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string]$AccessGroupObjectId,

        [Parameter(Mandatory=$true)]
        [string]$SqlConnectionString,

        [Parameter(Mandatory=$true)]
        [string]$KeyValue,

        [Parameter(Mandatory=$false)]
        [string]$TableName = 'Customers',

        [Parameter(Mandatory=$false)]
        [string]$KeyColumn = 'CustomerId',

        [Parameter(Mandatory=$false)]
        [switch]$UseServicePrincipal,

        [Parameter(Mandatory=$false)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string]$TenantId,

        [Parameter(Mandatory=$false)]
        [string]$ClientId,

        [Parameter(Mandatory=$false)]
        [string]$ClientSecret,

        [Parameter(Mandatory=$false)]
        [switch]$PassThru
    )

    begin {
        Write-Verbose "[Invoke-FinOpsOffboarding] Starting offboarding process for $KeyColumn = '$KeyValue'"
        
        # Validate service principal requirements
        if ($UseServicePrincipal -and (-not ($TenantId -and $ClientId -and $ClientSecret))) {
            throw "Service principal authentication requires TenantId, ClientId, and ClientSecret parameters."
        }

        $result = [PSCustomObject]@{
            KeyValue                = $KeyValue
            TableName               = $TableName
            WorkspaceId             = $WorkspaceId
            ReportId                = $ReportId
            AccessGroupObjectId     = $AccessGroupObjectId
            PowerBIAccessRevoked    = $false
            DatabaseUpdated         = $false
            RowsAffected            = 0
            Errors                  = @()
            Timestamp               = Get-Date
        }
    }

    process {
        try {
            # Step 1: Ensure Power BI module is available
            Write-Verbose "[Invoke-FinOpsOffboarding] Checking Power BI PowerShell module..."
            if (-not (Get-Module -ListAvailable -Name MicrosoftPowerBIMgmt)) {
                Write-Verbose "[Invoke-FinOpsOffboarding] Installing MicrosoftPowerBIMgmt module..."
                Install-Module -Name MicrosoftPowerBIMgmt -Force -Scope CurrentUser -AllowClobber -ErrorAction Stop
            }
            Import-Module MicrosoftPowerBIMgmt -ErrorAction Stop

            # Step 2: Authenticate to Power BI
            Write-Verbose "[Invoke-FinOpsOffboarding] Authenticating to Power BI..."
            if ($UseServicePrincipal) {
                Write-Verbose "[Invoke-FinOpsOffboarding] Using service principal authentication"
                $secureSecret = ConvertTo-SecureString -String $ClientSecret -AsPlainText -Force
                $credential = New-Object System.Management.Automation.PSCredential($ClientId, $secureSecret)
                Connect-PowerBIServiceAccount -Tenant $TenantId -ServicePrincipal -Credential $credential -ErrorAction Stop | Out-Null
            }
            else {
                Write-Verbose "[Invoke-FinOpsOffboarding] Using interactive authentication"
                $token = $null
                try { $token = Get-PowerBIAccessToken -AsString -ErrorAction Stop } catch {}
                if (-not $token) {
                    Connect-PowerBIServiceAccount -ErrorAction Stop | Out-Null
                }
            }
            Write-Verbose "[Invoke-FinOpsOffboarding] Power BI authentication successful"

            # Step 3: Revoke Power BI report access
            $endpoint = "groups/$WorkspaceId/reports/$ReportId/users/$AccessGroupObjectId"
            
            if ($PSCmdlet.ShouldProcess("Report $ReportId in workspace $WorkspaceId", "Revoke access for group $AccessGroupObjectId")) {
                try {
                    Write-Verbose "[Invoke-FinOpsOffboarding] Revoking access: DELETE $endpoint"
                    Invoke-PowerBIRestMethod -Url $endpoint -Method Delete -ErrorAction Stop | Out-Null
                    $result.PowerBIAccessRevoked = $true
                    Write-Verbose "[Invoke-FinOpsOffboarding] Successfully revoked Power BI access for group $AccessGroupObjectId"
                }
                catch {
                    $errorMsg = "Failed to revoke Power BI access: $($_.Exception.Message)"
                    Write-Warning "[Invoke-FinOpsOffboarding] $errorMsg"
                    $result.Errors += $errorMsg
                }
            }
            else {
                Write-Verbose "[Invoke-FinOpsOffboarding] WhatIf: Would revoke Power BI access"
            }

            # Step 4: Update database IsActive flag
            if ($PSCmdlet.ShouldProcess("$TableName record where $KeyColumn = '$KeyValue'", "Set IsActive = 0")) {
                try {
                    Write-Verbose "[Invoke-FinOpsOffboarding] Updating database: $TableName.$KeyColumn = '$KeyValue'"
                    
                    $query = @"
UPDATE [$TableName]
SET IsActive = @IsActive,
    ModifiedAt = SYSDATETIME()
WHERE [$KeyColumn] = @KeyValue;
SELECT @@ROWCOUNT;
"@

                    $conn = New-Object System.Data.SqlClient.SqlConnection $SqlConnectionString
                    $cmd = $conn.CreateCommand()
                    $cmd.CommandText = $query
                    $cmd.CommandTimeout = 30

                    $null = $cmd.Parameters.Add('@IsActive', [System.Data.SqlDbType]::Bit)
                    $cmd.Parameters['@IsActive'].Value = 0

                    $null = $cmd.Parameters.Add('@KeyValue', [System.Data.SqlDbType]::VarChar, 128)
                    $cmd.Parameters['@KeyValue'].Value = $KeyValue

                    $conn.Open()
                    $rowsAffected = $cmd.ExecuteScalar()
                    $result.RowsAffected = $rowsAffected

                    if ($rowsAffected -gt 0) {
                        $result.DatabaseUpdated = $true
                        Write-Verbose "[Invoke-FinOpsOffboarding] Database updated successfully. Rows affected: $rowsAffected"
                    }
                    else {
                        $warningMsg = "No rows were updated in the database. Check TableName, KeyColumn, and KeyValue parameters."
                        Write-Warning "[Invoke-FinOpsOffboarding] $warningMsg"
                        $result.Errors += $warningMsg
                    }
                }
                catch {
                    $errorMsg = "Database update failed: $($_.Exception.Message)"
                    Write-Error "[Invoke-FinOpsOffboarding] $errorMsg"
                    $result.Errors += $errorMsg
                }
                finally {
                    if ($conn -and $conn.State -ne 'Closed') {
                        $conn.Close()
                    }
                    if ($conn) {
                        $conn.Dispose()
                    }
                }
            }
            else {
                Write-Verbose "[Invoke-FinOpsOffboarding] WhatIf: Would set IsActive = 0 in database"
            }
        }
        catch {
            $errorMsg = "Offboarding process failed: $($_.Exception.Message)"
            Write-Error "[Invoke-FinOpsOffboarding] $errorMsg"
            $result.Errors += $errorMsg
        }
    }

    end {
        # Summary
        $successCount = @($result.PowerBIAccessRevoked, $result.DatabaseUpdated) | Where-Object { $_ -eq $true } | Measure-Object | Select-Object -ExpandProperty Count
        $totalSteps = 2
        
        if ($result.Errors.Count -eq 0) {
            Write-Verbose "[Invoke-FinOpsOffboarding] Offboarding completed successfully ($successCount/$totalSteps steps)"
        }
        else {
            Write-Warning "[Invoke-FinOpsOffboarding] Offboarding completed with errors ($successCount/$totalSteps steps)"
            Write-Warning "[Invoke-FinOpsOffboarding] Errors: $($result.Errors -join '; ')"
        }

        if ($PassThru) {
            return $result
        }
    }
}
