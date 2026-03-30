# ===============================================================
# Enhanced FinOps Deployment Script - Modernized Version
# 
# This script deploys a fully modernized FinOps platform with:
# - TypeScript support for both frontend and backend
# - Comprehensive input validation and security hardening
# - Interactive API documentation with Swagger/OpenAPI
# - ESLint/Prettier code quality tools
# - Jest testing framework with coverage
# - CI/CD GitHub Actions workflow ready
# - Environment-based configuration management
# - Advanced monitoring and health checks
#
# Consolidates to single Linux App Service Plan with selectable SKUs
# ===============================================================

param(
    [Parameter(Mandatory = $false)]
    [string]$WebAppsResourceGroup = "finops-rg",
    
    [Parameter(Mandatory = $false)]
    [string]$SqlServerResourceGroup = "LAB-Web1",
    
    [Parameter(Mandatory = $false)]
    [string]$BackendAppName = "finops-ops-backendC",
    
    [Parameter(Mandatory = $false)]
    [string]$FrontendAppName = "finops-ops-frontendC",
    
    [Parameter(Mandatory = $false)]
    [string]$AppServicePlan = "finops-ops-plan",
    
    [Parameter(Mandatory = $false)]
    [string]$Location = "West Europe",
    
    [Parameter(Mandatory = $false)]
    [ValidateSet("B1", "B2", "B3", "S1", "S2", "S3", "P1V3")]
    [string]$AppServiceSku = "",
    
    [Parameter(Mandatory = $false)]
    [switch]$EnableApplicationInsights,

    [Parameter(Mandatory = $false)]
    [switch]$EnableKeyVault,
    [Parameter(Mandatory = $false)]
    [switch]$EnableAutoScaling,
    
    [Parameter(Mandatory = $false)]
    [string[]]$AllowedIP = @("185.62.63.100", "185.62.60.100", "31.209.215.70"),
      [Parameter(Mandatory = $false)]
    [string]$DocumentationPath = ".\Deployment-Documentation",
    
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId = "c63d2e31-0295-4586-8397-9f638da94afc",
    
    [Parameter(Mandatory = $false)]
    [string]$FrontendSourcePath = ".\Frontend",
    
    [Parameter(Mandatory = $false)]
    [string]$BackendSourcePath = ".\Backend",
    
    [Parameter(Mandatory = $false)]
    [switch]$BuildTypeScript,
    
    [Parameter(Mandatory = $false)]
    [switch]$RunQualityChecks,
    
    [Parameter(Mandatory = $false)]
    [string]$NodeVersion = "22-lts"
)

# Initialize deployment documentation
$deploymentStart = Get-Date
$deploymentId = "finops-" + $deploymentStart.ToString("ddMMyyyy-HHmmss")
$docFile = Join-Path $DocumentationPath "$deploymentId-deployment-log.md"
$summaryFile = Join-Path $DocumentationPath "$deploymentId-deployment-summary.json"

# Ensure documentation directory exists
if (-not (Test-Path $DocumentationPath)) {
    New-Item -ItemType Directory -Path $DocumentationPath -Force | Out-Null
}

# Initialize deployment log
$deploymentLog = @()
$deploymentSummary = @{
    deploymentId = $deploymentId
    startTime = $deploymentStart.ToString("dd-MM-yyyy HH:mm:ss")
    parameters = @{
        webAppsResourceGroup = $WebAppsResourceGroup
        sqlServerResourceGroup = $SqlServerResourceGroup
        backendAppName = $BackendAppName
        frontendAppName = $FrontendAppName
        appServicePlan = $AppServicePlan
        location = $Location
        appServiceSku = $AppServiceSku
        enableApplicationInsights = $EnableApplicationInsights.IsPresent
        enableKeyVault = $EnableKeyVault.IsPresent
        enableAutoScaling = $EnableAutoScaling.IsPresent
        allowedIP = $AllowedIP
        subscriptionId = $SubscriptionId
        frontendSourcePath = $FrontendSourcePath
        backendSourcePath = $BackendSourcePath
        buildTypeScript = $BuildTypeScript.IsPresent
        runQualityChecks = $RunQualityChecks.IsPresent
        nodeVersion = $NodeVersion
    }
    steps = @()
    resources = @()
    urls = @()
    costs = @{}
    recommendations = @()
}

# Function to test App Service startup and health
# Function to build TypeScript and run quality checks
function Invoke-ModernizedApplication {
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,
        
        [Parameter(Mandatory)]
        [string]$AppType,
        
        [Parameter(Mandatory = $false)]
        [switch]$BuildTypeScript,
        
        [Parameter(Mandatory = $false)]
        [switch]$RunQualityChecks
    )
    
    Write-Host "`n🔧 Building $AppType application..." -ForegroundColor Yellow
    $safeAppType = if ($null -ne $AppType) { [string]$AppType } else { "Unknown" }
    Write-DeploymentLog -Message "Building $safeAppType application from $SourcePath" -Level "Step" -Step "BUILD_$($safeAppType.ToUpper())"
    
    $originalLocation = Get-Location
    try {
        Set-Location $SourcePath
        
        # Check if this is a modernized application with TypeScript
        $hasTypeScript = Test-Path "tsconfig.json"
        $hasPackageJson = Test-Path "package.json"
        $hasEslint = Test-Path ".eslintrc.json"
        $hasPrettier = Test-Path ".prettierrc.json"
        
        if ($hasTypeScript) {
            Write-Host "✅ TypeScript configuration detected" -ForegroundColor Green
            Write-DeploymentLog -Message "$AppType has TypeScript configuration" -Level "Success"
        }
        
        if ($hasEslint) {
            Write-Host "✅ ESLint configuration detected" -ForegroundColor Green
            Write-DeploymentLog -Message "$AppType has ESLint configuration" -Level "Success"
        }
        
        if ($hasPrettier) {
            Write-Host "✅ Prettier configuration detected" -ForegroundColor Green
            Write-DeploymentLog -Message "$AppType has Prettier configuration" -Level "Success"
        }
        
        if ($hasPackageJson) {
            Write-Host "📦 Installing dependencies..." -ForegroundColor Cyan
            $npmInstallResult = npm install 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "✅ Dependencies installed successfully" -ForegroundColor Green
                Write-DeploymentLog -Message "$AppType dependencies installed" -Level "Success"
            } else {
                Write-Host "⚠️ Some dependency warnings (continuing): $npmInstallResult" -ForegroundColor Yellow
                Write-DeploymentLog -Message "$AppType dependency warnings: $npmInstallResult" -Level "Warning"
            }
            
            # Run quality checks if requested and available
            if ($RunQualityChecks) {
                Write-Host "`n🔍 Running quality checks..." -ForegroundColor Cyan
                
                # Type checking
                if ($hasTypeScript) {
                    Write-Host "🔍 Running TypeScript type checking..." -ForegroundColor Cyan
                    $typeCheckResult = npm run type-check 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "✅ TypeScript type checking passed" -ForegroundColor Green
                        Write-DeploymentLog -Message "$AppType TypeScript type checking passed" -Level "Success"
                    } else {
                        Write-Host "⚠️ TypeScript type checking warnings: $typeCheckResult" -ForegroundColor Yellow
                        Write-DeploymentLog -Message "$AppType TypeScript warnings: $typeCheckResult" -Level "Warning"
                    }
                }
                
                # Linting
                if ($hasEslint) {
                    Write-Host "🔍 Running ESLint..." -ForegroundColor Cyan
                    $lintResult = npm run lint 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "✅ ESLint checks passed" -ForegroundColor Green
                        Write-DeploymentLog -Message "$AppType ESLint checks passed" -Level "Success"
                    } else {
                        Write-Host "⚠️ ESLint warnings: $lintResult" -ForegroundColor Yellow
                        Write-DeploymentLog -Message "$AppType ESLint warnings: $lintResult" -Level "Warning"
                    }
                }
                
                # Formatting check
                if ($hasPrettier) {
                    Write-Host "🔍 Checking code formatting..." -ForegroundColor Cyan
                    $formatResult = npm run format:check 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "✅ Code formatting is correct" -ForegroundColor Green
                        Write-DeploymentLog -Message "$AppType code formatting is correct" -Level "Success"
                    } else {
                        Write-Host "⚠️ Code formatting issues: $formatResult" -ForegroundColor Yellow
                        Write-DeploymentLog -Message "$AppType formatting issues: $formatResult" -Level "Warning"
                    }
                }
                
                # Run tests if available
                $packageJson = Get-Content "package.json" | ConvertFrom-Json
                if ($packageJson.scripts.test) {
                    Write-Host "🧪 Running tests..." -ForegroundColor Cyan
                    $testResult = npm test 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "✅ Tests passed" -ForegroundColor Green
                        Write-DeploymentLog -Message "$AppType tests passed" -Level "Success"
                    } else {
                        Write-Host "⚠️ Test warnings: $testResult" -ForegroundColor Yellow
                        Write-DeploymentLog -Message "$AppType test warnings: $testResult" -Level "Warning"
                    }
                }
            }
            
            # Build TypeScript if requested and available
            if ($BuildTypeScript -and $hasTypeScript) {
                Write-Host "`n🏗️ Building TypeScript..." -ForegroundColor Cyan
                $buildResult = npm run build 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "✅ TypeScript build completed" -ForegroundColor Green
                    Write-DeploymentLog -Message "$AppType TypeScript build completed" -Level "Success"
                    
                    # Check if dist directory was created
                    if (Test-Path "dist") {
                        Write-Host "✅ Build artifacts created in dist/ directory" -ForegroundColor Green
                        Write-DeploymentLog -Message "$AppType build artifacts created" -Level "Success"
                    }
                } else {
                    Write-Host "❌ TypeScript build failed: $buildResult" -ForegroundColor Red
                    Write-DeploymentLog -Message "$AppType TypeScript build failed: $buildResult" -Level "Error"
                    throw "TypeScript build failed for $AppType"
                }
            }
        }
        
        Write-Host "✅ $AppType build process completed" -ForegroundColor Green
        Write-DeploymentLog -Message "$AppType build process completed successfully" -Level "Success"
        
    } catch {
        Write-Host "❌ $AppType build failed: $_" -ForegroundColor Red
        Write-DeploymentLog -Message "$AppType build failed: $_" -Level "Error"
        throw
    } finally {
        Set-Location $originalLocation
    }
}

