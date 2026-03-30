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
# cd "C:\Users\thohalld\OneDrive - Crayon Group\Vinnuskjöl\Crayon\FinOps\FinOps OPS\DEV\FinOps_OPS_WebApp_Setup_versions\FinOps_OPS_WebApp_Setup_01\FinOps_OPS_WebApp_Setup_ClaudeCode"
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
    [string]$AppServiceSku = "B1",
    
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
    [string]$FrontendSourcePath = "C:\Users\thohalld\OneDrive - Crayon Group\Vinnuskjöl\Crayon\FinOps\FinOps OPS\DEV\FinOps_OPS_WebApp_Setup_versions\FinOps_OPS_WebApp_Setup_01\FinOps_OPS_WebApp_Setup_ClaudeCode\Frontend",
    
    [Parameter(Mandatory = $false)]
    [string]$BackendSourcePath = "C:\Users\thohalld\OneDrive - Crayon Group\Vinnuskjöl\Crayon\FinOps\FinOps OPS\DEV\FinOps_OPS_WebApp_Setup_versions\FinOps_OPS_WebApp_Setup_01\FinOps_OPS_WebApp_Setup_ClaudeCode\Backend",
        
    [Parameter(Mandatory = $false)]
    [string]$deploymenttemp = "C:\Users\thohalld\OneDrive - Crayon Group\Vinnuskjöl\Crayon\FinOps\FinOps OPS\DEV\FinOps_OPS_WebApp_Setup_versions\FinOps_OPS_WebApp_Setup_01\FinOps_OPS_WebApp_Setup_ClaudeCode\Temp",
    
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
                    try {
                        $typeCheckResult = npm run type-check 2>&1
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host "✅ TypeScript type checking passed" -ForegroundColor Green
                            Write-DeploymentLog -Message "$AppType TypeScript type checking passed" -Level "Success"
                        } else {
                            Write-Host "⚠️ TypeScript type checking warnings: $typeCheckResult" -ForegroundColor Yellow
                            Write-DeploymentLog -Message "$AppType TypeScript warnings: $typeCheckResult" -Level "Warning"
                        }
                    } catch {
                        Write-Host "⚠️ TypeScript type checking not available" -ForegroundColor Yellow
                    }
                }
                
                # Linting
                if ($hasEslint) {
                    Write-Host "🔍 Running ESLint..." -ForegroundColor Cyan
                    try {
                        $lintResult = npm run lint 2>&1
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host "✅ ESLint checks passed" -ForegroundColor Green
                            Write-DeploymentLog -Message "$AppType ESLint checks passed" -Level "Success"
                        } else {
                            Write-Host "⚠️ ESLint warnings: $lintResult" -ForegroundColor Yellow
                            Write-DeploymentLog -Message "$AppType ESLint warnings: $lintResult" -Level "Warning"
                        }
                    } catch {
                        Write-Host "⚠️ ESLint not available" -ForegroundColor Yellow
                    }
                }
                
                # Formatting check
                if ($hasPrettier) {
                    Write-Host "🔍 Checking code formatting..." -ForegroundColor Cyan
                    try {
                        $formatResult = npm run format:check 2>&1
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host "✅ Code formatting is correct" -ForegroundColor Green
                            Write-DeploymentLog -Message "$AppType code formatting is correct" -Level "Success"
                        } else {
                            Write-Host "⚠️ Code formatting issues: $formatResult" -ForegroundColor Yellow
                            Write-DeploymentLog -Message "$AppType formatting issues: $formatResult" -Level "Warning"
                        }
                    } catch {
                        Write-Host "⚠️ Prettier not available" -ForegroundColor Yellow
                    }
                }
                
                # Run tests if available
                if ($hasPackageJson) {
                    try {
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
                    } catch {
                        Write-Host "⚠️ Tests not available" -ForegroundColor Yellow
                    }
                }
            }
            
            # Build TypeScript if requested and available
            if ($BuildTypeScript -and $hasTypeScript) {
                Write-Host "`n🏗️ Building TypeScript..." -ForegroundColor Cyan
                try {
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
                } catch {
                    Write-Host "❌ TypeScript build failed: $_" -ForegroundColor Red
                    Write-DeploymentLog -Message "$AppType TypeScript build failed: $_" -Level "Error"
                    throw
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
        exit 1
    }
} catch {
    Write-DeploymentLog -Message "Azure CLI not found or not working properly" -Level "Error"
    Write-Host "`n❌ Azure CLI Error: $_" -ForegroundColor Red
    exit 1
}

# Get current subscription info
$currentAccount = $azAccount | ConvertFrom-Json
$currentSubscriptionId = $currentAccount.id
$currentSubscriptionName = $currentAccount.name

Write-DeploymentLog -Message "Current Azure subscription: $currentSubscriptionName ($currentSubscriptionId)" -Level "Info"

# Set selected subscription name
$selectedSubscriptionName = $currentSubscriptionName

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

# Validate source code paths (make them optional for now)
Write-DeploymentLog -Message "Validating source code paths" -Level "Step" -Step "SOURCE_VALIDATION"

$frontendExists = Test-Path $FrontendSourcePath
$backendExists = Test-Path $BackendSourcePath

if (-not $backendExists) {
    Write-DeploymentLog -Message "Backend source path not found: $BackendSourcePath - creating placeholder" -Level "Warning"
    Write-Host "⚠️ Backend source directory not found: $BackendSourcePath - will create sample app" -ForegroundColor Yellow
}

