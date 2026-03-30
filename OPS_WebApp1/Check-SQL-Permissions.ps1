# Check if your user account can manage SQL Database users
# Run this to verify your permissions

Write-Host "=== Checking SQL Database Administrator Permissions ===" -ForegroundColor Cyan
Write-Host ""

# Your account from context
$currentUser = "adm_thorsteinnhalldorsson@CrayonCloudDK.onmicrosoft.com"
$serverName = "grunn-db1-m365"
$databaseName = "Grunn-m365_DB1"

Write-Host "Current User: $currentUser" -ForegroundColor Yellow
Write-Host "Target Server: $serverName" -ForegroundColor Yellow  
Write-Host "Target Database: $databaseName" -ForegroundColor Yellow
Write-Host ""

# Check if Az.Sql module is available
if (-not (Get-Module -ListAvailable -Name Az.Sql)) {
    Write-Host "Installing Az.Sql module..." -ForegroundColor Yellow
    Install-Module Az.Sql -Force -AllowClobber -Scope CurrentUser
}

try {
    # Check current Azure context
    $context = Get-AzContext
    if (-not $context) {
        Write-Host "Please login to Azure first:" -ForegroundColor Red
        Write-Host "Connect-AzAccount" -ForegroundColor White
        exit 1
    }

    Write-Host "Connected to Azure as: $($context.Account)" -ForegroundColor Green
    Write-Host ""

    # Try to get SQL Server details
    Write-Host "Checking SQL Server access..." -ForegroundColor Yellow
    $server = Get-AzSqlServer | Where-Object { $_.ServerName -eq $serverName }
    
    if ($server) {
        Write-Host "✅ Found SQL Server: $($server.ServerName)" -ForegroundColor Green
        Write-Host "   Resource Group: $($server.ResourceGroupName)" -ForegroundColor Gray
        
        # Check if you can see databases
        $databases = Get-AzSqlDatabase -ServerName $serverName -ResourceGroupName $server.ResourceGroupName
        if ($databases) {
            Write-Host "✅ Can access databases on this server" -ForegroundColor Green
            
            $targetDb = $databases | Where-Object { $_.DatabaseName -eq $databaseName }
            if ($targetDb) {
                Write-Host "✅ Found target database: $databaseName" -ForegroundColor Green
            } else {
                Write-Host "❌ Cannot find database: $databaseName" -ForegroundColor Red
                Write-Host "Available databases:" -ForegroundColor Yellow
                $databases | ForEach-Object { Write-Host "   • $($_.DatabaseName)" -ForegroundColor White }
            }
        }
    } else {
        Write-Host "❌ Cannot find SQL Server: $serverName" -ForegroundColor Red
        Write-Host "This could mean:" -ForegroundColor Yellow
        Write-Host "   • Server is in a different subscription" -ForegroundColor White
        Write-Host "   • You don't have permissions to view it" -ForegroundColor White
        Write-Host "   • Server name is incorrect" -ForegroundColor White
    }

} catch {
    Write-Host "❌ Error checking permissions: $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "=== How to Run the SQL Commands ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "✅ Option 1: If you have Azure AD Admin rights" -ForegroundColor Green
Write-Host "   1. Connect to SQL Database in Azure Portal" -ForegroundColor White
Write-Host "   2. Go to Query Editor" -ForegroundColor White  
Write-Host "   3. Run the CREATE USER commands" -ForegroundColor White
Write-Host ""
Write-Host "✅ Option 2: Using SQL Server Management Studio (SSMS)" -ForegroundColor Green
Write-Host "   1. Connect with Azure AD Authentication" -ForegroundColor White
Write-Host "   2. Select your database: $databaseName" -ForegroundColor White
Write-Host "   3. Run the SQL commands" -ForegroundColor White
Write-Host ""
Write-Host "✅ Option 3: Using PowerShell (if you have permissions)" -ForegroundColor Green
Write-Host "   Invoke-Sqlcmd -ServerInstance '$serverName.database.windows.net' \`" -ForegroundColor White
Write-Host "                 -Database '$databaseName' \`" -ForegroundColor White  
Write-Host "                 -AccessToken `$token ``" -ForegroundColor White
Write-Host "                 -Query 'CREATE USER [your-managed-identity] FROM EXTERNAL PROVIDER'" -ForegroundColor White
Write-Host ""
Write-Host "❌ If you get permission errors:" -ForegroundColor Red
Write-Host "   • Ask someone with Azure AD Administrator role on the database" -ForegroundColor White
Write-Host "   • Or ask to be granted Azure AD Administrator permissions" -ForegroundColor White