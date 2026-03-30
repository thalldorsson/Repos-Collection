# Create Data Collection Rule Association (DCRA)
# This associates the DCR with specific devices or groups

param(
    [Parameter(Mandatory=$true)]
    [string]$DCRResourceId,
    
    [Parameter(Mandatory=$true)]
    [string]$TargetResourceId,
    
    [Parameter(Mandatory=$false)]
    [string]$AssociationName = "DCRA-WinREHealth-$(Get-Date -Format 'yyyyMMddHHmmss')"
)

# Check if logged in to Azure
try {
    $context = Get-AzContext -ErrorAction Stop
    Write-Host " Connected to Azure as: $($context.Account.Id)" -ForegroundColor Green
} catch {
    Write-Host " Not logged in to Azure. Running Connect-AzAccount..." -ForegroundColor Yellow
    Connect-AzAccount
}

Write-Host "`n Association Parameters:" -ForegroundColor Cyan
Write-Host "  Association Name: $AssociationName"
Write-Host "  DCR Resource ID: $DCRResourceId"
Write-Host "  Target Resource ID: $TargetResourceId"

# Create the DCRA
Write-Host "`n Creating Data Collection Rule Association..." -ForegroundColor Cyan
try {
    $body = @{
        properties = @{
            dataCollectionRuleId = $DCRResourceId
        }
    } | ConvertTo-Json

    $uri = "https://management.azure.com$($TargetResourceId)/providers/Microsoft.Insights/dataCollectionRuleAssociations/$($AssociationName)?api-version=2022-06-01"
    
    $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type" = "application/json"
    }

    $response = Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $body

    Write-Host " DCRA created successfully!" -ForegroundColor Green
    Write-Host "`nAssociation ID: $($response.id)" -ForegroundColor White
    
} catch {
    Write-Host " DCRA creation failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "`n Tip: Ensure Azure Monitor Agent is installed on the target device" -ForegroundColor Yellow
    exit 1
}

Write-Host "`n Next Steps:" -ForegroundColor Yellow
Write-Host "1. Verify Azure Monitor Agent is installed on target device"
Write-Host "2. Run the WinRE detection script on the device"
Write-Host "3. Wait 5-10 minutes for data ingestion"
Write-Host "4. Query Log Analytics: WinREHealth_CL | where ComputerName_s == 'TARGETPC'"