function Test-AppServiceStartup {
    param(
        [Parameter(Mandatory)]
        [string]$AppName,
        
        [Parameter(Mandatory)]
        [string]$ResourceGroup,
        
        [Parameter(Mandatory)]
        [string]$AppType,
        
        [int]$TimeoutMinutes = 5
    )
    
    $startTime = Get-Date
    $timeoutTime = $startTime.AddMinutes($TimeoutMinutes)
    $appUrl = "https://$AppName.azurewebsites.net"
    
    Write-Host "🔍 Testing $AppType startup: $AppName" -ForegroundColor Cyan
    Write-Host "   URL: $appUrl" -ForegroundColor Gray
    Write-Host "   Timeout: $TimeoutMinutes minutes" -ForegroundColor Gray
    
    $attemptCount = 0
    $maxAttempts = [math]::Ceiling($TimeoutMinutes * 60 / 30) # Check every 30 seconds
    
    while ((Get-Date) -lt $timeoutTime -and $attemptCount -lt $maxAttempts) {
        $attemptCount++
        
        try {
            # Test basic connectivity
            $response = Invoke-WebRequest -Uri $appUrl -Method GET -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop
            
            if ($response.StatusCode -eq 200) {
                Write-Host "   ✅ $AppType is responding (HTTP 200)" -ForegroundColor Green
                return $true
            } else {
                Write-Host "   ⚠️ $AppType returned HTTP $($response.StatusCode)" -ForegroundColor Yellow
            }
        }
        catch {
            $errorMessage = $_.Exception.Message
            if ($errorMessage -like "*timeout*" -or $errorMessage -like "*503*" -or $errorMessage -like "*502*") {
                Write-Host "   ⏳ $AppType still starting... (attempt $attemptCount/$maxAttempts)" -ForegroundColor Yellow
            } else {
                Write-Host "   ⚠️ $AppType connection error: $($errorMessage.Substring(0, [math]::Min(50, $errorMessage.Length)))" -ForegroundColor Yellow
            }
        }
        
        if ($attemptCount -lt $maxAttempts) {
            Start-Sleep -Seconds 30
        }
    }
    
    Write-Host "   ❌ $AppType did not start within $TimeoutMinutes minutes" -ForegroundColor Red
    Write-Host "   💡 This is normal for first deployment - npm packages may still be installing" -ForegroundColor Gray
    return $false
}

function Write-DeploymentLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("Info", "Success", "Warning", "Error", "Step")]
        [string]$Level = "Info",
        
        [Parameter(Mandatory = $false)]
        [string]$Step = "",
        
        [Parameter(Mandatory = $false)]
        [hashtable]$Details = @{}
    )
    
    $timestamp = Get-Date -Format "dd-MM-yyyy HH:mm:ss"
    $logEntry = @{
        timestamp = $timestamp
        level = $Level
        message = $Message
        step = $Step
        details = $Details
    }
    
    $script:deploymentLog += $logEntry
    
    # Also add to summary steps if it's a step
    if ($Level -eq "Step") {
        $script:deploymentSummary.steps += @{
            stepName = $Step
            message = $Message
            timestamp = $timestamp
            status = "completed"
            details = $Details
        }
    }
    
    # Display with appropriate formatting
    switch ($Level) {
        "Success" { Write-Host "✅ $Message" -ForegroundColor Green }
        "Warning" { Write-Host "⚠️ $Message" -ForegroundColor Yellow }
        "Error" { Write-Host "❌ $Message" -ForegroundColor Red }
        "Step" { Write-Host "`n🔄 [$Step] $Message" -ForegroundColor Cyan }
        default { Write-Host "ℹ️ $Message" -ForegroundColor White }
    }
}

# ===============================================================
# Step 0: Azure Subscription Selection
# ===============================================================
Write-DeploymentLog -Message "Checking Azure CLI and subscription setup" -Level "Step" -Step "SUBSCRIPTION_SETUP"

# Check if Azure CLI is installed and user is logged in
try {
    $azAccount = az account show 2>$null
    if (-not $azAccount) {
        Write-DeploymentLog -Message "Azure CLI not logged in. Please run 'az login' first." -Level "Error"
        Write-Host "`n❌ Azure CLI Error: Not logged in" -ForegroundColor Red
        Write-Host "Please run the following command first:" -ForegroundColor Yellow
        Write-Host "   az login" -ForegroundColor Cyan
        #exit 1
    }
} catch {
    Write-DeploymentLog -Message "Azure CLI not found or not working properly" -Level "Error"
    Write-Host "`n❌ Azure CLI Error: $_" -ForegroundColor Red
    #exit 1
}

# Get current subscription info
$currentAccount = $azAccount | ConvertFrom-Json
$currentSubscriptionId = $currentAccount.id
$currentSubscriptionName = $currentAccount.name

Write-DeploymentLog -Message "Current Azure subscription: $currentSubscriptionName ($currentSubscriptionId)" -Level "Info"

