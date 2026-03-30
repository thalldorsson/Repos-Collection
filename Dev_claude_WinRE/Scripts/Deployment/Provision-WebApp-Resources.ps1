#Requires -Version 7.0
<#
.SYNOPSIS
    Provisions Azure resources for WinRE Health Web App

.DESCRIPTION
    Creates all required Azure resources for Phase 4 web application:
    - Resource Group
    - App Service Plan (S1 tier)
    - App Service (web app)
    - Key Vault (secrets management)
    - Cosmos DB (feedback storage)
    - Managed Identity
    - RBAC role assignments

.PARAMETER ResourceGroupName
    Name of the resource group to create

.PARAMETER Location
    Azure region (default: westeurope)

.PARAMETER AppName
    Name of the web app (must be globally unique)

.PARAMETER LogAnalyticsWorkspaceId
    Optional: Resource ID of Log Analytics workspace for RBAC assignment

.EXAMPLE
    .\Provision-WebApp-Resources.ps1 -ResourceGroupName "rg-winre-webapp" -AppName "webapp-winre-health-contoso"

.EXAMPLE
    .\Provision-WebApp-Resources.ps1 `
        -ResourceGroupName "rg-winre-webapp" `
        -AppName "webapp-winre-health-contoso" `
        -Location "eastus" `
        -LogAnalyticsWorkspaceId "/subscriptions/xxx/resourceGroups/xxx/providers/Microsoft.OperationalInsights/workspaces/xxx"

.NOTES
    Estimated time: 10-15 minutes
    Estimated cost: ~$90/month (S1 App Service + Cosmos Serverless + Key Vault)
    
    Prerequisites:
    - Azure CLI installed (az --version >= 2.50)
    - Logged in to Azure (az login)
    - Contributor role on subscription
    
    Author: WinRE Health Toolkit Team
    Version: 1.0.0
    Date: January 10, 2026
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory=$false)]
    [string]$Location = "westeurope",
    
    [Parameter(Mandatory=$true)]
    [string]$AppName,
    
    [Parameter(Mandatory=$false)]
    [string]$LogAnalyticsWorkspaceId
)

$ErrorActionPreference = "Stop"

# Validate Azure CLI is installed
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI not found. Install from: https://aka.ms/installazurecliwindows"
}

# Login to Azure (if not already logged in)
Write-Host "Checking Azure login status..." -ForegroundColor Cyan
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Host "Not logged in. Initiating Azure login..." -ForegroundColor Yellow
    az login
    $account = az account show | ConvertFrom-Json
}

Write-Host "Logged in as: $($account.user.name)" -ForegroundColor Green
Write-Host "Subscription: $($account.name) ($($account.id))" -ForegroundColor Green

# Generate resource names
$appServicePlanName = "plan-$AppName"
$keyVaultName = "kv-$(($AppName -replace '[^a-z0-9]', '').Substring(0, [Math]::Min(20, $AppName.Length)))"
$cosmosDbName = "cosmos-$(($AppName -replace '[^a-z0-9]', '').Substring(0, [Math]::Min(20, $AppName.Length)))-fb"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "WinRE Health Web App - Resource Provisioning" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Resource Group: $ResourceGroupName" -ForegroundColor White
Write-Host "  Location: $Location" -ForegroundColor White
Write-Host "  App Service Plan: $appServicePlanName (S1 tier)" -ForegroundColor White
Write-Host "  Web App: $AppName" -ForegroundColor White
Write-Host "  Key Vault: $keyVaultName" -ForegroundColor White
Write-Host "  Cosmos DB: $cosmosDbName (Serverless)" -ForegroundColor White

$confirm = Read-Host "`nProceed with provisioning? (yes/no)"
if ($confirm -ne "yes") {
    Write-Host "Provisioning cancelled." -ForegroundColor Yellow
    exit 0
}

# Step 1: Create Resource Group
Write-Host "`n[1/7] Creating Resource Group..." -ForegroundColor Cyan
az group create --name $ResourceGroupName --location $Location | Out-Null
Write-Host "✓ Resource Group created: $ResourceGroupName" -ForegroundColor Green

# Step 2: Create App Service Plan
Write-Host "`n[2/7] Creating App Service Plan (S1 tier)..." -ForegroundColor Cyan
az appservice plan create `
    --name $appServicePlanName `
    --resource-group $ResourceGroupName `
    --location $Location `
    --sku S1 `
    --is-linux | Out-Null
Write-Host "✓ App Service Plan created: $appServicePlanName" -ForegroundColor Green

# Step 3: Create Web App
Write-Host "`n[3/7] Creating Web App..." -ForegroundColor Cyan
az webapp create `
    --name $AppName `
    --resource-group $ResourceGroupName `
    --plan $appServicePlanName `
    --runtime "NODE:18-lts" | Out-Null  # Change to "DOTNET:8.0" for ASP.NET Core
Write-Host "✓ Web App created: $AppName" -ForegroundColor Green
Write-Host "  URL: https://$AppName.azurewebsites.net" -ForegroundColor Gray

