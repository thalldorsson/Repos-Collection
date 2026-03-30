# PowerShell script to find your managed identities and their names
# Run this to identify the correct names for database user creation

param(
    [string]$SubscriptionName = "",
    [string]$ResourceGroupName = ""
)

Write-Host "=== Finding Managed Identities for SQL Database Setup ===" -ForegroundColor Cyan
Write-Host ""

# Ensure Azure login
$context = Get-AzContext
if (-not $context) {
    Write-Host "Not logged into Azure. Please run Connect-AzAccount first." -ForegroundColor Red
    exit 1
}

Write-Host "Current Azure Context:" -ForegroundColor Yellow
Write-Host "  Account: $($context.Account)"
Write-Host "  Subscription: $($context.Subscription.Name)"
Write-Host ""

# Your managed identity client IDs from .env
$readClientId = "c19799df-9312-4f89-a02b-2a39df381368"
$writeClientId = "0b3be02d-0cb5-466c-84fc-861f7094bf98"

Write-Host "Looking for managed identities with client IDs:" -ForegroundColor Yellow
Write-Host "  Read MI:  $readClientId" -ForegroundColor White
Write-Host "  Write MI: $writeClientId" -ForegroundColor White
Write-Host ""

try {
    # Get all managed identities in the subscription or resource group
    if ($ResourceGroupName) {
        $managedIdentities = Get-AzUserAssignedIdentity -ResourceGroupName $ResourceGroupName
        Write-Host "Searching in Resource Group: $ResourceGroupName" -ForegroundColor Yellow
    } else {
        $managedIdentities = Get-AzUserAssignedIdentity
        Write-Host "Searching in entire subscription..." -ForegroundColor Yellow
    }

    if ($managedIdentities) {
        Write-Host "Found Managed Identities:" -ForegroundColor Green
        foreach ($mi in $managedIdentities) {
            $isReadMI = $mi.ClientId -eq $readClientId
            $isWriteMI = $mi.ClientId -eq $writeClientId
            
            if ($isReadMI -or $isWriteMI) {
                $type = if ($isReadMI) { "READ" } else { "WRITE" }
                Write-Host "  ★ $($mi.Name) [$type]" -ForegroundColor Cyan
            } else {
                Write-Host "  • $($mi.Name)" -ForegroundColor Gray
            }
            
            Write-Host "    Client ID: $($mi.ClientId)" -ForegroundColor White
            Write-Host "    Principal ID: $($mi.PrincipalId)" -ForegroundColor White
            Write-Host "    Resource Group: $($mi.ResourceGroupName)" -ForegroundColor Gray
            Write-Host ""
        }

        # Find the specific ones we need
        $readMI = $managedIdentities | Where-Object { $_.ClientId -eq $readClientId }
        $writeMI = $managedIdentities | Where-Object { $_.ClientId -eq $writeClientId }

        Write-Host "=== SQL Database User Creation Commands ===" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Run these commands in your SQL Database as Azure AD Administrator:" -ForegroundColor Yellow
        Write-Host ""

        if ($readMI) {
            Write-Host "-- Create READ managed identity user" -ForegroundColor Green
            Write-Host "CREATE USER [$($readMI.Name)] FROM EXTERNAL PROVIDER;" -ForegroundColor White
            Write-Host "ALTER ROLE db_datareader ADD MEMBER [$($readMI.Name)];" -ForegroundColor White
            Write-Host "GRANT SELECT ON SCHEMA::O365 TO [$($readMI.Name)];" -ForegroundColor White
            Write-Host ""
        } else {
            Write-Host "❌ READ Managed Identity not found with client ID: $readClientId" -ForegroundColor Red
        }

        if ($writeMI) {
            Write-Host "-- Create WRITE managed identity user" -ForegroundColor Green
            Write-Host "CREATE USER [$($writeMI.Name)] FROM EXTERNAL PROVIDER;" -ForegroundColor White
            Write-Host "ALTER ROLE db_datareader ADD MEMBER [$($writeMI.Name)];" -ForegroundColor White
            Write-Host "ALTER ROLE db_datawriter ADD MEMBER [$($writeMI.Name)];" -ForegroundColor White
            Write-Host "GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::O365 TO [$($writeMI.Name)];" -ForegroundColor White
            Write-Host ""
        } else {
            Write-Host "❌ WRITE Managed Identity not found with client ID: $writeClientId" -ForegroundColor Red
        }

        Write-Host "-- Verify the users were created" -ForegroundColor Green
        Write-Host "SELECT name, type_desc, authentication_type_desc FROM sys.database_principals" -ForegroundColor White
        Write-Host "WHERE type = 'E' AND name IN ('$(($readMI.Name, $writeMI.Name | Where-Object {$_}) -join "', '")');" -ForegroundColor White

    } else {
        Write-Host "No managed identities found." -ForegroundColor Red
    }

} catch {
    Write-Host "Error searching for managed identities: $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "=== Next Steps ===" -ForegroundColor Cyan
Write-Host "1. Run the CREATE USER commands above in your SQL database" -ForegroundColor White
Write-Host "2. Restart your API server" -ForegroundColor White
Write-Host "3. Test: Invoke-WebRequest -Uri 'http://localhost:3001/api/ready'" -ForegroundColor White