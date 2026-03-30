param (
  [string]$resourceGroupName = "MyResourceGroup",
  [string]$location = "westeurope",
  [string]$webAppName = "azure-sql-api-webapp",
  [string]$sqlServerName = "grunn-db1-web-dev",
  [string]$sqlAdminUsername = "sqladminuser",
  [string]$sqlAdminPassword
)

az group create --name $resourceGroupName --location $location

az deployment group create --resource-group $resourceGroupName `
  --template-file ./infra/main.bicep `
  --parameters webAppName=$webAppName sqlServerName=$sqlServerName `
              sqlAdminUsername=$sqlAdminUsername sqlAdminPassword=$sqlAdminPassword