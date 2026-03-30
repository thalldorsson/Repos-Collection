<#
.SYNOPSIS
    PowerShell helper script to test tenant access credentials.

.DESCRIPTION
    This script performs the following:
    1. Searches for a customer by CustomerId, Name, or Domain
    2. Retrieves customer tenant access info and refresh schedule
    3. Fetches the client secret from Azure Key Vault
    4. Tests Graph API token acquisition
    5. Optionally updates NextRefreshDateKey to tomorrow

.PARAMETER CustomerId
    The customer ID to search for.

.PARAMETER Name
    Customer name to search for (partial match).

.PARAMETER Domain
    Customer domain to search for (exact match).

.PARAMETER UpdateRefresh
    If specified, updates the NextRefreshDateKey to tomorrow.

.EXAMPLE
    .\Test-TenantAccess.ps1 -CustomerId 123
    
.EXAMPLE
    .\Test-TenantAccess.ps1 -Domain "contoso.com" -UpdateRefresh

#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$CustomerId,

    [Parameter(Mandatory = $false)]
    [string]$Name,

    [Parameter(Mandatory = $false)]
    [string]$Domain,

    [Parameter(Mandatory = $false)]
    [switch]$UpdateRefresh
)

#Requires -Modules Az.Accounts, Az.KeyVault

# Configuration
$SqlServer = "sqlserver-m365-prd-we-001.database.windows.net"
$Database = "sqldb-m365-prd-001"
$KeyVaultName = "kv-m365-prd-we-001"

Write-Host "=== Tenant Access Test ===" -ForegroundColor Cyan
Write-Host ""

# Ensure Azure login and get SQL access token
Write-Host "Connecting to Azure..." -ForegroundColor Yellow
$context = Get-AzContext
if (-not $context) {
    Write-Host "Not logged into Azure. Running Connect-AzAccount..." -ForegroundColor Yellow
    Connect-AzAccount
}

Write-Host "Getting SQL access token..." -ForegroundColor Yellow
$token = (Get-AzAccessToken -ResourceUrl "https://database.windows.net/").Token
Write-Host "Token acquired successfully!" -ForegroundColor Green
Write-Host ""

# Step 1: Build and execute search query
Write-Host "[1/5] Searching for customer..." -ForegroundColor Yellow

$searchQuery = @"
SELECT 
    CustomerId,
    SUBSTRING(CustomerName, 1, 50) AS CustomerName,
    SUBSTRING(TenantId, 1, 36) AS TenantId,
    SUBSTRING(Domain, 1, 50) AS Domain
FROM [O365].[CustomerDetalisWithAppCred]
WHERE 1=1
"@

$whereConditions = @()
if ($CustomerId) { $whereConditions += "CustomerId = '$CustomerId'" }
if ($Name) { $whereConditions += "CustomerName LIKE '%$Name%'" }
if ($Domain) { $whereConditions += "Domain = '$Domain'" }

if ($whereConditions.Count -gt 0) {
    $searchQuery += " AND (" + ($whereConditions -join " OR ") + ")"
}

$searchQuery += " ORDER BY CustomerName"

try {
    # Connect to SQL (requires Azure login and database permissions)
    $customers = Invoke-Sqlcmd -ServerInstance $SqlServer -Database $Database -Query $searchQuery -AccessToken $token
    
    if (-not $customers) {
        Write-Host "No customers found matching search criteria." -ForegroundColor Red
        exit 1
    }

    Write-Host "Found $($customers.Count) customer(s):" -ForegroundColor Green
    $customers | Format-Table CustomerId, CustomerName, Domain -AutoSize

    # If multiple results, prompt user
    if ($customers.Count -gt 1) {
        $selectedId = Read-Host "Enter CustomerId to continue"
        $customer = $customers | Where-Object { $_.CustomerId -eq $selectedId }
        if (-not $customer) {
            Write-Host "Invalid CustomerId." -ForegroundColor Red
            exit 1
        }
    } else {
        $customer = $customers[0]
    }

} catch {
    Write-Host "Error searching customers: $_" -ForegroundColor Red
    exit 1
}

Write-Host ""

# Step 2: Get tenant access info
Write-Host "[2/5] Retrieving tenant access info..." -ForegroundColor Yellow

$accessQuery = @"
SELECT 
    c.CustomerId,
    c.CustomerName,
    c.TenantId,
    c.Domain,
    c.ApplicationId,
    c.SecretName,
    a.LastRefreshDateKey,
    a.NextRefreshDateKey,
    a.IsActive,
    a.RunFrequencyInDays
FROM [O365].[CustomerDetalisWithAppCred] c
LEFT JOIN [O365].[AppCredential] a ON c.CustomerId = a.CustomerId
WHERE c.CustomerId = '$($customer.CustomerId)'
"@