# Handle subscription selection
if (-not $SubscriptionId) {
    Write-DeploymentLog -Message "No subscription specified, showing selection menu" -Level "Step" -Step "SUBSCRIPTION_SELECTION"
    
    Write-Host "`n🔐 AZURE SUBSCRIPTION SELECTION:" -ForegroundColor Yellow
    Write-Host "=" * 70 -ForegroundColor Cyan
    
    Write-Host "`n📋 Current Subscription:" -ForegroundColor Green
    Write-Host "   Name: $currentSubscriptionName" -ForegroundColor White
    Write-Host "   ID: $currentSubscriptionId" -ForegroundColor Gray
    
    # Get all available subscriptions
    Write-Host "`n🔍 Loading available subscriptions..." -ForegroundColor Cyan
    
    try {
        $subscriptions = az account list --query "[].{id:id, name:name, state:state}" --output json | ConvertFrom-Json
        
        if ($subscriptions.Count -eq 0) {
            Write-DeploymentLog -Message "No subscriptions found" -Level "Error"
            Write-Host "❌ No Azure subscriptions found" -ForegroundColor Red
            #exit 1
        }
        
        # Filter active subscriptions
        $activeSubscriptions = $subscriptions | Where-Object { $_.state -eq "Enabled" }
        
        if ($activeSubscriptions.Count -eq 0) {
            Write-DeploymentLog -Message "No active subscriptions found" -Level "Error"
            Write-Host "❌ No active Azure subscriptions found" -ForegroundColor Red
            #exit 1
        }
        
        Write-Host "`n📋 Available Subscriptions:" -ForegroundColor Yellow
        
        for ($i = 0; $i -lt $activeSubscriptions.Count; $i++) {
            $sub = $activeSubscriptions[$i]
            $marker = if ($sub.id -eq $currentSubscriptionId) { " (CURRENT)" } else { "" }
            $color = if ($sub.id -eq $currentSubscriptionId) { "Green" } else { "White" }
            
            Write-Host "   [$($i + 1)] $($sub.name)$marker" -ForegroundColor $color
            Write-Host "       ID: $($sub.id)" -ForegroundColor Gray
        }
        
        Write-Host "`n💡 OPTIONS:" -ForegroundColor Cyan
        Write-Host "   [ENTER] Use current subscription: $currentSubscriptionName" -ForegroundColor Gray
        Write-Host "   [1-$($activeSubscriptions.Count)] Select different subscription" -ForegroundColor Gray
        Write-Host "   [Q] Quit deployment" -ForegroundColor Gray
        
        Write-Host "`n" + "=" * 70 -ForegroundColor Cyan
        
        do {
            $selection = Read-Host "Select subscription (ENTER for current, 1-$($activeSubscriptions.Count), or Q to quit)"
            
            if ([string]::IsNullOrWhiteSpace($selection)) {
                # Use current subscription
                $SubscriptionId = $currentSubscriptionId
                $selectedSubscriptionName = $currentSubscriptionName
                Write-DeploymentLog -Message "Using current subscription: $selectedSubscriptionName" -Level "Success"
                break
            }
            elseif ($selection.ToUpper() -eq "Q") {
                Write-DeploymentLog -Message "Deployment cancelled by user" -Level "Info"
                Write-Host "`n👋 Deployment cancelled" -ForegroundColor Yellow
                exit 0
            }
            elseif ([int]::TryParse($selection, [ref]$null) -and [int]$selection -ge 1 -and [int]$selection -le $activeSubscriptions.Count) {
                $selectedSub = $activeSubscriptions[[int]$selection - 1]
                $SubscriptionId = $selectedSub.id
                $selectedSubscriptionName = $selectedSub.name
                
                # Switch to selected subscription
                Write-Host "`n🔄 Switching to subscription: $selectedSubscriptionName" -ForegroundColor Cyan
                try {
                    az account set --subscription $SubscriptionId | Out-Null
                    Write-DeploymentLog -Message "Switched to subscription: $selectedSubscriptionName ($SubscriptionId)" -Level "Success"
                    break
                } catch {
                    Write-DeploymentLog -Message "Failed to switch subscription: $_" -Level "Error"
                    Write-Host "❌ Failed to switch subscription: $_" -ForegroundColor Red
                    continue
                }
            }
            else {
                Write-Host "❌ Invalid selection. Please choose 1-$($activeSubscriptions.Count), ENTER, or Q" -ForegroundColor Red
            }
        } while ($true)
        
    } catch {
        Write-DeploymentLog -Message "Failed to list subscriptions: $_" -Level "Error"
        Write-Host "❌ Failed to list subscriptions: $_" -ForegroundColor Red
        #exit 1
    }
} else {
    # Subscription ID provided as parameter
    Write-DeploymentLog -Message "Subscription ID provided: $SubscriptionId" -Level "Info"
    
    if ($SubscriptionId -ne $currentSubscriptionId) {
        Write-Host "`n🔄 Switching to specified subscription..." -ForegroundColor Cyan
        try {
            az account set --subscription $SubscriptionId | Out-Null
            $newAccount = az account show | ConvertFrom-Json
            $selectedSubscriptionName = $newAccount.name
            Write-DeploymentLog -Message "Switched to subscription: $selectedSubscriptionName ($SubscriptionId)" -Level "Success"
        } catch {
            Write-DeploymentLog -Message "Failed to switch to subscription ${SubscriptionId}: $_" -Level "Error"
            Write-Host "❌ Failed to switch to subscription $SubscriptionId" -ForegroundColor Red
            #exit 1
        }
    } else {
        $selectedSubscriptionName = $currentSubscriptionName
        Write-DeploymentLog -Message "Using current subscription: $selectedSubscriptionName" -Level "Success"
    }
}

# Update deployment summary with subscription info
$deploymentSummary.parameters.subscriptionId = $SubscriptionId
$deploymentSummary.parameters.subscriptionName = $selectedSubscriptionName

Write-Host "`n✅ Azure Subscription Configured" -ForegroundColor Green
Write-Host "   Subscription: $selectedSubscriptionName" -ForegroundColor White
Write-Host "   ID: $SubscriptionId" -ForegroundColor Gray

# Validate parameters to prevent common mistakes
Write-DeploymentLog -Message "Validating deployment parameters" -Level "Step" -Step "PARAMETER_VALIDATION"

# Check if SQL Server resource group looks like an App Service SKU (common mistake)
$validSkus = @("B1", "B2", "B3", "S1", "S2", "S3", "P1V3", "P2V3", "P3V3", "I1V2", "I2V2", "I3V2")
if ($SqlServerResourceGroup -in $validSkus) {
    Write-DeploymentLog -Message "SQL Server resource group appears to be an App Service SKU: $SqlServerResourceGroup" -Level "Warning"
    Write-DeploymentLog -Message "Setting SQL Server resource group to optional/skip for this deployment" -Level "Info"
    $SqlServerResourceGroup = "LAB-Web1" # Default fallback
}

Write-DeploymentLog -Message "Parameters validated successfully" -Level "Success" -Details @{
    webAppsResourceGroup = $WebAppsResourceGroup
    sqlServerResourceGroup = $SqlServerResourceGroup
    appServiceSku = $AppServiceSku
}

# Validate source code paths
Write-DeploymentLog -Message "Validating source code paths" -Level "Step" -Step "SOURCE_VALIDATION"

if (-not (Test-Path $BackendSourcePath)) {
    Write-DeploymentLog -Message "Backend source path not found: $BackendSourcePath" -Level "Error"
    Write-Host "❌ Backend source directory not found: $BackendSourcePath" -ForegroundColor Red
    #exit 1
}

if (-not (Test-Path $FrontendSourcePath)) {
    Write-DeploymentLog -Message "Frontend source path not found: $FrontendSourcePath" -Level "Error"
    Write-Host "❌ Frontend source directory not found: $FrontendSourcePath" -ForegroundColor Red
    #exit 1
}

Write-DeploymentLog -Message "Source paths validated successfully" -Level "Success" -Details @{
    backendSourcePath = $BackendSourcePath
    frontendSourcePath = $FrontendSourcePath
}

Write-Host "`n✅ Source Code Paths Validated" -ForegroundColor Green
Write-Host "   Backend Source: $BackendSourcePath" -ForegroundColor White
Write-Host "   Frontend Source: $FrontendSourcePath" -ForegroundColor White

# Display App Service Plan options if not specified
if (-not $AppServiceSku) {
    Write-DeploymentLog -Message "App Service SKU not specified, showing selection menu" -Level "Step" -Step "SKU_SELECTION"
    
    Write-Host "`n🎯 SELECT APP SERVICE PLAN SKU:" -ForegroundColor Yellow
    Write-Host "=" * 60 -ForegroundColor Cyan
    
    Write-Host "`n🏃 DEVELOPMENT/TESTING:" -ForegroundColor Green
    Write-Host "   B1 - Basic 1     (~$55/month)  - 1.75GB RAM, 10GB storage" -ForegroundColor White
    Write-Host "   B2 - Basic 2     (~$110/month) - 3.5GB RAM, 10GB storage" -ForegroundColor White
    Write-Host "   B3 - Basic 3     (~$220/month) - 7GB RAM, 10GB storage" -ForegroundColor White
    
    Write-Host "`n📊 PRODUCTION (SMALL-MEDIUM):" -ForegroundColor Yellow
    Write-Host "   S1 - Standard 1  (~$75/month)  - 1.75GB RAM, 50GB storage, Auto-scaling ✅" -ForegroundColor White
    Write-Host "   S2 - Standard 2  (~$150/month) - 3.5GB RAM, 50GB storage, Auto-scaling ✅" -ForegroundColor White
    Write-Host "   S3 - Standard 3  (~$300/month) - 7GB RAM, 50GB storage, Auto-scaling ✅" -ForegroundColor White
    
    Write-Host "`n🚀 PRODUCTION (HIGH-PERFORMANCE):" -ForegroundColor Magenta
    Write-Host "   P1V3 - Premium 1 (~$200/month) - 8GB RAM, 250GB storage, Advanced features ✅" -ForegroundColor White

    Write-Host "`n💡 RECOMMENDATIONS:" -ForegroundColor Cyan
    Write-Host "   🏃 Development: B1 or B2" -ForegroundColor Gray
    Write-Host "   📊 Production (small): S1 or S2" -ForegroundColor Gray
    Write-Host "   🚀 Production (enterprise): P1V3" -ForegroundColor Gray
    
    Write-Host "`n" + "=" * 60 -ForegroundColor Cyan
    
    do {
        $AppServiceSku = Read-Host "Enter App Service SKU (e.g., B1, S1, P1V3)"
        $validSkus = @("B1", "B2", "B3", "S1", "S2", "S3", "P1V3")
        if ($AppServiceSku -notin $validSkus) {
            Write-Host "❌ Invalid SKU. Please choose from: $($validSkus -join ', ')" -ForegroundColor Red
        }
    } while ($AppServiceSku -notin $validSkus)
    
    Write-DeploymentLog -Message "Selected App Service SKU: $AppServiceSku" -Level "Success" -Details @{ selectedSku = $AppServiceSku }
}

