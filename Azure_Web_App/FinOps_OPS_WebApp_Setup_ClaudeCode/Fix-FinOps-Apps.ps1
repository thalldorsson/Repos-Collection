# ===============================================================
# FinOps App Service Troubleshooting and Fix Script
# 
# This script diagnoses and fixes common issues with the FinOps
# app deployments, specifically the Node.js startup issues
# ===============================================================

param(
    [Parameter(Mandatory = $false)]
    [string]$BackendAppName = "finops-ops-backendC",
    
    [Parameter(Mandatory = $false)]
    [string]$FrontendAppName = "finops-ops-frontendC",
    
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup = "finops-rg",
    
    [Parameter(Mandatory = $false)]
    [string]$NodeVersion = "22-lts"
)

function Write-Status {
    param(
        [string]$Message,
        [string]$Level = "Info"
    )
    
    $timestamp = Get-Date -Format "HH:mm:ss"
    switch ($Level) {
        "Success" { Write-Host "[$timestamp] ✅ $Message" -ForegroundColor Green }
        "Warning" { Write-Host "[$timestamp] ⚠️ $Message" -ForegroundColor Yellow }
        "Error" { Write-Host "[$timestamp] ❌ $Message" -ForegroundColor Red }
        "Info" { Write-Host "[$timestamp] ℹ️ $Message" -ForegroundColor Cyan }
        "Step" { Write-Host "[$timestamp] 🔧 $Message" -ForegroundColor Magenta }
    }
}

function Fix-AppServiceConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppName,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroup,
        
        [Parameter(Mandatory = $true)]
        [string]$AppType
    )
    
    Write-Status "Fixing configuration for $AppType app: $AppName" -Level "Step"
    
    try {
        # Check if app exists
        $appExists = az webapp show --name $AppName --resource-group $ResourceGroup 2>$null
        if (-not $appExists) {
            Write-Status "App $AppName not found in resource group $ResourceGroup" -Level "Error"
            return $false
        }
        
        Write-Status "App found, applying fixes..." -Level "Info"
        
        # Fix 1: Set Node.js version
        Write-Status "Setting Node.js version to $NodeVersion" -Level "Info"
        az webapp config appsettings set --name $AppName --resource-group $ResourceGroup --settings WEBSITE_NODE_DEFAULT_VERSION="$NodeVersion" --output none
        
        # Fix 2: Set startup command to npm start
        Write-Status "Setting startup command to 'npm start'" -Level "Info"
        az webapp config set --name $AppName --resource-group $ResourceGroup --startup-file "npm start" --output none
        
        # Fix 3: Enable build during deployment
        Write-Status "Enabling build during deployment" -Level "Info"
        az webapp config appsettings set --name $AppName --resource-group $ResourceGroup --settings `
            SCM_DO_BUILD_DURING_DEPLOYMENT="true" `
            WEBSITE_RUN_FROM_PACKAGE="1" `
            PORT="8080" `
            NODE_ENV="production" --output none
        
        # Fix 4: Restart the app
        Write-Status "Restarting $AppType app to apply changes" -Level "Info"
        az webapp restart --name $AppName --resource-group $ResourceGroup --output none
        
        Write-Status "$AppType app configuration fixed successfully" -Level "Success"
        return $true
        
    } catch {
        Write-Status "Failed to fix $AppType app: $_" -Level "Error"
        return $false
    }
}

function Get-AppStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppName,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroup
    )
    
    try {
        Write-Status "Checking status for: $AppName" -Level "Info"
        
        # Get app details
        $appDetails = az webapp show --name $AppName --resource-group $ResourceGroup | ConvertFrom-Json
        $appSettings = az webapp config appsettings list --name $AppName --resource-group $ResourceGroup | ConvertFrom-Json
        
        Write-Host "   📊 Status: $($appDetails.state)" -ForegroundColor White
        Write-Host "   🌐 URL: https://$($appDetails.defaultHostName)" -ForegroundColor White
        Write-Host "   🔧 Runtime: $($appDetails.siteConfig.linuxFxVersion)" -ForegroundColor White
        
        # Check important settings
        $nodeVersion = ($appSettings | Where-Object { $_.name -eq "WEBSITE_NODE_DEFAULT_VERSION" }).value
        $startupCommand = $appDetails.siteConfig.appCommandLine
        $buildDuringDeploy = ($appSettings | Where-Object { $_.name -eq "SCM_DO_BUILD_DURING_DEPLOYMENT" }).value
        $port = ($appSettings | Where-Object { $_.name -eq "PORT" }).value
        
        Write-Host "   📦 Node version: $($nodeVersion ?? 'Not set')" -ForegroundColor White
        Write-Host "   🚀 Startup command: $($startupCommand ?? 'Not set')" -ForegroundColor White
        Write-Host "   🔨 Build during deployment: $($buildDuringDeploy ?? 'Not set')" -ForegroundColor White
        Write-Host "   🔌 Port: $($port ?? 'Not set')" -ForegroundColor White
        
        return @{
            Status = $appDetails.state
            URL = "https://$($appDetails.defaultHostName)"
            NodeVersion = $nodeVersion
            StartupCommand = $startupCommand
            BuildDuringDeploy = $buildDuringDeploy
            Port = $port
        }
        
    } catch {
        Write-Status "Error checking status: $_" -Level "Error"
        return $null
    }
}

function Test-AppUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        
        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 30
    )
    
    try {
        Write-Status "Testing URL: $Url" -Level "Info"
        
        $response = Invoke-WebRequest -Uri $Url -TimeoutSec $TimeoutSeconds -UseBasicParsing
        
        if ($response.StatusCode -eq 200) {
            Write-Status "URL responded successfully (200 OK)" -Level "Success"
            return $true
        } else {
            Write-Status "URL responded with status: $($response.StatusCode)" -Level "Warning"
            return $false
        }
        
    } catch {
        Write-Status "URL test failed: $_" -Level "Error"
        return $false
    }
}