try {
    $accessInfo = Invoke-Sqlcmd -ServerInstance $SqlServer -Database $Database -Query $accessQuery -AccessToken $token
    
    Write-Host "Customer Details:" -ForegroundColor Green
    Write-Host "  CustomerId:      $($accessInfo.CustomerId)"
    Write-Host "  Name:            $($accessInfo.CustomerName)"
    Write-Host "  TenantId:        $($accessInfo.TenantId)"
    Write-Host "  Domain:          $($accessInfo.Domain)"
    Write-Host "  ApplicationId:   $($accessInfo.ApplicationId)"
    Write-Host "  SecretName:      $($accessInfo.SecretName)"
    Write-Host ""
    Write-Host "Refresh Schedule:" -ForegroundColor Green
    Write-Host "  Last Refresh:    $($accessInfo.LastRefreshDateKey)"
    Write-Host "  Next Refresh:    $($accessInfo.NextRefreshDateKey)"
    Write-Host "  Active:          $($accessInfo.IsActive)"
    Write-Host "  Frequency:       $($accessInfo.RunFrequencyInDays) days"

} catch {
    Write-Host "Error retrieving access info: $_" -ForegroundColor Red
    exit 1
}

Write-Host ""

# Step 3: Fetch secret from Key Vault
Write-Host "[3/5] Fetching secret from Key Vault..." -ForegroundColor Yellow

try {
    # Ensure Azure login
    $context = Get-AzContext
    if (-not $context) {
        Write-Host "Not logged into Azure. Running Connect-AzAccount..." -ForegroundColor Yellow
        Connect-AzAccount
    }

    $secret = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $accessInfo.SecretName -AsPlainText
    
    if ($secret) {
        Write-Host "Secret retrieved successfully (length: $($secret.Length) chars)" -ForegroundColor Green
        $maskedSecret = $secret.Substring(0, [Math]::Min(4, $secret.Length)) + "..." + $secret.Substring([Math]::Max(0, $secret.Length - 4))
        Write-Host "  Masked value: $maskedSecret" -ForegroundColor Gray
    } else {
        Write-Host "Secret not found in Key Vault." -ForegroundColor Red
        exit 1
    }

} catch {
    Write-Host "Error fetching secret: $_" -ForegroundColor Red
    exit 1
}

Write-Host ""

# Step 4: Test Graph API token
Write-Host "[4/5] Testing Graph API token acquisition..." -ForegroundColor Yellow

try {
    $tokenBody = @{
        client_id     = $accessInfo.ApplicationId
        client_secret = $secret
        scope         = "https://graph.microsoft.com/.default"
        grant_type    = "client_credentials"
    }

    $tokenResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$($accessInfo.TenantId)/oauth2/v2.0/token" -Method Post -Body $tokenBody -ContentType "application/x-www-form-urlencoded"

    Write-Host "Token acquired successfully!" -ForegroundColor Green
    Write-Host "  Token type:   $($tokenResponse.token_type)"
    Write-Host "  Expires in:   $($tokenResponse.expires_in) seconds"
    Write-Host "  Scope:        $($tokenResponse.scope)"

    # Test Graph API call
    Write-Host ""
    Write-Host "Testing Graph API call (organization info)..." -ForegroundColor Yellow
    
    $headers = @{
        Authorization = "$($tokenResponse.token_type) $($tokenResponse.access_token)"
    }

    $orgInfo = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/organization" -Headers $headers -Method Get

    if ($orgInfo.value) {
        Write-Host "Organization info retrieved successfully!" -ForegroundColor Green
        $org = $orgInfo.value[0]
        Write-Host "  Display Name:        $($org.displayName)"
        Write-Host "  Tenant Type:         $($org.tenantType)"
        Write-Host "  Verified Domains:    $($org.verifiedDomains.Count)"
    }

} catch {
    Write-Host "Error testing Graph API: $_" -ForegroundColor Red
    Write-Host "Response: $($_.Exception.Response.StatusCode) - $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""

# Step 5: Optionally update refresh date
if ($UpdateRefresh) {
    Write-Host "[5/5] Updating NextRefreshDateKey to tomorrow..." -ForegroundColor Yellow

    $tomorrow = (Get-Date).AddDays(1).ToString("yyyyMMdd")

    $updateQuery = @"
UPDATE [O365].[AppCredential]
SET NextRefreshDateKey = '$tomorrow'
WHERE CustomerId = '$($customer.CustomerId)'
"@

    try {
        Invoke-Sqlcmd -ServerInstance $SqlServer -Database $Database -Query $updateQuery -AccessToken $token
        Write-Host "NextRefreshDateKey updated to $tomorrow" -ForegroundColor Green
    } catch {
        Write-Host "Error updating refresh date: $_" -ForegroundColor Red
    }
} else {
    Write-Host "[5/5] Skipping refresh update (use -UpdateRefresh to enable)" -ForegroundColor Gray
}

Write-Host ""
Write-Host "=== Test Complete ===" -ForegroundColor Cyan