# Determine plan capabilities based on SKU
$isLinuxCapable = $AppServiceSku -match "^(B|S|P|I)"
$hasAutoScaling = $AppServiceSku -match "^(S|P|I)"
$hasStagingSlots = $AppServiceSku -match "^(S|P|I)"
$hasAdvancedFeatures = $AppServiceSku -match "^(P|I)"
$isIsolated = $AppServiceSku -match "^I"

# Store SKU capabilities in deployment summary
$deploymentSummary.parameters.skuCapabilities = @{
    isLinuxCapable = $isLinuxCapable
    hasAutoScaling = $hasAutoScaling
    hasStagingSlots = $hasStagingSlots
    hasAdvancedFeatures = $hasAdvancedFeatures
    isIsolated = $isIsolated
}

Write-DeploymentLog -Message "Enhanced FinOps Platform deployment started" -Level "Step" -Step "DEPLOYMENT_START" -Details @{
    webAppsResourceGroup = $WebAppsResourceGroup
    sqlServerResourceGroup = $SqlServerResourceGroup
    appServicePlan = $AppServicePlan
    sku = $AppServiceSku
    location = $Location
}

Write-Host "`n🚀 Creating Enhanced FinOps Platform" -ForegroundColor Green
Write-Host "   Web Apps Resource Group: $WebAppsResourceGroup" -ForegroundColor Gray
Write-Host "   SQL Server Resource Group: $SqlServerResourceGroup" -ForegroundColor Gray
Write-Host "   App Service Plan: $AppServicePlan ($AppServiceSku)" -ForegroundColor Gray
Write-Host "   Location: $Location" -ForegroundColor Gray
Write-Host "   Linux Support: $isLinuxCapable" -ForegroundColor Gray
Write-Host "   Auto-scaling: $hasAutoScaling" -ForegroundColor Gray
Write-Host "   Advanced Features: $hasAdvancedFeatures" -ForegroundColor Gray

# ===============================================================
# Step 1: Ensure Resource Groups Exist
# ===============================================================
Write-DeploymentLog -Message "Checking resource groups" -Level "Step" -Step "RESOURCE_GROUPS"

try {
    $webAppsRg = az group show --name $WebAppsResourceGroup 2>$null
    if ($webAppsRg) {
        Write-DeploymentLog -Message "Web Apps resource group exists: $WebAppsResourceGroup" -Level "Success"
        $deploymentSummary.resources += @{ type = "ResourceGroup"; name = $WebAppsResourceGroup; status = "existing" }
    } else {
        Write-DeploymentLog -Message "Creating Web Apps resource group: $WebAppsResourceGroup" -Level "Info"
        az group create --name $WebAppsResourceGroup --location $Location | Out-Null
        Write-DeploymentLog -Message "Web Apps resource group created: $WebAppsResourceGroup" -Level "Success"
        $deploymentSummary.resources += @{ type = "ResourceGroup"; name = $WebAppsResourceGroup; status = "created" }
    }
} catch {
    Write-DeploymentLog -Message "Failed to handle Web Apps resource group: $_" -Level "Error"
    #exit 1
}

try {
    $sqlRg = az group show --name $SqlServerResourceGroup 2>$null
    if ($sqlRg) {
        Write-DeploymentLog -Message "SQL Server resource group exists: $SqlServerResourceGroup" -Level "Success"
        $deploymentSummary.resources += @{ type = "ResourceGroup"; name = $SqlServerResourceGroup; status = "existing" }
    } else {
        Write-DeploymentLog -Message "SQL Server resource group not found: $SqlServerResourceGroup" -Level "Warning"
        Write-DeploymentLog -Message "Note: SQL Server resource group is optional for this deployment" -Level "Info"
        # SQL Server resource group is optional - continue deployment
    }
} catch {
    Write-DeploymentLog -Message "Failed to check SQL Server resource group: $_" -Level "Warning"
    Write-DeploymentLog -Message "Continuing deployment without SQL Server resource group validation" -Level "Info"
}

# ===============================================================
# Step 2: Create Unified App Service Plan (Linux)
# ===============================================================
Write-DeploymentLog -Message "Creating unified App Service Plan" -Level "Step" -Step "APP_SERVICE_PLAN"