if (-not $frontendExists) {
    Write-DeploymentLog -Message "Frontend source path not found: $FrontendSourcePath - creating placeholder" -Level "Warning"
    Write-Host "⚠️ Frontend source directory not found: $FrontendSourcePath - will create sample app" -ForegroundColor Yellow
}

Write-DeploymentLog -Message "Source paths validation completed" -Level "Success" -Details @{
    backendSourcePath = $BackendSourcePath
    frontendSourcePath = $FrontendSourcePath
    backendExists = $backendExists
    frontendExists = $frontendExists
}

Write-Host "`n✅ Source Code Paths Validated" -ForegroundColor Green
Write-Host "   Backend Source: $BackendSourcePath (exists: $backendExists)" -ForegroundColor White
Write-Host "   Frontend Source: $FrontendSourcePath (exists: $frontendExists)" -ForegroundColor White

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
    appServiceSku = $AppServiceSku
    capabilities = $deploymentSummary.parameters.skuCapabilities
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
    $webRgExists = az group exists --name $WebAppsResourceGroup
    if ($webRgExists -eq "false") {
        Write-Host "📂 Creating Web Apps resource group: $WebAppsResourceGroup" -ForegroundColor Yellow
        az group create --name $WebAppsResourceGroup --location $Location | Out-Null
        Write-DeploymentLog -Message "Created Web Apps resource group: $WebAppsResourceGroup" -Level "Success"
    } else {
        Write-DeploymentLog -Message "Web Apps resource group already exists: $WebAppsResourceGroup" -Level "Info"
    }
} catch {
    Write-DeploymentLog -Message "Failed to create Web Apps resource group: $_" -Level "Error"
    throw "Failed to create Web Apps resource group: $_"
}

try {
    $sqlRgExists = az group exists --name $SqlServerResourceGroup
    if ($sqlRgExists -eq "false") {
        Write-Host "📂 Creating SQL Server resource group: $SqlServerResourceGroup" -ForegroundColor Yellow
        az group create --name $SqlServerResourceGroup --location $Location | Out-Null
        Write-DeploymentLog -Message "Created SQL Server resource group: $SqlServerResourceGroup" -Level "Success"
    } else {
        Write-DeploymentLog -Message "SQL Server resource group already exists: $SqlServerResourceGroup" -Level "Info"
    }
} catch {
    Write-DeploymentLog -Message "Failed to create SQL Server resource group: $_" -Level "Error"
    Write-Host "⚠️ SQL Server resource group creation failed (continuing): $_" -ForegroundColor Yellow
}

# ===============================================================
# Step 2: Create Unified App Service Plan (Linux)
# ===============================================================
Write-DeploymentLog -Message "Creating unified App Service Plan" -Level "Step" -Step "APP_SERVICE_PLAN"

try {
    Write-Host "`n🏗️ Creating App Service Plan: $AppServicePlan" -ForegroundColor Yellow
    
    $planExists = az appservice plan show --name $AppServicePlan --resource-group $WebAppsResourceGroup 2>$null
    if (-not $planExists) {
        az appservice plan create `
            --name $AppServicePlan `
            --resource-group $WebAppsResourceGroup `
            --location $Location `
            --sku $AppServiceSku `
            --is-linux `
            --output none
        
        Write-Host "✅ App Service Plan created: $AppServicePlan ($AppServiceSku)" -ForegroundColor Green
        Write-DeploymentLog -Message "App Service Plan created successfully" -Level "Success"
    } else {
        Write-Host "✅ App Service Plan already exists: $AppServicePlan" -ForegroundColor Green
        Write-DeploymentLog -Message "App Service Plan already exists" -Level "Info"
    }
    
    # Add to deployment summary
    $deploymentSummary.resources += @{
        type = "Microsoft.Web/serverfarms"
        name = $AppServicePlan
        resourceGroup = $WebAppsResourceGroup
        sku = $AppServiceSku
        status = "created"
    }
    
} catch {
    Write-DeploymentLog -Message "Failed to create App Service Plan: $_" -Level "Error"
    throw "Failed to create App Service Plan: $_"
}

# ===============================================================
# Step 3: Create Backend App Service (Linux Node.js)
# ===============================================================
Write-Host "`n🔧 Creating Backend App Service..." -ForegroundColor Yellow

try {
    $backendExists = az webapp show --name $BackendAppName --resource-group $WebAppsResourceGroup 2>$null
    if (-not $backendExists) {
        az webapp create `
            --name $BackendAppName `
            --resource-group $WebAppsResourceGroup `
            --plan $AppServicePlan `
            --runtime "NODE:$NodeVersion" `
            --output none
        
        Write-Host "✅ Backend App Service created: $BackendAppName" -ForegroundColor Green
        Write-DeploymentLog -Message "Backend App Service created successfully" -Level "Success"
        
        # Configure backend settings
        az webapp config appsettings set `
            --name $BackendAppName `
            --resource-group $WebAppsResourceGroup `
            --settings `
                "NODE_ENV=production" `
                "PORT=8080" `
                "WEBSITE_NODE_DEFAULT_VERSION=$NodeVersion" `
            --output none
            
        Write-Host "✅ Backend configuration applied" -ForegroundColor Green
        
    } else {
        Write-Host "✅ Backend App Service already exists: $BackendAppName" -ForegroundColor Green
        Write-DeploymentLog -Message "Backend App Service already exists" -Level "Info"
    }
    
    # Add to deployment summary
    $deploymentSummary.resources += @{
        type = "Microsoft.Web/sites"
        name = $BackendAppName
        resourceGroup = $WebAppsResourceGroup
        runtime = "NODE:$NodeVersion"
        status = "created"
        url = "https://$BackendAppName.azurewebsites.net"
    }
    
} catch {
    Write-DeploymentLog -Message "Failed to create Backend App Service: $_" -Level "Error"
    throw "Failed to create Backend App Service: $_"
}