# Step 4: Enable Managed Identity
Write-Host "`n[4/7] Enabling Managed Identity..." -ForegroundColor Cyan
$identity = az webapp identity assign `
    --name $AppName `
    --resource-group $ResourceGroupName | ConvertFrom-Json
Write-Host "✓ Managed Identity enabled" -ForegroundColor Green
Write-Host "  Principal ID: $($identity.principalId)" -ForegroundColor Gray

# Step 5: Create Key Vault
Write-Host "`n[5/7] Creating Key Vault..." -ForegroundColor Cyan
az keyvault create `
    --name $keyVaultName `
    --resource-group $ResourceGroupName `
    --location $Location `
    --enable-rbac-authorization false | Out-Null
Write-Host "✓ Key Vault created: $keyVaultName" -ForegroundColor Green

# Grant web app access to Key Vault
Write-Host "  Granting Key Vault access to web app..." -ForegroundColor Cyan
az keyvault set-policy `
    --name $keyVaultName `
    --object-id $identity.principalId `
    --secret-permissions get list | Out-Null
Write-Host "✓ Key Vault access granted" -ForegroundColor Green

# Step 6: Create Cosmos DB
Write-Host "`n[6/7] Creating Cosmos DB (Serverless)..." -ForegroundColor Cyan
az cosmosdb create `
    --name $cosmosDbName `
    --resource-group $ResourceGroupName `
    --locations regionName=$Location `
    --capabilities EnableServerless | Out-Null
Write-Host "✓ Cosmos DB created: $cosmosDbName" -ForegroundColor Green

# Create database and container
Write-Host "  Creating database and container..." -ForegroundColor Cyan
az cosmosdb sql database create `
    --account-name $cosmosDbName `
    --resource-group $ResourceGroupName `
    --name "WinREFeedback" | Out-Null

az cosmosdb sql container create `
    --account-name $cosmosDbName `
    --resource-group $ResourceGroupName `
    --database-name "WinREFeedback" `
    --name "FeedbackItems" `
    --partition-key-path "/feedbackType" `
    --throughput 400 | Out-Null
Write-Host "✓ Database and container created" -ForegroundColor Green

# Step 7: Grant Log Analytics Access (if workspace provided)
if ($LogAnalyticsWorkspaceId) {
    Write-Host "`n[7/7] Granting Log Analytics Reader access..." -ForegroundColor Cyan
    az role assignment create `
        --assignee $identity.principalId `
        --role "Log Analytics Reader" `
        --scope $LogAnalyticsWorkspaceId | Out-Null
    Write-Host "✓ Log Analytics access granted" -ForegroundColor Green
} else {
    Write-Host "`n[7/7] Skipping Log Analytics access (workspace ID not provided)" -ForegroundColor Yellow
}

# Summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Provisioning Complete!" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "Resources Created:" -ForegroundColor Yellow
Write-Host "✓ Resource Group: $ResourceGroupName" -ForegroundColor Green
Write-Host "✓ App Service Plan: $appServicePlanName (S1 tier)" -ForegroundColor Green
Write-Host "✓ Web App: $AppName" -ForegroundColor Green
Write-Host "  URL: https://$AppName.azurewebsites.net" -ForegroundColor Gray
Write-Host "✓ Managed Identity: Enabled" -ForegroundColor Green
Write-Host "✓ Key Vault: $keyVaultName" -ForegroundColor Green
Write-Host "✓ Cosmos DB: $cosmosDbName (Serverless)" -ForegroundColor Green

Write-Host "`nNext Steps:" -ForegroundColor Yellow
Write-Host "1. Configure Entra ID app registration (see Docs/WEEK3-FEEDBACK-WEBAPP-SETUP.md)" -ForegroundColor White
Write-Host "2. Store Entra client secret in Key Vault" -ForegroundColor White
Write-Host "3. Deploy web app code (Month 2)" -ForegroundColor White
Write-Host "4. Configure IP restrictions via Conditional Access" -ForegroundColor White

Write-Host "`nEstimated Monthly Cost: ~$90" -ForegroundColor Cyan
Write-Host "  - App Service Plan (S1): $70" -ForegroundColor Gray
Write-Host "  - Key Vault: $5" -ForegroundColor Gray
Write-Host "  - Cosmos DB (Serverless): $10" -ForegroundColor Gray
Write-Host "  - Bandwidth: $5" -ForegroundColor Gray

# Output resource IDs to file for reference
$output = @{
    ResourceGroupName = $ResourceGroupName
    Location = $Location
    AppServicePlanName = $appServicePlanName
    AppName = $AppName
    AppUrl = "https://$AppName.azurewebsites.net"
    ManagedIdentityPrincipalId = $identity.principalId
    KeyVaultName = $keyVaultName
    CosmosDbName = $cosmosDbName
    ProvisionedDate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
}

$outputFile = "webapp-resources-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$output | ConvertTo-Json | Set-Content -Path $outputFile
Write-Host "`nResource details saved to: $outputFile" -ForegroundColor Cyan