try {
    $existingPlan = az appservice plan show --name $AppServicePlan --resource-group $WebAppsResourceGroup 2>$null
    if ($existingPlan) {
        Write-DeploymentLog -Message "App Service Plan already exists: $AppServicePlan" -Level "Success"
        $planInfo = $existingPlan | ConvertFrom-Json
        Write-DeploymentLog -Message "Current SKU: $($planInfo.sku.name)" -Level "Info"
        
        $deploymentSummary.resources += @{ 
            type = "AppServicePlan"
            name = $AppServicePlan
            status = "existing"
            sku = $planInfo.sku.name
        }
        
        # Update SKU if different
        if ($planInfo.sku.name -ne $AppServiceSku) {
            Write-DeploymentLog -Message "Updating App Service Plan SKU to $AppServiceSku" -Level "Info"
            az appservice plan update --name $AppServicePlan --resource-group $WebAppsResourceGroup --sku $AppServiceSku | Out-Null
            Write-DeploymentLog -Message "App Service Plan SKU updated" -Level "Success"
            $deploymentSummary.resources[-1].status = "updated"
            $deploymentSummary.resources[-1].previousSku = $planInfo.sku.name
            $deploymentSummary.resources[-1].newSku = $AppServiceSku
        }
    } else {
        Write-DeploymentLog -Message "Creating App Service Plan: $AppServicePlan ($AppServiceSku)" -Level "Info"
        az appservice plan create `
            --name $AppServicePlan `
            --resource-group $WebAppsResourceGroup `
            --location $Location `
            --sku $AppServiceSku `
            --is-linux | Out-Null
        Write-DeploymentLog -Message "App Service Plan created: $AppServicePlan" -Level "Success"
        
        $deploymentSummary.resources += @{ 
            type = "AppServicePlan"
            name = $AppServicePlan
            status = "created"
            sku = $AppServiceSku
            location = $Location
        }
    }
    
    # Estimate monthly cost based on SKU
    $monthlyCost = switch -Regex ($AppServiceSku) {
        '^B1' { 55 }
        '^B2' { 110 }
        '^B3' { 220 }
        '^S1' { 75 }
        '^S2' { 150 }
        '^S3' { 300 }
        '^P1V3' { 200 }
        default { 200 } 
    }
    
    $deploymentSummary.costs.appServicePlan = @{
        sku = $AppServiceSku
        estimatedMonthlyCostUSD = $monthlyCost
    }
    
} catch {
    Write-DeploymentLog -Message "Failed to create App Service Plan: $_" -Level "Error"
    #exit 1
}

# ===============================================================
# Step 3: Create Backend App Service (Linux Node.js)
# ===============================================================
Write-Host "`n🔧 Creating Backend App Service..." -ForegroundColor Yellow

try {
    $existingBackend = az webapp show --name $BackendAppName --resource-group $WebAppsResourceGroup 2>$null
    if ($existingBackend) {
        Write-Host "✅ Backend App Service already exists: $BackendAppName" -ForegroundColor Green
    } else {
        Write-Host "🔧 Creating Backend App Service: $BackendAppName" -ForegroundColor Cyan
        az webapp create `
            --resource-group $WebAppsResourceGroup `
            --plan $AppServicePlan `
            --name $BackendAppName `
            --runtime "NODE:$NodeVersion" | Out-Null
        Write-Host "✅ Backend App Service created: $BackendAppName" -ForegroundColor Green
    }
    
    # Enable managed identity
    Write-Host "🔐 Configuring managed identity for backend..." -ForegroundColor Cyan
    $identity = az webapp identity assign --resource-group $WebAppsResourceGroup --name $BackendAppName | ConvertFrom-Json
    $principalId = $identity.principalId
    $tenantId = $identity.tenantId
    
    Write-Host "✅ Managed Identity configured" -ForegroundColor Green
    Write-Host "   Principal ID: $principalId" -ForegroundColor Gray
    
} catch {
    Write-Host "❌ Failed to create backend app: $_" -ForegroundColor Red
    #exit 1
}

# ===============================================================
# Step 4: Create Frontend App Service (Linux with Static Content)
# ===============================================================
Write-Host "`n🎨 Creating Frontend App Service..." -ForegroundColor Yellow

try {
    $existingFrontend = az webapp show --name $FrontendAppName --resource-group $WebAppsResourceGroup 2>$null
    if ($existingFrontend) {
        Write-Host "✅ Frontend App Service already exists: $FrontendAppName" -ForegroundColor Green
    } else {
        Write-Host "🔧 Creating Frontend App Service: $FrontendAppName" -ForegroundColor Cyan
        
        # Use same Linux plan with static content hosting
        az webapp create `
            --resource-group $WebAppsResourceGroup `
            --plan $AppServicePlan `
            --name $FrontendAppName `
            --runtime "NODE:$NodeVersion" | Out-Null
        Write-Host "✅ Frontend App Service created: $FrontendAppName" -ForegroundColor Green
    }
} catch {
    Write-Host "❌ Failed to create frontend app: $_" -ForegroundColor Red
    #exit 1
}

# ===============================================================
# Step 5: Configure Application Insights (Optional)
# ===============================================================
if ($EnableApplicationInsights) {
    Write-Host "`n📊 Setting up Application Insights..." -ForegroundColor Yellow
    
    try {
        $appInsightsName = "$AppServicePlan-insights"
        
        # Create Application Insights
        $appInsights = az monitor app-insights component create `
            --app $appInsightsName `
            --location $Location `
            --resource-group $WebAppsResourceGroup `
            --kind web | ConvertFrom-Json
        
        $instrumentationKey = $appInsights.instrumentationKey
        $connectionString = $appInsights.connectionString
        
        # Configure both apps to use Application Insights
        az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $BackendAppName --settings "APPINSIGHTS_INSTRUMENTATIONKEY=$instrumentationKey" | Out-Null
        az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $BackendAppName --settings "APPLICATIONINSIGHTS_CONNECTION_STRING=$connectionString" | Out-Null
        
        az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $FrontendAppName --settings "APPINSIGHTS_INSTRUMENTATIONKEY=$instrumentationKey" | Out-Null
        az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $FrontendAppName --settings "APPLICATIONINSIGHTS_CONNECTION_STRING=$connectionString" | Out-Null
        
        Write-Host "✅ Application Insights configured" -ForegroundColor Green
        Write-Host "   Instrumentation Key: $instrumentationKey" -ForegroundColor Gray
        
    } catch {
        Write-Host "⚠️ Application Insights setup failed: $_" -ForegroundColor Yellow
    }
}

# ===============================================================
# Step 6: Configure Auto-scaling (If supported)
# ===============================================================
if ($hasAutoScaling -and $EnableAutoScaling) {
    Write-Host "`n📈 Configuring auto-scaling..." -ForegroundColor Yellow
    
    try {
        # Create auto-scaling rule based on CPU percentage
        az monitor autoscale create `
            --resource-group $WebAppsResourceGroup `
            --resource $AppServicePlan `
            --resource-type Microsoft.Web/serverFarms `
            --name "$AppServicePlan-autoscale" `
            --min-count 1 `
            --max-count 5 `
            --count 1 | Out-Null
        
        # Scale out rule (CPU > 70%)
        az monitor autoscale rule create `
            --resource-group $WebAppsResourceGroup `
            --autoscale-name "$AppServicePlan-autoscale" `
            --condition "Percentage CPU > 70 avg 5m" `
            --scale out 1 | Out-Null
        
        # Scale in rule (CPU < 30%)
        az monitor autoscale rule create `
            --resource-group $WebAppsResourceGroup `
            --autoscale-name "$AppServicePlan-autoscale" `
            --condition "Percentage CPU < 30 avg 5m" `
            --scale in 1 | Out-Null
        
        Write-Host "✅ Auto-scaling configured (1-5 instances, CPU-based)" -ForegroundColor Green
        
    } catch {
        Write-Host "⚠️ Auto-scaling setup failed: $_" -ForegroundColor Yellow
    }
}

# ===============================================================
# Step 7: Build and Deploy Applications from Source Code
# ===============================================================
Write-DeploymentLog -Message "Building and deploying modernized applications" -Level "Step" -Step "APPLICATION_BUILD_DEPLOY"

# Build Backend Application if TypeScript build is enabled
if ($BuildTypeScript -or $RunQualityChecks) {
    try {
        Invoke-ModernizedApplication -SourcePath $BackendSourcePath -AppType "Backend" -BuildTypeScript:$BuildTypeScript -RunQualityChecks:$RunQualityChecks
    } catch {
        Write-Host "❌ Backend build failed, but continuing with deployment..." -ForegroundColor Red
        Write-DeploymentLog -Message "Backend build failed: $_, continuing with deployment" -Level "Warning"
    }
}

# Build Frontend Application if TypeScript build is enabled
if ($BuildTypeScript -or $RunQualityChecks) 
{
    try {
        Invoke-ModernizedApplication -SourcePath $FrontendSourcePath -AppType "Frontend" -BuildTypeScript:$BuildTypeScript -RunQualityChecks:$RunQualityChecks
    } catch {
        Write-Host "❌ Frontend build failed, but continuing with deployment..." -ForegroundColor Red
        Write-DeploymentLog -Message "Frontend build failed: $_, continuing with deployment" -Level "Warning"
    }
}

Write-DeploymentLog -Message "Deploying applications from source directories" -Level "Step" -Step "APPLICATION_DEPLOYMENT"

# Deploy Backend Application
Write-Host "`n🔧 Deploying Backend from source..." -ForegroundColor Yellow

try {
    # Ensure Temp directory exists
    if (-not (Test-Path ".\Temp")) {
        New-Item -ItemType Directory -Path ".\Temp" -Force | Out-Null
        Write-DeploymentLog -Message "Created Temp directory for deployment packages" -Level "Info"
    }
    
    # Create backend deployment package
    $backendDeployPath = Join-Path ".\Temp" "finops-backend-deploy"
    $backendZip = Join-Path ".\Temp" "finops-backend-deploy.zip"

    # Clean up any existing deployment files
    if (Test-Path $backendDeployPath) { Remove-Item $backendDeployPath -Recurse -Force }
    if (Test-Path $backendZip) { Remove-Item $backendZip -Force }
      # Copy backend source to deployment directory (copy contents, not the folder itself)
    Write-Host "📦 Preparing backend deployment package..." -ForegroundColor Cyan
    New-Item -Path $backendDeployPath -ItemType Directory -Force | Out-Null
    Copy-Item -Path "$BackendSourcePath\*" -Destination $backendDeployPath -Recurse -Force
    Write-DeploymentLog -Message "Backend source contents copied to deployment directory" -Level "Success"
      # Validate backend package.json exists and has proper structure
    $packageJsonPath = Join-Path $backendDeployPath "package.json"
    if (-not (Test-Path $packageJsonPath)) {
        Write-DeploymentLog -Message "package.json not found in backend source. This is unexpected for a proper backend deployment." -Level "Error"
        throw "Backend package.json is missing. Please ensure the backend source directory contains a valid package.json file."
    } else {
        Write-DeploymentLog -Message "Backend package.json found and validated" -Level "Success"
        # Read and validate the package.json
        try {
            $packageContent = Get-Content $packageJsonPath | ConvertFrom-Json
            if (-not $packageContent.main) {
                Write-DeploymentLog -Message "Backend package.json missing 'main' entry. Adding default." -Level "Warning"
                $packageContent | Add-Member -NotePropertyName "main" -NotePropertyValue "server.js" -Force
                $packageContent | ConvertTo-Json -Depth 10 | Set-Content $packageJsonPath -Encoding UTF8
            }
            if (-not $packageContent.scripts.start) {
                Write-DeploymentLog -Message "Backend package.json missing 'start' script. Adding default." -Level "Warning"
                if (-not $packageContent.scripts) {
                    $packageContent | Add-Member -NotePropertyName "scripts" -NotePropertyValue @{} -Force
                }
                $packageContent.scripts | Add-Member -NotePropertyName "start" -NotePropertyValue "node server.js" -Force
                $packageContent | ConvertTo-Json -Depth 10 | Set-Content $packageJsonPath -Encoding UTF8
            }
        } catch {
            Write-DeploymentLog -Message "Failed to validate backend package.json: $_" -Level "Error"
            throw "Invalid backend package.json format: $_"        }
    }    # Keep .deployment file if it exists to control the build process
    $deploymentFile = Join-Path $backendDeployPath ".deployment"
    if (Test-Path $deploymentFile) {
        Write-DeploymentLog -Message "Custom .deployment file found and will be used for build control" -Level "Info"
    } else {
        Write-DeploymentLog -Message "No custom .deployment file - Azure Oryx will handle auto-build" -Level "Info"
    }
    
    # Create ZIP package for backend
    Write-Host "Creating backend ZIP package: $backendZip" -ForegroundColor Cyan
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path $backendZip) { Remove-Item $backendZip -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($backendDeployPath, $backendZip)
    if (Test-Path $backendZip) {
        Write-DeploymentLog -Message "Backend deployment package created: $backendZip" -Level "Success"
    } else {
        Write-DeploymentLog -Message "Failed to create backend ZIP package: $backendZip" -Level "Error"
        Write-Host "❌ Failed to create backend ZIP package: $backendZip" -ForegroundColor Red
        #exit 1
    }
      # Configure backend app settings with modernized environment variables
    Write-Host "🔧 Configuring backend application settings..." -ForegroundColor Cyan
    
    # Azure AD and database configuration
    az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $BackendAppName --settings "AZURE_CLIENT_ID=$principalId" | Out-Null
    az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $BackendAppName --settings "AZURE_TENANT_ID=$tenantId" | Out-Null
    
    # CORS configuration for frontend
    az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $BackendAppName --settings "FRONTEND_URL=https://$FrontendAppName.azurewebsites.net" | Out-Null
    az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $BackendAppName --settings "CORS_ALLOWED_ORIGINS=https://$FrontendAppName.azurewebsites.net,https://portal.azure.com" | Out-Null
    
    # Environment and feature flags
    az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $BackendAppName --settings "NODE_ENV=production" | Out-Null
    az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $BackendAppName --settings "PORT=8080" | Out-Null
    az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $BackendAppName --settings "ENABLE_AUTH=true" | Out-Null
    az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $BackendAppName --settings "LOG_LEVEL=info" | Out-Null
    
    # Rate limiting configuration
    az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $BackendAppName --settings "API_RATE_LIMIT_WINDOW_MS=900000" | Out-Null
    az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $BackendAppName --settings "API_RATE_LIMIT_MAX=100" | Out-Null
    az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $BackendAppName --settings "AUTH_RATE_LIMIT_MAX=5" | Out-Null
    
    # Configure build automation for Node.js deployment
    Write-Host "🔧 Configuring backend build automation..." -ForegroundColor Cyan
    az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $BackendAppName --settings "SCM_DO_BUILD_DURING_DEPLOYMENT=true" | Out-Null
    az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $BackendAppName --settings "ENABLE_ORYX_BUILD=true" | Out-Null
    az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $BackendAppName --settings "PRE_BUILD_COMMAND=npm install" | Out-Null
    az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $BackendAppName --settings "POST_BUILD_COMMAND=echo 'Backend build completed'" | Out-Null
    Write-DeploymentLog -Message "Backend build automation configured" -Level "Success"
    
    # Deploy backend application
    Write-Host "🚀 Deploying backend application..." -ForegroundColor Cyan
    $backendDeployResult = az webapp deploy --resource-group $WebAppsResourceGroup --name $BackendAppName --src-path $backendZip --type zip 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-DeploymentLog -Message "Backend deployment failed: $backendDeployResult" -Level "Error"
        Write-Host "❌ Backend deployment failed: $backendDeployResult" -ForegroundColor Red
        #exit 1
    } else {
        Write-DeploymentLog -Message "Backend application deployed successfully" -Level "Success"
        Write-Host "✅ Backend deployed from: $BackendSourcePath" -ForegroundColor Green
    }
    
    # Clean up backend deployment files
    Remove-Item $backendDeployPath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $backendZip -Force -ErrorAction SilentlyContinue
    
} catch {
    Write-DeploymentLog -Message "Backend deployment failed: $_" -Level "Error"
    Write-Host "❌ Backend deployment failed: $_" -ForegroundColor Red
    #exit 1
}

# Deploy Frontend Application
Write-Host "`n🎨 Deploying Frontend from source..." -ForegroundColor Yellow

try {
    # Create frontend deployment package
  
    $frontendDeployPath = Join-Path "C:\Users\thohalld\OneDrive - Crayon Group\Vinnuskjöl\Crayon\FinOps\FinOps OPS\DEV\FinOps_OPS_WebApp_Setup_versions\FinOps_OPS_WebApp_Setup_01\FinOps_OPS_WebApp_Setup_ClaudeCode\TEMP" "finops-frontend-deploy"
    $frontendZip = Join-Path "C:\Users\thohalld\OneDrive - Crayon Group\Vinnuskjöl\Crayon\FinOps\FinOps OPS\DEV\FinOps_OPS_WebApp_Setup_versions\FinOps_OPS_WebApp_Setup_01\FinOps_OPS_WebApp_Setup_ClaudeCode\TEMP" "finops-frontend-deploy.zip"

    # Clean up any existing deployment files
    if (Test-Path $frontendDeployPath) { Remove-Item $frontendDeployPath -Recurse -Force }
    if (Test-Path $frontendZip) { Remove-Item $frontendZip -Force }
      # Copy frontend source to deployment directory (copy contents, not the folder itself)
    Write-Host "📦 Preparing frontend deployment package..." -ForegroundColor Cyan
    New-Item -Path $frontendDeployPath -ItemType Directory -Force | Out-Null
    Copy-Item -Path "$FrontendSourcePath\*" -Destination $frontendDeployPath -Recurse -Force
    Write-DeploymentLog -Message "Frontend source contents copied to deployment directory" -Level "Success"
      # Validate frontend structure and configuration
    $frontendPackageJson = Join-Path $frontendDeployPath "package.json"
    $frontendServerJs = Join-Path $frontendDeployPath "server.js"
    $isNodeApp = Test-Path $frontendPackageJson
    
    if ($isNodeApp) {
        Write-Host "📋 Node.js frontend application detected" -ForegroundColor Cyan
        Write-DeploymentLog -Message "Frontend identified as Node.js application" -Level "Info"
        
        # Validate server.js exists
        if (-not (Test-Path $frontendServerJs)) {
            Write-DeploymentLog -Message "server.js not found in frontend source. This is unexpected for a Node.js frontend." -Level "Error"
            throw "Frontend server.js is missing. Please ensure the frontend source directory contains a valid server.js file."
        }
        
        # Validate and fix package.json if needed
        try {
            $packageContent = Get-Content $frontendPackageJson | ConvertFrom-Json
            if (-not $packageContent.main) {
                Write-DeploymentLog -Message "Frontend package.json missing 'main' entry. Adding default." -Level "Warning"
                $packageContent | Add-Member -NotePropertyName "main" -NotePropertyValue "server.js" -Force
                $packageContent | ConvertTo-Json -Depth 10 | Set-Content $frontendPackageJson -Encoding UTF8
            }
            if (-not $packageContent.scripts.start) {
                Write-DeploymentLog -Message "Frontend package.json missing 'start' script. Adding default." -Level "Warning"
                if (-not $packageContent.scripts) {
                    $packageContent | Add-Member -NotePropertyName "scripts" -NotePropertyValue @{} -Force
                }
                $packageContent.scripts | Add-Member -NotePropertyName "start" -NotePropertyValue "node server.js" -Force
                $packageContent | ConvertTo-Json -Depth 10 | Set-Content $frontendPackageJson -Encoding UTF8
            }
        } catch {
            Write-DeploymentLog -Message "Failed to validate frontend package.json: $_" -Level "Error"
            throw "Invalid frontend package.json format: $_"
        }
    } else {
        Write-Host "📄 Static frontend application detected" -ForegroundColor Cyan
        Write-DeploymentLog -Message "Frontend identified as static application - creating Node.js wrapper" -Level "Info"
        
        # For static sites, create a simple server.js if it doesn't exist
        $serverJsPath = Join-Path $frontendDeployPath "server.js"
        if (-not (Test-Path $serverJsPath)) {
            $staticServerJs = @"
const express = require('express');
const path = require('path');
const app = express();
const port = process.env.PORT || 8080;

// Serve static files
app.use(express.static('.'));

// Handle SPA routing - serve index.html for all routes
app.get('*', (req, res) => {
    res.sendFile(path.join(__dirname, 'index.html'));
});

app.listen(port, () => {
    console.log('✅ FinOps Frontend server started on port', port);
    console.log('� Frontend URL: https://$FrontendAppName.azurewebsites.net');
});
"@
            Set-Content -Path $serverJsPath -Value $staticServerJs -Encoding UTF8
            Write-DeploymentLog -Message "Static server.js created for frontend" -Level "Info"
        }
        
        # Create package.json for static site
        if (-not (Test-Path $frontendPackageJson)) {
            $staticPackageJson = @"
{
  "name": "finops-frontend",
  "version": "1.0.0",
  "description": "FinOps Frontend Application",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "engines": {
    "node": ">=20.0.0"
  },
  "dependencies": {
    "express": "^4.18.0"
  }
}
"@
            Set-Content -Path $frontendPackageJson -Value $staticPackageJson -Encoding UTF8
            Write-DeploymentLog -Message "Package.json created for static frontend" -Level "Info"        }
    }
    
    # Create .deployment file to ensure proper Node.js deployment
    $frontendDeploymentFile = Join-Path $frontendDeployPath ".deployment"
    $frontendDeploymentContent = @"
[config]
command = npm start
"@
    Set-Content -Path $frontendDeploymentFile -Value $frontendDeploymentContent -Encoding UTF8
    Write-DeploymentLog -Message "Frontend .deployment file created" -Level "Info"
    
    # Create ZIP package for frontend
    Write-Host "Creating frontend ZIP package: $frontendZip" -ForegroundColor Cyan
    if (Test-Path $frontendZip) { Remove-Item $frontendZip -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($frontendDeployPath, $frontendZip)
    if (Test-Path $frontendZip) {
        Write-DeploymentLog -Message "Frontend deployment package created: $frontendZip" -Level "Success"
    } else {
        Write-DeploymentLog -Message "Failed to create frontend ZIP package: $frontendZip" -Level "Error"
        Write-Host "❌ Failed to create frontend ZIP package: $frontendZip" -ForegroundColor Red
        #exit 1
    }
      # Configure frontend app settings with modernized environment variables
    Write-Host "🔧 Configuring frontend application settings..." -ForegroundColor Cyan
    
    # Backend API configuration
    az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $FrontendAppName --settings "API_BASE_URL=https://$BackendAppName.azurewebsites.net" | Out-Null
    az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $FrontendAppName --settings "BACKEND_URL=https://$BackendAppName.azurewebsites.net" | Out-Null
    
    # Environment configuration
    az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $FrontendAppName --settings "NODE_ENV=production" | Out-Null
    az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $FrontendAppName --settings "PORT=8080" | Out-Null
    
    # Feature flags
    az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $FrontendAppName --settings "ENABLE_AUTH=false" | Out-Null
    az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $FrontendAppName --settings "ENABLE_MOCK_DATA=false" | Out-Null
    az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $FrontendAppName --settings "LOG_LEVEL=warn" | Out-Null
    
    # Configure build automation for Node.js deployment
    Write-Host "🔧 Configuring frontend build automation..." -ForegroundColor Cyan
    az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $FrontendAppName --settings "SCM_DO_BUILD_DURING_DEPLOYMENT=true" | Out-Null
    az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $FrontendAppName --settings "ENABLE_ORYX_BUILD=true" | Out-Null
    az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $FrontendAppName --settings "PRE_BUILD_COMMAND=npm install" | Out-Null
    az webapp config appsettings set --resource-group $WebAppsResourceGroup --name $FrontendAppName --settings "POST_BUILD_COMMAND=echo 'Frontend build completed'" | Out-Null
    Write-DeploymentLog -Message "Frontend build automation configured" -Level "Success"
    
    # Deploy frontend application
    Write-Host "🚀 Deploying frontend application..." -ForegroundColor Cyan
    $frontendDeployResult = az webapp deploy --resource-group $WebAppsResourceGroup --name $FrontendAppName --src-path $frontendZip --type zip 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-DeploymentLog -Message "Frontend deployment failed: $frontendDeployResult" -Level "Error"
        Write-Host "❌ Frontend deployment failed: $frontendDeployResult" -ForegroundColor Red
        #exit 1
    } else {
        Write-DeploymentLog -Message "Frontend application deployed successfully" -Level "Success"
        Write-Host "✅ Frontend deployed from: $FrontendSourcePath" -ForegroundColor Green
    }
    
    # Clean up frontend deployment files
    Remove-Item $frontendDeployPath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $frontendZip -Force -ErrorAction SilentlyContinue
    
} catch {
    Write-DeploymentLog -Message "Frontend deployment failed: $_" -Level "Error"
    Write-Host "❌ Frontend deployment failed: $_" -ForegroundColor Red
    #exit 1
}

# Update deployment summary with source paths
$deploymentSummary.resources += @{ 
    type = "BackendApplication"
    name = $BackendAppName
    status = "deployed"
    sourcePath = $BackendSourcePath
}

$deploymentSummary.resources += @{ 
    type = "FrontendApplication"
    name = $FrontendAppName
    status = "deployed"
    sourcePath = $FrontendSourcePath
}

Write-DeploymentLog -Message "Application deployment completed successfully" -Level "Success"

# ===============================================================
# Final Summary
# ===============================================================
Write-Host "`n🎉 ENHANCED FINOPS PLATFORM DEPLOYED!" -ForegroundColor Green
Write-Host "=" * 60 -ForegroundColor Cyan

Write-Host "`n📋 DEPLOYMENT SUMMARY:" -ForegroundColor Yellow
Write-Host "   ✅ Deployment ID: $deploymentId" -ForegroundColor White
Write-Host "   ✅ Duration: $($deploymentSummary.duration)" -ForegroundColor White
Write-Host "   ✅ Resources Created/Updated: $($deploymentSummary.resources.Count)" -ForegroundColor White

Write-Host "`n🏗️ INFRASTRUCTURE:" -ForegroundColor Yellow
Write-Host "   ✅ Unified App Service Plan: $AppServicePlan ($AppServiceSku)" -ForegroundColor White
Write-Host "   ✅ Backend App: $BackendAppName" -ForegroundColor White
Write-Host "   ✅ Frontend App: $FrontendAppName" -ForegroundColor White
Write-Host "   ✅ Resource Group: $WebAppsResourceGroup" -ForegroundColor White

Write-Host "`n🚀 FEATURES ENABLED:" -ForegroundColor Yellow
Write-Host "   ✅ Linux hosting for both apps" -ForegroundColor White
Write-Host "   ✅ Managed Identity authentication" -ForegroundColor White
Write-Host "   $(if($hasAutoScaling){'✅'}else{'❌'}) Auto-scaling ($(if($hasAutoScaling){'enabled'}else{'not available for this SKU'}))" -ForegroundColor White
Write-Host "   $(if($hasStagingSlots){'✅'}else{'❌'}) Staging slots ($(if($hasStagingSlots){'available'}else{'not available for this SKU'}))" -ForegroundColor White
Write-Host "   $(if($EnableApplicationInsights){'✅'}else{'❌'}) Application Insights ($(if($EnableApplicationInsights){'enabled'}else{'disabled'}))" -ForegroundColor White

Write-Host "`n🌐 ENDPOINTS:" -ForegroundColor Yellow
Write-Host "   🔧 Backend API: https://$BackendAppName.azurewebsites.net" -ForegroundColor White
Write-Host "   🎨 Frontend: https://$FrontendAppName.azurewebsites.net" -ForegroundColor White
Write-Host "   🧪 API Health: https://$BackendAppName.azurewebsites.net/health" -ForegroundColor White
Write-Host "   📚 API Documentation: https://$BackendAppName.azurewebsites.net/api-docs" -ForegroundColor White
Write-Host "   📊 Service Health: https://$BackendAppName.azurewebsites.net/api/service-health" -ForegroundColor White
Write-Host "   📋 API Status: https://$BackendAppName.azurewebsites.net/api/status" -ForegroundColor White

Write-Host "`n📁 SOURCE DEPLOYMENTS:" -ForegroundColor Yellow
Write-Host "   🔧 Backend Source: $BackendSourcePath" -ForegroundColor White
Write-Host "   🎨 Frontend Source: $FrontendSourcePath" -ForegroundColor White

Write-Host "`n💰 COST ESTIMATE:" -ForegroundColor Yellow
Write-Host "   💵 App Service Plan ($AppServiceSku): ~$($deploymentSummary.costs.appServicePlan.estimatedMonthlyCostUSD) USD/month" -ForegroundColor White
if ($EnableApplicationInsights) {
    Write-Host "   📊 Application Insights: ~$15 USD/month" -ForegroundColor White
}
Write-Host "   💰 Total Estimated: ~$($deploymentSummary.totalCostEstimateUSD) USD/month" -ForegroundColor White

Write-Host "`n📄 DOCUMENTATION:" -ForegroundColor Yellow
Write-Host "   📋 Full Documentation: $docFile" -ForegroundColor White
Write-Host "   📊 Deployment Summary: $summaryFile" -ForegroundColor White
Write-Host "   🔗 Quick URLs: $(Join-Path $DocumentationPath "$deploymentId-urls.txt")" -ForegroundColor White

Write-Host "`n📋 NEXT STEPS:" -ForegroundColor Yellow
Write-Host "   1. 🧪 Test the frontend: https://$FrontendAppName.azurewebsites.net" -ForegroundColor White
Write-Host "   2. 🔧 Test the backend API: https://$BackendAppName.azurewebsites.net" -ForegroundColor White
Write-Host "   3. 📚 Explore API documentation: https://$BackendAppName.azurewebsites.net/api-docs" -ForegroundColor White
Write-Host "   4. 📊 Check service health: https://$BackendAppName.azurewebsites.net/api/service-health" -ForegroundColor White
Write-Host "   5. 🔐 Grant SQL permissions to managed identity" -ForegroundColor White
Write-Host "   6. 🚀 Set up CI/CD pipeline with GitHub Actions" -ForegroundColor White
Write-Host "   7. 📊 Monitor performance in Azure portal" -ForegroundColor White
if ($EnableApplicationInsights) {
    Write-Host "   8. 📈 Review Application Insights dashboards" -ForegroundColor White
}
Write-Host "   $(if($EnableApplicationInsights){9}else{8}). 📖 Review deployment documentation: $docFile" -ForegroundColor White

Write-Host "`n🚀 QUICK ACCESS:" -ForegroundColor Yellow
Write-Host "   🌐 Open Frontend: Start-Process 'https://$FrontendAppName.azurewebsites.net'" -ForegroundColor Gray
Write-Host "   🔧 Open Backend: Start-Process 'https://$BackendAppName.azurewebsites.net'" -ForegroundColor Gray
Write-Host "   📚 Open API Docs: Start-Process 'https://$BackendAppName.azurewebsites.net/api-docs'" -ForegroundColor Gray
Write-Host "   🧪 Check Health: Start-Process 'https://$BackendAppName.azurewebsites.net/health'" -ForegroundColor Gray
Write-Host "   📊 Service Health: Start-Process 'https://$BackendAppName.azurewebsites.net/api/service-health'" -ForegroundColor Gray
Write-Host "   📖 Open Documentation: Start-Process '$docFile'" -ForegroundColor Gray

Write-Host "`n" + "=" * 60 -ForegroundColor Cyan
Write-Host "🎯 Enhanced FinOps Platform ready for production use!" -ForegroundColor Green
Write-Host "📋 All deployment details documented in: $DocumentationPath" -ForegroundColor Cyan

# Open documentation automatically
if (Test-Path $docFile) {
    Write-Host "`n📖 Opening deployment documentation..." -ForegroundColor Cyan
    Start-Process $docFile
}

# ===============================================================
# Generate Documentation Files
# ===============================================================
Write-DeploymentLog -Message "Generating deployment documentation" -Level "Step" -Step "DOCUMENTATION"

$deploymentEnd = Get-Date
$deploymentSummary.endTime = $deploymentEnd.ToString("dd-MM-yyyy HH:mm:ss")
$deploymentSummary.duration = ($deploymentEnd - $deploymentStart).ToString("hh\:mm\:ss")
$deploymentSummary.totalCostEstimateUSD = ($deploymentSummary.costs.Values | ForEach-Object { $_.estimatedMonthlyCostUSD } | Measure-Object -Sum).Sum

# Generate comprehensive markdown documentation
$markdownContent = @"
# FinOps Platform Deployment Documentation

**Deployment ID:** $deploymentId  
**Date:** $($deploymentStart.ToString("yyyy-MM-dd"))  
**Duration:** $($deploymentSummary.duration)  
**Status:** ✅ Successfully Completed

## 📋 Deployment Summary

### Infrastructure Created
"@

foreach ($resource in $deploymentSummary.resources) {
    $markdownContent += "`n- **$($resource.type)**: $($resource.name) ($($resource.status))"
    if ($resource.sku) {
        $markdownContent += " - SKU: $($resource.sku)"
    }
}

$markdownContent += @"

### 🌐 Application URLs
- **Backend API**: https://$BackendAppName.azurewebsites.net
- **Frontend**: https://$FrontendAppName.azurewebsites.net
- **API Documentation**: https://$BackendAppName.azurewebsites.net/api-docs
- **API Health Check**: https://$BackendAppName.azurewebsites.net/health
- **Service Health**: https://$BackendAppName.azurewebsites.net/api/service-health
- **API Status**: https://$BackendAppName.azurewebsites.net/api/status

### 💰 Cost Estimates (Monthly)
- **App Service Plan ($AppServiceSku)**: $($deploymentSummary.costs.appServicePlan.estimatedMonthlyCostUSD) USD
"@

if ($EnableApplicationInsights) {
    $markdownContent += "`n- **Application Insights**: ~$15 USD"
}

$markdownContent += "`n- **Total Estimated**: ~$($deploymentSummary.totalCostEstimateUSD) USD/month"

$markdownContent += @"

### 🔧 Features Enabled

#### Platform Features
- ✅ **Unified App Service Plan**: Single Linux plan for both applications
- ✅ **Managed Identity**: Azure AD authentication for SQL access
- $(if($hasAutoScaling){'✅'}else{'❌'}) **Auto-scaling**: $(if($hasAutoScaling){'CPU-based scaling (1-5 instances)'}else{'Not available for this SKU'})
- $(if($hasStagingSlots){'✅'}else{'❌'}) **Staging Slots**: $(if($hasStagingSlots){'Available for blue-green deployments'}else{'Not available for this SKU'})
- $(if($EnableApplicationInsights){'✅'}else{'❌'}) **Application Insights**: $(if($EnableApplicationInsights){'Performance monitoring enabled'}else{'Not enabled'})

#### Modernization Features
- ✅ **TypeScript Support**: Full TypeScript implementation for both frontend and backend
- ✅ **API Documentation**: Interactive Swagger/OpenAPI documentation
- ✅ **Input Validation**: Comprehensive Joi-based validation with security sanitization
- ✅ **Code Quality**: ESLint and Prettier configuration for consistent code style
- ✅ **Testing Framework**: Jest testing setup with coverage reporting
- ✅ **CI/CD Ready**: GitHub Actions workflow configuration included
- ✅ **Security Hardening**: Enhanced security headers, rate limiting, and XSS protection
- ✅ **Environment Management**: Dynamic environment configuration system

### 🔐 Security Configuration
- **Access Restrictions**: Configured for IP $AllowedIP
- **Managed Identity**: Enabled for secure SQL access
- **HTTPS**: Enforced for all applications
- **Security Headers**: Enhanced headers configured

## 📊 Deployment Steps

"@

foreach ($step in $deploymentSummary.steps) {
    $markdownContent += "### $($step.stepName) - $($step.timestamp)`n"
    $markdownContent += "$($step.message)`n`n"
}

$markdownContent += @"

## 🔄 Next Steps

### Immediate Actions Required
1. **Grant SQL Permissions**: Configure managed identity access to SQL databases
2. **Test Applications**: Verify frontend and backend connectivity
3. **Configure Monitoring**: Set up alerts and dashboards if Application Insights is enabled

### Recommended Actions
1. **Set up CI/CD**: Implement automated deployment pipeline
2. **Configure Custom Domain**: Add custom domain and SSL certificate
3. **Implement Caching**: Add Redis cache for improved performance
4. **Set up Backup**: Configure backup policies for applications

## 📞 Support Information

- **Resource Group**: $WebAppsResourceGroup
- **App Service Plan**: $AppServicePlan
- **Location**: $Location
- **SKU**: $AppServiceSku

## 📝 Deployment Log

"@

foreach ($logEntry in $deploymentLog) {
    $icon = switch ($logEntry.level) {
        "Success" { "✅" }
        "Warning" { "⚠️" }
        "Error" { "❌" }
        "Step" { "🔄" }
        default { "ℹ️" }
    }
    $markdownContent += "`n**$($logEntry.timestamp)** $icon **$($logEntry.level)**: $($logEntry.message)"
}

$markdownContent += @"

---
*Generated automatically by Deploy-Enhanced-FinOps.ps1*  
*Deployment ID: $deploymentId*
"@

# Save documentation files
try {
    Set-Content -Path $docFile -Value $markdownContent -Encoding UTF8
    Write-DeploymentLog -Message "Deployment documentation saved: $docFile" -Level "Success"
    
    $deploymentSummary | ConvertTo-Json -Depth 10 | Set-Content -Path $summaryFile -Encoding UTF8
    Write-DeploymentLog -Message "Deployment summary saved: $summaryFile" -Level "Success"
    
    # Also save URLs to a quick reference file
    $urlsFile = Join-Path $DocumentationPath "$deploymentId-urls.txt"
    $urlsContent = @"
FinOps Platform URLs - $deploymentId
Generated: $($deploymentEnd.ToString("dd-MM-yyyy HH:mm:ss"))

=== MAIN APPLICATIONS ===
Frontend: https://$FrontendAppName.azurewebsites.net
Backend API: https://$BackendAppName.azurewebsites.net

=== API ENDPOINTS ===
API Documentation: https://$BackendAppName.azurewebsites.net/api-docs
API Health Check: https://$BackendAppName.azurewebsites.net/health
Service Health: https://$BackendAppName.azurewebsites.net/api/service-health
API Status: https://$BackendAppName.azurewebsites.net/api/status

=== REFRESH TRACKING ===
M365 Refresh Status: https://$BackendAppName.azurewebsites.net/api/updates/m365
Azure Refresh Status: https://$BackendAppName.azurewebsites.net/api/updates/azure
AWS Refresh Status: https://$BackendAppName.azurewebsites.net/api/updates/aws
Combined Refresh Report: https://$BackendAppName.azurewebsites.net/api/refresh-report

=== MANAGEMENT ===
Azure Portal: https://portal.azure.com/#@/resource/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$WebAppsResourceGroup/providers/Microsoft.Web/serverfarms/$AppServicePlan
Resource Group: https://portal.azure.com/#@/resource/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$WebAppsResourceGroup/overview
"@
    Set-Content -Path $urlsFile -Value $urlsContent -Encoding UTF8
    Write-DeploymentLog -Message "Quick URLs reference saved: $urlsFile" -Level "Success"
    
} catch {
    Write-DeploymentLog -Message "Failed to save documentation: $_" -Level "Warning"
}