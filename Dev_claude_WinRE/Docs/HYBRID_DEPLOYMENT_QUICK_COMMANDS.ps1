# Hybrid deployment — quick commands (PowerShell)

# Variables
$SubscriptionId = '1b6a9d60-35ae-4f21-8dab-66c85fc756d2'
$ResourceGroup   = 'rg-winre-health-we-prod'
$Location        = 'westeurope'
$Workspace       = 'law-winre-health-we-prod'

# Set subscription
az account set --subscription $SubscriptionId

# Create resource group
az group create --name $ResourceGroup --location $Location

# Deploy Bicep template to create Log Analytics workspace
az deployment group create `
  --resource-group $ResourceGroup `
  --template-file infra/bicep/law-winre.bicep `
  --parameters workspaceName=$Workspace

# Retrieve workspace id and primary shared key
$WorkspaceId = az monitor log-analytics workspace show `
  --resource-group $ResourceGroup `
  --workspace-name $Workspace `
  --query customerId -o tsv

$WorkspaceKey = az monitor log-analytics workspace get-shared-keys `
  --resource-group $ResourceGroup `
  --workspace-name $Workspace `
  --query primarySharedKey -o tsv

Write-Output "Workspace ID: $WorkspaceId"

# Optional: set for current PowerShell session (do NOT commit these)
$env:LA_WORKSPACE_ID  = $WorkspaceId
$env:LA_WORKSPACE_KEY = $WorkspaceKey
$env:ENABLE_AZURE_LOGGING = 'true'
