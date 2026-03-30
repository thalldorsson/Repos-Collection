function Get-FinOpsAzCustomerAppCredential {
    <#
    .SYNOPSIS
        Retrieves Tenant / Application / Secret metadata for a customer from SQL views.

    .DESCRIPTION
        Attempts lookup in priority order against: 
          1. [Azure].[udvADFListCustomer]
          2. [O365].[CustomerDetalisWithAppCred]
        Performs an automatic retry removing spaces from the provided customer name if the first attempt yields no rows.

        Returns the first matching row (or all with -All). Exposes: CustomerId, CustomerName, TenantId, ApplicationId, SecretName, Source, Country.

    .PARAMETER CustomerName
        Display name of the customer (will attempt space-stripped fallback if not found).

    .PARAMETER ConnectionString
        ADO.NET style SQL connection string. If not provided, attempts to read from environment variable AFO_SQL_CONNECTION.

    .PARAMETER All
        Return all matching rows instead of just the first.

    .EXAMPLE
        Get-FinOpsAzCustomerAppCredential -CustomerName 'gf forsikring'
    .EXAMPLE
        # Return all matching variants (with and without space)
        Get-FinOpsAzCustomerAppCredential -CustomerName 'gf forsikring' -All | Format-Table CustomerName,TenantId,ApplicationId,Source
    .EXAMPLE
        # Using an explicit SQL connection string
        Get-FinOpsAzCustomerAppCredential -CustomerName 'Contoso' -ConnectionString $env:AFO_SQL_CONNECTION

    .NOTES
        Requires appropriate SQL permissions. No secrets are retrieved here; this only returns the secret name.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)][string]$CustomerName,
        [string]$ConnectionString,
        [switch]$All
    )

    if (-not $ConnectionString) { $ConnectionString = $env:AFO_SQL_CONNECTION }
    if (-not $ConnectionString) { throw 'No connection string supplied and AFO_SQL_CONNECTION not set.' }

    $namesToTry = @($CustomerName)
    if ($CustomerName -match '\s') { $namesToTry += ($CustomerName -replace '\s', '') }

    $queryTemplates = @(
        @{ Source = 'Azure.udvADFListCustomer'; Query = "SELECT TOP (100) CustomerId, CustomerName, TenantId, ApplicationId, SecretName, NULL as Country FROM [Azure].[udvADFListCustomer] WHERE CustomerName = @CustomerName" },
        @{ Source = 'O365.CustomerDetalisWithAppCred'; Query = "SELECT TOP (100) CustomerId, CustomerName, TenantId, ApplicationId, SecretName, Country FROM [O365].[CustomerDetalisWithAppCred] WHERE CustomerName = @CustomerName" }
    )

    Add-Type -AssemblyName System.Data 2>$null
    $results = @()

    foreach ($name in $namesToTry) {
        foreach ($qt in $queryTemplates) {
            $conn = New-Object System.Data.SqlClient.SqlConnection $ConnectionString
            try {
                $conn.Open()
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = $qt.Query
                $p = $cmd.Parameters.Add('@CustomerName', [System.Data.SqlDbType]::NVarChar, 256)
                $p.Value = $name
                $rdr = $cmd.ExecuteReader()
                while ($rdr.Read()) {
                    $row = [pscustomobject]@{
                        CustomerId = $rdr['CustomerId']
                        CustomerName = $rdr['CustomerName']
                        TenantId = $rdr['TenantId']
                        ApplicationId = $rdr['ApplicationId']
                        SecretName = $rdr['SecretName']
                        Country = if ($rdr['Country'] -ne [DBNull]::Value) { $rdr['Country'] } else { $null }
                        Source = $qt.Source
                        InputVariant = $name
                    }
                    $results += $row
                }
                $rdr.Close()
            }
            finally { $conn.Dispose() }
            if ($results.Count -gt 0 -and -not $All) { return $results[0] }
        }
        if ($results.Count -gt 0 -and -not $All) { break }
    }

    if ($All) { return $results }
    if ($results.Count -eq 0) { Write-Warning "No credential row found for customer '$CustomerName' (tried variants: $($namesToTry -join ', '))" }
    return $null
}