function Get-AppLogs {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppName,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroup
    )
    
    try {
        Write-Status "Getting recent logs for: $AppName" -Level "Info"
        
        # Enable logging first
        az webapp log config --name $AppName --resource-group $ResourceGroup --web-server-logging filesystem --output none
        
        # Get logs
        Write-Host "`n📄 Recent logs for $AppName:" -ForegroundColor Yellow
        az webapp log tail --name $AppName --resource-group $ResourceGroup --provider application
        
    } catch {
        Write-Status "Error getting logs: $_" -Level "Error"
    }
}

# ===============================================================
# Main Script Execution
# ===============================================================

Write-Host "`n🔧 FinOps App Service Troubleshooter" -ForegroundColor Green
Write-Host "=" * 50 -ForegroundColor Cyan

Write-Status "Starting diagnostics and fixes..." -Level "Step"
Write-Status "Backend App: $BackendAppName" -Level "Info"
Write-Status "Frontend App: $FrontendAppName" -Level "Info"
Write-Status "Resource Group: $ResourceGroup" -Level "Info"

# Check Azure CLI
try {
    $azAccount = az account show 2>$null
    if (-not $azAccount) {
        Write-Status "Please login to Azure CLI first: az login" -Level "Error"
        exit 1
    }
} catch {
    Write-Status "Azure CLI not found or not working" -Level "Error"
    exit 1
}

# Step 1: Get current status
Write-Host "`n🔍 CURRENT STATUS" -ForegroundColor Yellow
Write-Host "-" * 30 -ForegroundColor Gray

$backendStatus = Get-AppStatus -AppName $BackendAppName -ResourceGroup $ResourceGroup
$frontendStatus = Get-AppStatus -AppName $FrontendAppName -ResourceGroup $ResourceGroup

# Step 2: Fix configurations
Write-Host "`n🔧 APPLYING FIXES" -ForegroundColor Yellow
Write-Host "-" * 30 -ForegroundColor Gray

$backendFixed = Fix-AppServiceConfiguration -AppName $BackendAppName -ResourceGroup $ResourceGroup -AppType "Backend"
$frontendFixed = Fix-AppServiceConfiguration -AppName $FrontendAppName -ResourceGroup $ResourceGroup -AppType "Frontend"

# Step 3: Wait for restart and test
Write-Host "`n⏳ WAITING FOR RESTART" -ForegroundColor Yellow
Write-Host "-" * 30 -ForegroundColor Gray

Write-Status "Waiting 30 seconds for apps to restart..." -Level "Info"
Start-Sleep -Seconds 30

# Step 4: Test URLs
Write-Host "`n🧪 TESTING APPLICATIONS" -ForegroundColor Yellow
Write-Host "-" * 30 -ForegroundColor Gray

if ($backendStatus) {
    $backendUrlWorking = Test-AppUrl -Url $backendStatus.URL
    $backendHealthWorking = Test-AppUrl -Url "$($backendStatus.URL)/health"
}

if ($frontendStatus) {
    $frontendUrlWorking = Test-AppUrl -Url $frontendStatus.URL
}

# Step 5: Final status
Write-Host "`n📊 FINAL STATUS" -ForegroundColor Yellow
Write-Host "-" * 30 -ForegroundColor Gray

Write-Status "Backend configuration fixed: $backendFixed" -Level $(if($backendFixed) {"Success"} else {"Error"})
Write-Status "Frontend configuration fixed: $frontendFixed" -Level $(if($frontendFixed) {"Success"} else {"Error"})

if ($backendStatus) {
    Write-Status "Backend URL working: $backendUrlWorking" -Level $(if($backendUrlWorking) {"Success"} else {"Warning"})
    Write-Status "Backend health endpoint: $backendHealthWorking" -Level $(if($backendHealthWorking) {"Success"} else {"Warning"})
}

if ($frontendStatus) {
    Write-Status "Frontend URL working: $frontendUrlWorking" -Level $(if($frontendUrlWorking) {"Success"} else {"Warning"})
}

# Step 6: Show URLs and next steps
Write-Host "`n🌐 APPLICATION URLS" -ForegroundColor Yellow
Write-Host "-" * 30 -ForegroundColor Gray

if ($backendStatus) {
    Write-Host "🔧 Backend: $($backendStatus.URL)" -ForegroundColor White
    Write-Host "🧪 Health Check: $($backendStatus.URL)/health" -ForegroundColor White
    Write-Host "📊 API Status: $($backendStatus.URL)/api/status" -ForegroundColor White
}

if ($frontendStatus) {
    Write-Host "🎨 Frontend: $($frontendStatus.URL)" -ForegroundColor White
}

Write-Host "`n📋 NEXT STEPS" -ForegroundColor Yellow
Write-Host "-" * 30 -ForegroundColor Gray

Write-Host "1. 🌐 Test the URLs above in your browser" -ForegroundColor White
Write-Host "2. 📄 If still not working, check logs:" -ForegroundColor White
Write-Host "   Get-AppLogs -AppName '$BackendAppName' -ResourceGroup '$ResourceGroup'" -ForegroundColor Gray
Write-Host "   Get-AppLogs -AppName '$FrontendAppName' -ResourceGroup '$ResourceGroup'" -ForegroundColor Gray
Write-Host "3. 🔄 If needed, redeploy with the main script" -ForegroundColor White
Write-Host "4. 🏗️ Check Azure portal for detailed diagnostics" -ForegroundColor White

Write-Host "`n✅ Troubleshooting completed!" -ForegroundColor Green