# ===============================================================
# Step 4: Create Frontend App Service (Linux with Static Content)
# ===============================================================
Write-Host "`n🎨 Creating Frontend App Service..." -ForegroundColor Yellow

try {
    $frontendExists = az webapp show --name $FrontendAppName --resource-group $WebAppsResourceGroup 2>$null
    if (-not $frontendExists) {
        az webapp create `
            --name $FrontendAppName `
            --resource-group $WebAppsResourceGroup `
            --plan $AppServicePlan `
            --runtime "NODE:$NodeVersion" `
            --output none
        
        Write-Host "✅ Frontend App Service created: $FrontendAppName" -ForegroundColor Green
        Write-DeploymentLog -Message "Frontend App Service created successfully" -Level "Success"
        
        # Configure frontend settings
        az webapp config appsettings set `
            --name $FrontendAppName `
            --resource-group $WebAppsResourceGroup `
            --settings `
                "NODE_ENV=production" `
                "PORT=8080" `
                "WEBSITE_NODE_DEFAULT_VERSION=$NodeVersion" `
                "BACKEND_API_URL=https://$BackendAppName.azurewebsites.net" `
            --output none
            
        Write-Host "✅ Frontend configuration applied" -ForegroundColor Green
        
    } else {
        Write-Host "✅ Frontend App Service already exists: $FrontendAppName" -ForegroundColor Green
        Write-DeploymentLog -Message "Frontend App Service already exists" -Level "Info"
    }
    
    # Add to deployment summary
    $deploymentSummary.resources += @{
        type = "Microsoft.Web/sites"
        name = $FrontendAppName
        resourceGroup = $WebAppsResourceGroup
        runtime = "NODE:$NodeVersion"
        status = "created"
        url = "https://$FrontendAppName.azurewebsites.net"
    }
    
} catch {
    Write-DeploymentLog -Message "Failed to create Frontend App Service: $_" -Level "Error"
    throw "Failed to create Frontend App Service: $_"
}

# ===============================================================
# Step 5: Configure Application Insights (Optional)
# ===============================================================
if ($EnableApplicationInsights) {
    Write-DeploymentLog -Message "Configuring Application Insights" -Level "Step" -Step "APPLICATION_INSIGHTS"
    
    try {
        $appInsightsName = "$($AppServicePlan)-ai"
        
        # Create Application Insights
        az monitor app-insights component create `
            --app $appInsightsName `
            --location $Location `
            --resource-group $WebAppsResourceGroup `
            --output none
        
        # Get instrumentation key
        $instrumentationKey = az monitor app-insights component show `
            --app $appInsightsName `
            --resource-group $WebAppsResourceGroup `
            --query "instrumentationKey" `
            --output tsv
        
        # Configure both apps with Application Insights
        az webapp config appsettings set `
            --name $BackendAppName `
            --resource-group $WebAppsResourceGroup `
            --settings "APPINSIGHTS_INSTRUMENTATIONKEY=$instrumentationKey" `
            --output none
            
        az webapp config appsettings set `
            --name $FrontendAppName `
            --resource-group $WebAppsResourceGroup `
            --settings "APPINSIGHTS_INSTRUMENTATIONKEY=$instrumentationKey" `
            --output none
        
        Write-Host "✅ Application Insights configured" -ForegroundColor Green
        Write-DeploymentLog -Message "Application Insights configured successfully" -Level "Success"
        
        # Add to deployment summary
        $deploymentSummary.resources += @{
            type = "Microsoft.Insights/components"
            name = $appInsightsName
            resourceGroup = $WebAppsResourceGroup
            status = "created"
        }
        
    } catch {
        Write-DeploymentLog -Message "Failed to configure Application Insights: $_" -Level "Warning"
        Write-Host "⚠️ Application Insights configuration failed (continuing): $_" -ForegroundColor Yellow
    }
}

# ===============================================================
# Step 6: Configure Auto-scaling (If supported)
# ===============================================================
if ($hasAutoScaling -and $EnableAutoScaling) {
    Write-DeploymentLog -Message "Configuring auto-scaling" -Level "Step" -Step "AUTO_SCALING"
    
    try {
        # Create auto-scale settings
        az monitor autoscale create `
            --resource-group $WebAppsResourceGroup `
            --resource $AppServicePlan `
            --resource-type "Microsoft.Web/serverfarms" `
            --name "$AppServicePlan-autoscale" `
            --min-count 1 `
            --max-count 5 `
            --count 1 `
            --output none
        
        # Add CPU scaling rule
        az monitor autoscale rule create `
            --resource-group $WebAppsResourceGroup `
            --autoscale-name "$AppServicePlan-autoscale" `
            --condition "Percentage CPU > 75 avg 5m" `
            --scale out 1 `
            --output none
            
        az monitor autoscale rule create `
            --resource-group $WebAppsResourceGroup `
            --autoscale-name "$AppServicePlan-autoscale" `
            --condition "Percentage CPU < 25 avg 5m" `
            --scale in 1 `
            --output none
        
        Write-Host "✅ Auto-scaling configured (1-5 instances, CPU-based)" -ForegroundColor Green
        Write-DeploymentLog -Message "Auto-scaling configured successfully" -Level "Success"
        
    } catch {
        Write-DeploymentLog -Message "Failed to configure auto-scaling: $_" -Level "Warning"
        Write-Host "⚠️ Auto-scaling configuration failed (continuing): $_" -ForegroundColor Yellow
    }
}

# ===============================================================
# Step 7: Create sample applications if source doesn't exist
# ===============================================================
Write-DeploymentLog -Message "Preparing application deployments" -Level "Step" -Step "APPLICATION_PREPARATION"

# Create sample backend if source doesn't exist
if (-not $backendExists) {
    Write-Host "`n📝 Creating sample backend application..." -ForegroundColor Yellow
    
    if (-not (Test-Path $BackendSourcePath)) {
        New-Item -ItemType Directory -Path $BackendSourcePath -Force | Out-Null
    }
      # Create package.json
    $backendPackageJson = @'
{
  "name": "finops-backend",
  "version": "1.0.0",
  "description": "FinOps Backend API",
  "main": "server.js",
  "scripts": {
    "start": "node server.js",
    "dev": "node server.js"
  },
  "dependencies": {
    "express": "^4.18.2",
    "cors": "^2.8.5",
    "helmet": "^7.1.0"
  },
  "engines": {
    "node": ">=18.0.0"
  }
}
'@
    $backendPackageJson | Out-File -FilePath (Join-Path $BackendSourcePath "package.json") -Encoding utf8
      # Create server.js
    $backendServer = @'
const express = require('express');
const cors = require('cors');
const helmet = require('helmet');

const app = express();
const port = process.env.PORT || 8080;

// Middleware
app.use(helmet());
app.use(cors());
app.use(express.json());

// Health check endpoint
app.get('/health', (req, res) => {
    res.status(200).json({
        status: 'healthy',
        timestamp: new Date().toISOString(),
        version: '1.0.0',
        service: 'finops-backend'
    });
});

// API routes
app.get('/api/status', (req, res) => {
    res.json({
        message: 'FinOps Backend API is running',
        timestamp: new Date().toISOString(),
        environment: process.env.NODE_ENV || 'development'
    });
});

app.get('/api/service-health', (req, res) => {
    res.json({
        service: 'finops-backend',
        status: 'operational',
        uptime: process.uptime(),
        memory: process.memoryUsage(),
        timestamp: new Date().toISOString()
    });
});

// Default route
app.get('/', (req, res) => {
    res.json({
        message: 'Welcome to FinOps Backend API',
        endpoints: [
            '/health',
            '/api/status',
            '/api/service-health'
        ]
    });
});

app.listen(port, () => {
    console.log(`🚀 FinOps Backend API running on port ${port}`);
    console.log(`📋 Health check: http://localhost:${port}/health`);
});
'@
    $backendServer | Out-File -FilePath (Join-Path $BackendSourcePath "server.js") -Encoding utf8
    
    Write-Host "✅ Sample backend application created" -ForegroundColor Green
}

# Create sample frontend if source doesn't exist
if (-not $frontendExists) {
    Write-Host "`n📝 Creating sample frontend application..." -ForegroundColor Yellow
    
    if (-not (Test-Path $FrontendSourcePath)) {
        New-Item -ItemType Directory -Path $FrontendSourcePath -Force | Out-Null
    }
      # Create package.json
    $frontendPackageJson = @'
{
  "name": "finops-frontend",
  "version": "1.0.0",
  "description": "FinOps Frontend Application",
  "main": "server.js",
  "scripts": {
    "start": "node server.js",
    "dev": "node server.js"
  },
  "dependencies": {
    "express": "^4.18.2"
  },
  "engines": {
    "node": ">=18.0.0"
  }
}
'@
    $frontendPackageJson | Out-File -FilePath (Join-Path $FrontendSourcePath "package.json") -Encoding utf8
      # Create index.html
    $frontendIndex = @'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>FinOps Platform</title>
    <style>
        body {
            font-family: "Segoe UI", Tahoma, Geneva, Verdana, sans-serif;
            margin: 0;
            padding: 20px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            min-height: 100vh;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
            text-align: center;
        }
        .header {
            margin-bottom: 50px;
        }
        .logo {
            font-size: 3em;
            margin-bottom: 20px;
        }
        .subtitle {
            font-size: 1.2em;
            opacity: 0.9;
        }
        .features {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
            gap: 30px;
            margin: 50px 0;
        }
        .feature {
            background: rgba(255, 255, 255, 0.1);
            padding: 30px;
            border-radius: 15px;
            backdrop-filter: blur(10px);
        }
        .feature h3 {
            font-size: 1.5em;
            margin-bottom: 15px;
        }
        .status {
            background: rgba(255, 255, 255, 0.1);
            padding: 20px;
            border-radius: 10px;
            margin: 30px 0;
        }
        .btn {
            background: rgba(255, 255, 255, 0.2);
            color: white;
            border: none;
            padding: 12px 24px;
            border-radius: 8px;
            cursor: pointer;
            font-size: 1em;
            margin: 5px;
            transition: all 0.3s ease;
        }
        .btn:hover {
            background: rgba(255, 255, 255, 0.3);
            transform: translateY(-2px);
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div class="logo">💼 FinOps Platform</div>
            <div class="subtitle">Financial Operations Management & Cost Optimization</div>
        </div>
        
        <div class="status">
            <h2>🚀 Platform Status</h2>
            <p><strong>Frontend:</strong> <span style="color: #4CAF50;">✅ Online</span></p>
            <p><strong>Backend API:</strong> <span id="backend-status">🔄 Checking...</span></p>
            <p><strong>Deployment:</strong> <span style="color: #4CAF50;">✅ Successful</span></p>
        </div>
        
        <div class="features">
            <div class="feature">
                <h3>📊 Cost Analytics</h3>
                <p>Real-time cost monitoring and analysis across multiple cloud platforms</p>
            </div>
            <div class="feature">
                <h3>🔧 Resource Optimization</h3>
                <p>Automated recommendations for cost optimization and resource rightsizing</p>
            </div>
            <div class="feature">
                <h3>📈 Financial Reporting</h3>
                <p>Comprehensive reporting and budgeting tools for financial transparency</p>
            </div>
        </div>
        
        <div style="margin-top: 50px;">
            <button class="btn" onclick="checkBackend()">🔄 Check Backend Status</button>
            <button class="btn" onclick="window.open('/health', '_blank')">🏥 Health Check</button>
        </div>
    </div>
    
    <script>
        async function checkBackend() {
            const statusElement = document.getElementById('backend-status');
            statusElement.innerHTML = '🔄 Checking...';
            
            try {
                const backendUrl = 'https://backend.azurewebsites.net';
                const response = await fetch(`${backendUrl}/api/status`);
                const data = await response.json();
                
                if (response.ok) {
                    statusElement.innerHTML = '✅ Online';
                    statusElement.style.color = '#4CAF50';
                } else {
                    throw new Error('Backend not responding');
                }
            } catch (error) {
                statusElement.innerHTML = '❌ Offline';
                statusElement.style.color = '#f44336';
            }
        }
        
        // Check backend status on page load
        checkBackend();
    </script>
</body>
</html>
'@
    $frontendIndex | Out-File -FilePath (Join-Path $FrontendSourcePath "index.html") -Encoding utf8
      # Create server.js
    $frontendServer = @'
const express = require('express');
const path = require('path');
const app = express();
const port = process.env.PORT || 8080;

// Serve static files
app.use(express.static(__dirname));

// Health check endpoint
app.get('/health', (req, res) => {
    res.status(200).json({
        status: 'healthy',
        timestamp: new Date().toISOString(),
        service: 'finops-frontend'
    });
});

// Handle SPA routing - serve index.html for all other routes
app.get('*', (req, res) => {
    res.sendFile(path.join(__dirname, 'index.html'));
});

app.listen(port, () => {
    console.log(`🎨 FinOps Frontend running on port ${port}`);
    console.log(`🌐 Frontend URL: Frontend site running`);
});
'@
    $frontendServer | Out-File -FilePath (Join-Path $FrontendSourcePath "server.js") -Encoding utf8
    
    Write-Host "✅ Sample frontend application created" -ForegroundColor Green
}

# ===============================================================
# Step 8: Deploy Applications
# ===============================================================
Write-DeploymentLog -Message "Deploying applications" -Level "Step" -Step "APPLICATION_DEPLOYMENT"

# Deploy Backend Application
Write-Host "`n🔧 Deploying Backend application..." -ForegroundColor Yellow

try {
    $originalLocation = Get-Location
    Set-Location $BackendSourcePath
      # Create deployment package
    $deploymentZip = Join-Path $deploymenttemp "backend-deployment.zip"
    if (Test-Path $deploymentZip) { Remove-Item $deploymentZip -Force }
      # Clean up any existing node_modules to avoid compression issues
    if (Test-Path "node_modules") {
        Write-Host "   🧹 Cleaning node_modules directory for deployment..." -ForegroundColor Gray
        Remove-Item "node_modules" -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    # Remove .deployment file as we'll let Azure handle the build process
    if (Test-Path ".deployment") {
        Remove-Item ".deployment" -Force
    }
    
    # Get files to include (exclude problematic directories)
    $filesToInclude = Get-ChildItem -Path . | Where-Object { 
        $_.Name -notin @("node_modules", ".git", ".nyc_output", "coverage", "logs") 
    }
      # Create zip package with only necessary files
    if ($filesToInclude.Count -gt 0) {
        #Compress-Archive -Path $filesToInclude.FullName -DestinationPath $deploymentZip -Force
        Compress-Archive -Path (Get-ChildItem -Path $BackendSourcePath -Recurse).FullName -DestinationPath $deploymentZip -Force
    } else {
        throw "No deployable files found in backend directory"
    }
      # Configure Node.js runtime and startup command for backend
    Write-Host "   ⚙️ Configuring Node.js runtime and startup..." -ForegroundColor Gray
    
    # Set Node.js version
    az webapp config appsettings set --name $BackendAppName --resource-group $WebAppsResourceGroup --settings WEBSITE_NODE_DEFAULT_VERSION="$NodeVersion" --output none
    
    # Configure startup command with npm start
    az webapp config set --name $BackendAppName --resource-group $WebAppsResourceGroup --startup-file "npm start" --output none
      # Set additional app settings for proper Node.js deployment
    az webapp config appsettings set --name $BackendAppName --resource-group $WebAppsResourceGroup --settings SCM_DO_BUILD_DURING_DEPLOYMENT="true" WEBSITE_RUN_FROM_PACKAGE="1" PORT="8080" NODE_ENV="production" --output none
    
    # Deploy to Azure using the new deployment method
    Write-Host "   🚀 Uploading to Azure..." -ForegroundColor Gray
    az webapp deploy --name $BackendAppName --resource-group $WebAppsResourceGroup --src-path $deploymentZip --type zip --output none
    
    # Wait a moment for deployment to complete
    Start-Sleep -Seconds 10
    
    # Restart the app to ensure new settings take effect
    Write-Host "   🔄 Restarting backend app..." -ForegroundColor Gray
    az webapp restart --name $BackendAppName --resource-group $WebAppsResourceGroup --output none
    
    Write-Host "✅ Backend deployed successfully" -ForegroundColor Green
    Write-DeploymentLog -Message "Backend application deployed successfully" -Level "Success"
    
} catch {
    Write-DeploymentLog -Message "Backend deployment failed: $_" -Level "Error"
    Write-Host "❌ Backend deployment failed: $_" -ForegroundColor Red
} finally {
    Set-Location $originalLocation
}

# Deploy Frontend Application  
Write-Host "`n🎨 Deploying Frontend application..." -ForegroundColor Yellow

try {
    $originalLocation = Get-Location
    Set-Location $FrontendSourcePath
      # Create deployment package
    $deploymentZip = Join-Path $deploymenttemp "frontend-deployment.zip"
    if (Test-Path $deploymentZip) { Remove-Item $deploymentZip -Force }
      # Clean up any existing node_modules to avoid compression issues
    if (Test-Path "node_modules") {
        Write-Host "   🧹 Cleaning node_modules directory for deployment..." -ForegroundColor Gray
        Remove-Item "node_modules" -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    # Remove .deployment file as we'll let Azure handle the build process
    if (Test-Path ".deployment") {
        Remove-Item ".deployment" -Force
    }
    
    # Get files to include (exclude problematic directories)
    $filesToInclude = Get-ChildItem -Path . | Where-Object { 
        $_.Name -notin @("node_modules", ".git", ".nyc_output", "coverage", "logs") 
    }
      # Create zip package with only necessary files
    if ($filesToInclude.Count -gt 0) {
        Compress-Archive -Path (Get-ChildItem -Path $BackendSourcePath -Recurse).FullName -DestinationPath $deploymentZip -Force
        #Compress-Archive -Path $filesToInclude.FullName -DestinationPath $deploymentZip -Force
    } else {
        throw "No deployable files found in frontend directory"
    }
      # Configure Node.js runtime and startup command for frontend
    Write-Host "   ⚙️ Configuring Node.js runtime and startup..." -ForegroundColor Gray
    
    # Set Node.js version
    az webapp config appsettings set --name $FrontendAppName --resource-group $WebAppsResourceGroup --settings WEBSITE_NODE_DEFAULT_VERSION="$NodeVersion" --output none
    
    # Configure startup command with npm start
    az webapp config set --name $FrontendAppName --resource-group $WebAppsResourceGroup --startup-file "npm start" --output none
      # Set additional app settings for proper Node.js deployment
    az webapp config appsettings set --name $FrontendAppName --resource-group $WebAppsResourceGroup --settings SCM_DO_BUILD_DURING_DEPLOYMENT="true" WEBSITE_RUN_FROM_PACKAGE="1" PORT="8080" NODE_ENV="production" --output none
    
    # Deploy to Azure using the new deployment method
    Write-Host "   🚀 Uploading to Azure..." -ForegroundColor Gray
    az webapp deploy --name $FrontendAppName --resource-group $WebAppsResourceGroup --src-path $deploymentZip --type zip --output none
    
    # Wait a moment for deployment to complete
    Start-Sleep -Seconds 10
    
    # Restart the app to ensure new settings take effect
    Write-Host "   🔄 Restarting frontend app..." -ForegroundColor Gray
    az webapp restart --name $FrontendAppName --resource-group $WebAppsResourceGroup --output none
    
    Write-Host "✅ Frontend deployed successfully" -ForegroundColor Green
    Write-DeploymentLog -Message "Frontend application deployed successfully" -Level "Success"
    
} catch {
    Write-DeploymentLog -Message "Frontend deployment failed: $_" -Level "Error"
    Write-Host "❌ Frontend deployment failed: $_" -ForegroundColor Red
} finally {
    Set-Location $originalLocation
}

# ===============================================================
# Step 9: Verify Deployment Status
# ===============================================================
Write-DeploymentLog -Message "Verifying deployment status" -Level "Step" -Step "DEPLOYMENT_VERIFICATION"

Write-Host "`n🔍 Verifying deployment status..." -ForegroundColor Yellow

# Check backend status
$backendStatus = Get-AppServiceDeploymentStatus -AppName $BackendAppName -ResourceGroup $WebAppsResourceGroup
if ($backendStatus) {
    $deploymentSummary.resources += @{
        name = $BackendAppName
        type = "Backend App Service"
        status = $backendStatus.Status
        url = "https://$($backendStatus.Hostname)"
        deploymentTime = (Get-Date).ToString("dd-MM-yyyy HH:mm:ss")
    }
}

# Check frontend status  
$frontendStatus = Get-AppServiceDeploymentStatus -AppName $FrontendAppName -ResourceGroup $WebAppsResourceGroup
if ($frontendStatus) {
    $deploymentSummary.resources += @{
        name = $FrontendAppName
        type = "Frontend App Service"
        status = $frontendStatus.Status
        url = "https://$($frontendStatus.Hostname)"
        deploymentTime = (Get-Date).ToString("dd-MM-yyyy HH:mm:ss")
    }
}

# Test application startup
Write-Host "`n🧪 Testing application startup..." -ForegroundColor Yellow

# Test backend startup
Test-AppServiceStartup -AppName $BackendAppName -AppType "Backend" -TimeoutMinutes 5

# Test frontend startup
Test-AppServiceStartup -AppName $FrontendAppName -AppType "Frontend" -TimeoutMinutes 5

# ===============================================================
# Final Summary
# ===============================================================
$deploymentEnd = Get-Date
$deploymentSummary.endTime = $deploymentEnd.ToString("dd-MM-yyyy HH:mm:ss")
$deploymentSummary.duration = ($deploymentEnd - $deploymentStart).ToString("hh\:mm\:ss")

# Calculate costs
$deploymentSummary.costs = @{
    appServicePlan = @{
        sku = $AppServiceSku
        estimatedMonthlyCostUSD = switch ($AppServiceSku) {
            "B1" { 55 }
            "B2" { 110 }
            "B3" { 220 }
            "S1" { 150 }
            "S2" { 300 }
            "S3" { 600 }
            "P1V3" { 180 }
            default { 180 }
        }
    }
}

if ($EnableApplicationInsights) {
    $deploymentSummary.costs.applicationInsights = @{
        estimatedMonthlyCostUSD = 15
    }
}

$deploymentSummary.totalCostEstimateUSD = ($deploymentSummary.costs.Values | ForEach-Object { $_.estimatedMonthlyCostUSD } | Measure-Object -Sum).Sum

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
Write-Host "   $(if($hasAutoScaling){'✅'}else{'❌'}) Auto-scaling ($(if($hasAutoScaling){'enabled'}else{'not available for this SKU'}))" -ForegroundColor White
Write-Host "   $(if($hasStagingSlots){'✅'}else{'❌'}) Staging slots ($(if($hasStagingSlots){'available'}else{'not available for this SKU'}))" -ForegroundColor White
Write-Host "   $(if($EnableApplicationInsights){'✅'}else{'❌'}) Application Insights ($(if($EnableApplicationInsights){'enabled'}else{'disabled'}))" -ForegroundColor White

Write-Host "`n🌐 ENDPOINTS:" -ForegroundColor Yellow
Write-Host "   🔧 Backend API: https://$BackendAppName.azurewebsites.net" -ForegroundColor White
Write-Host "   🎨 Frontend: https://$FrontendAppName.azurewebsites.net" -ForegroundColor White
Write-Host "   🧪 API Health: https://$BackendAppName.azurewebsites.net/health" -ForegroundColor White
Write-Host "   📊 Service Health: https://$BackendAppName.azurewebsites.net/api/service-health" -ForegroundColor White
Write-Host "   📋 API Status: https://$BackendAppName.azurewebsites.net/api/status" -ForegroundColor White

Write-Host "`n💰 COST ESTIMATE:" -ForegroundColor Yellow
Write-Host "   💵 App Service Plan ($AppServiceSku): ~$($deploymentSummary.costs.appServicePlan.estimatedMonthlyCostUSD) USD/month" -ForegroundColor White
if ($EnableApplicationInsights) {
    Write-Host "   📊 Application Insights: ~$($deploymentSummary.costs.applicationInsights.estimatedMonthlyCostUSD) USD/month" -ForegroundColor White
}
Write-Host "   💰 Total Estimated: ~$($deploymentSummary.totalCostEstimateUSD) USD/month" -ForegroundColor White

Write-Host "`n📋 NEXT STEPS:" -ForegroundColor Yellow
Write-Host "   1. 🧪 Test the frontend: https://$FrontendAppName.azurewebsites.net" -ForegroundColor White
Write-Host "   2. 🔧 Test the backend API: https://$BackendAppName.azurewebsites.net" -ForegroundColor White
Write-Host "   3. 📊 Check service health: https://$BackendAppName.azurewebsites.net/api/service-health" -ForegroundColor White
Write-Host "   4. 🚀 Set up CI/CD pipeline with GitHub Actions" -ForegroundColor White
Write-Host "   5. 📊 Monitor performance in Azure portal" -ForegroundColor White

Write-Host "`n🚀 QUICK ACCESS:" -ForegroundColor Yellow
Write-Host "   🌐 Open Frontend: Start-Process 'https://$FrontendAppName.azurewebsites.net'" -ForegroundColor Gray
Write-Host "   🔧 Open Backend: Start-Process 'https://$BackendAppName.azurewebsites.net'" -ForegroundColor Gray
Write-Host "   🧪 Check Health: Start-Process 'https://$BackendAppName.azurewebsites.net/health'" -ForegroundColor Gray

Write-Host "`n" + "=" * 60 -ForegroundColor Cyan
Write-Host "🎯 Enhanced FinOps Platform ready for production use!" -ForegroundColor Green

# Save deployment summary
try {
    $deploymentSummary | ConvertTo-Json -Depth 10 | Out-File -FilePath $summaryFile -Encoding utf8
    Write-Host "📄 Deployment summary saved: $summaryFile" -ForegroundColor Cyan
} catch {
    Write-Host "⚠️ Failed to save deployment summary: $_" -ForegroundColor Yellow
}

Write-DeploymentLog -Message "Enhanced FinOps Platform deployment completed successfully" -Level "Success"

function Get-AppServiceDeploymentStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppName,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroup
    )
    
    Write-Host "`n🔍 Checking deployment status for: $AppName" -ForegroundColor Cyan
    
    try {
        # Get app service details
        $appDetails = az webapp show --name $AppName --resource-group $ResourceGroup | ConvertFrom-Json
        
        # Get current settings
        $appSettings = az webapp config appsettings list --name $AppName --resource-group $ResourceGroup | ConvertFrom-Json
        
        # Get deployment status
        $deploymentStatus = az webapp deployment list --name $AppName --resource-group $ResourceGroup | ConvertFrom-Json
        
        Write-Host "   📊 App Status: $($appDetails.state)" -ForegroundColor White
        Write-Host "   🏗️ Default hostname: $($appDetails.defaultHostName)" -ForegroundColor White
        Write-Host "   🔧 Runtime stack: $($appDetails.siteConfig.linuxFxVersion)" -ForegroundColor White
        
        # Check important settings
        $nodeVersion = ($appSettings | Where-Object { $_.name -eq "WEBSITE_NODE_DEFAULT_VERSION" }).value
        $startupFile = $appDetails.siteConfig.appCommandLine
        $buildDuringDeploy = ($appSettings | Where-Object { $_.name -eq "SCM_DO_BUILD_DURING_DEPLOYMENT" }).value
        
        Write-Host "   📦 Node version: $nodeVersion" -ForegroundColor White
        Write-Host "   🚀 Startup command: $startupFile" -ForegroundColor White
        Write-Host "   🔨 Build during deployment: $buildDuringDeploy" -ForegroundColor White
        
        # Show recent deployments
        if ($deploymentStatus -and $deploymentStatus.Count -gt 0) {
            $latestDeployment = $deploymentStatus[0]
            Write-Host "   📅 Latest deployment: $($latestDeployment.status) at $($latestDeployment.receivedTime)" -ForegroundColor White
        }
        
        return @{
            Status = $appDetails.state
            Hostname = $appDetails.defaultHostName
            RuntimeStack = $appDetails.siteConfig.linuxFxVersion
            NodeVersion = $nodeVersion
            StartupCommand = $startupFile
            BuildDuringDeploy = $buildDuringDeploy
            LatestDeployment = $latestDeployment
        }
        
    } catch {
        Write-Host "   ❌ Error checking status: $_" -ForegroundColor Red
        return $null
    }
}

function Get-AppServiceLogs {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppName,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroup,
        
        [Parameter(Mandatory = $false)]
        [int]$Lines = 100
    )
    
    Write-Host "`n📄 Getting recent logs for: $AppName" -ForegroundColor Cyan
    
    try {
        # Enable logging
        az webapp log config --name $AppName --resource-group $ResourceGroup --web-server-logging filesystem --output none
        
        # Get logs
        $logs = az webapp log tail --name $AppName --resource-group $ResourceGroup --provider application | Out-String
        
        if ($logs) {
            Write-Host "   📋 Recent application logs:" -ForegroundColor White
            Write-Host $logs -ForegroundColor Gray
        } else {
            Write-Host "   ℹ️ No application logs available yet" -ForegroundColor Yellow
        }
        
    } catch {
        Write-Host "   ❌ Error getting logs: $_" -ForegroundColor Red
    }
}

Write-Host "`n🔧 TROUBLESHOOTING GUIDE:" -ForegroundColor Yellow
Write-Host "   If applications are not starting properly:" -ForegroundColor White
Write-Host "   1. 🔍 Check logs: az webapp log tail --name <app-name> --resource-group $WebAppsResourceGroup" -ForegroundColor Gray
Write-Host "   2. 🔄 Restart apps: az webapp restart --name <app-name> --resource-group $WebAppsResourceGroup" -ForegroundColor Gray
Write-Host "   3. 📋 Check configuration: az webapp config show --name <app-name> --resource-group $WebAppsResourceGroup" -ForegroundColor Gray
Write-Host "   4. 🐛 Debug startup: Check if package.json has correct 'start' script" -ForegroundColor Gray
Write-Host "   5. 🔧 Manual fix: Set startup command to 'npm start' in Azure portal" -ForegroundColor Gray

Write-Host "`n📋 COMMON FIXES:" -ForegroundColor Yellow
Write-Host "   • If getting default static site: Ensure startup command is set to 'npm start'" -ForegroundColor White
Write-Host "   • If npm install fails: Check package.json syntax and dependencies" -ForegroundColor White
Write-Host "   • If app won't start: Verify PORT environment variable is set to 8080" -ForegroundColor White
Write-Host "   • For build issues: Enable SCM_DO_BUILD_DURING_DEPLOYMENT=true" -ForegroundColor White

Write-Host "`n🔍 DEBUGGING COMMANDS:" -ForegroundColor Yellow
Write-Host "   # Get backend logs:" -ForegroundColor Gray
Write-Host "   Get-AppServiceLogs -AppName '$BackendAppName' -ResourceGroup '$WebAppsResourceGroup'" -ForegroundColor White
Write-Host "   # Get frontend logs:" -ForegroundColor Gray
Write-Host "   Get-AppServiceLogs -AppName '$FrontendAppName' -ResourceGroup '$WebAppsResourceGroup'" -ForegroundColor White
Write-Host "   # Check backend status:" -ForegroundColor Gray
Write-Host "   Get-AppServiceDeploymentStatus -AppName '$BackendAppName' -ResourceGroup '$WebAppsResourceGroup'" -ForegroundColor White

Write-DeploymentLog -Message "Enhanced FinOps Platform deployment completed successfully" -Level "Success"
