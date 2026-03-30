# Deploy Data Collection Rule for WinRE Health Monitoring
# This script deploys the DCR ARM template to Azure

param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory=$true)]
    [string]$WorkspaceResourceId,
    
    [Parameter(Mandatory=$false)]
    [string]$Location = "westeurope",
    
    [Parameter(Mandatory=$false)]
    [string]$DCRName = "DCR-WinREHealth"
)

# Check if logged in to Azure
try {
    $context = Get-AzContext -ErrorAction Stop
    Write-Host " Connected to Azure as: $($context.Account.Id)" -ForegroundColor Green
} catch {
    Write-Host " Not logged in to Azure. Running Connect-AzAccount..." -ForegroundColor Yellow
    Connect-AzAccount
}

# Get the script directory
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$templatePath = Join-Path $scriptDir "DCR-WinREHealth-Template.json"

if (!(Test-Path $templatePath)) {
    Write-Host " Template file not found: $templatePath" -ForegroundColor Red
    exit 1
}

Write-Host "`n Deployment Parameters:" -ForegroundColor Cyan
Write-Host "  Resource Group: $ResourceGroupName"
Write-Host "  DCR Name: $DCRName"
Write-Host "  Location: $Location"
Write-Host "  Workspace ID: $WorkspaceResourceId"

# Deploy the DCR
Write-Host "`n Deploying Data Collection Rule..." -ForegroundColor Cyan
try {
    $deployment = New-AzResourceGroupDeployment `
        -ResourceGroupName $ResourceGroupName `
        -TemplateFile $templatePath `
        -dataCollectionRuleName $DCRName `
        -location $Location `
        -workspaceResourceId $WorkspaceResourceId `
        -ErrorAction Stop

    Write-Host " DCR deployed successfully!" -ForegroundColor Green
    Write-Host "`nDCR Resource ID:" -ForegroundColor Cyan
    Write-Host $deployment.Outputs.dataCollectionRuleId.Value -ForegroundColor White
    
    Write-Host "`n Next Steps:" -ForegroundColor Yellow
    Write-Host "1. Copy the DCR Resource ID above"
    Write-Host "2. Create a Data Collection Rule Association (DCRA) for each device/group"
    Write-Host "3. Install Azure Monitor Agent on target devices via Intune"
    Write-Host "4. Run the detection script to generate health status"
    Write-Host "5. Query Log Analytics: WinREHealth_CL | take 10"
    
} catch {
    Write-Host " Deployment failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
