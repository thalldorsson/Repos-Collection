# PowerShell script to setup managed identity SQL permissions
# Run this with appropriate Azure permissions

# Login to Azure
Connect-AzAccount

# Variables - matching your .env configuration
$subscriptionId = "your-subscription-id-here"
$resourceGroup = "your-resource-group-name"
$serverName = "grunn-db1-m365"  # from your connection string
$databaseName = "Grunn-m365_DB1"  # from your connection string
$readMIClientId = "c19799df-9312-4f89-a02b-2a39df381368"
$writeMIClientId = "0b3be02d-0cb5-466c-84fc-861f7094bf98"

Write-Host "Setting up managed identity permissions for SQL Database..." -ForegroundColor Yellow

# Get the managed identity names (you'll need to find these in Azure Portal)
# Usually they match your resource names like: ops-webapp1-read-mi, ops-webapp1-write-mi

# Alternative: Connect directly to SQL and run the CREATE USER commands
Write-Host "Please run the following SQL commands as Azure AD Administrator:" -ForegroundColor Cyan
Write-Host "
-- Connect to database: $databaseName
-- Run these commands:

CREATE USER [ops-webapp1-read-mi] FROM EXTERNAL PROVIDER;
CREATE USER [ops-webapp1-write-mi] FROM EXTERNAL PROVIDER;

-- Grant permissions
ALTER ROLE db_datareader ADD MEMBER [ops-webapp1-read-mi];
ALTER ROLE db_datareader ADD MEMBER [ops-webapp1-write-mi];
ALTER ROLE db_datawriter ADD MEMBER [ops-webapp1-write-mi];
GRANT SELECT ON SCHEMA::O365 TO [ops-webapp1-read-mi];
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::O365 TO [ops-webapp1-write-mi];
" -ForegroundColor White

Write-Host "After running the SQL commands, test the connection again." -ForegroundColor Green