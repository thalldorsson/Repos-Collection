<#
.SYNOPSIS
    Deploys Azure Workbooks for WinRE Health Monitoring.

.DESCRIPTION
    Automates the deployment of Azure Workbooks (Executive and Operational dashboards)
    for WinRE Health Monitoring using ARM templates. Supports individual or batch
    deployment with proper validation and error handling.

.PARAMETER ResourceGroup
    Azure resource group name where workbooks will be deployed.

.PARAMETER Location
    Azure region for workbook resources (e.g., 'westeurope', 'eastus').

.PARAMETER SubscriptionId
    Azure subscription ID. If not provided, uses current Azure CLI context.

.PARAMETER DeployExecutive
    Deploy the Executive Dashboard workbook.

.PARAMETER DeployOperational
    Deploy the Operational Dashboard workbook.

.PARAMETER DeployAll
    Deploy all available workbooks.

.PARAMETER WorkbookKind
    Workbook visibility: 'shared' (visible to all with access) or 'user' (private).
    Default: 'shared'

.PARAMETER Tags
    Optional tags to apply to workbook resources as a hashtable.

.PARAMETER DryRun
    Validate templates without deploying.

.PARAMETER Verbose
    Show detailed deployment progress.

.EXAMPLE
    .\Deploy-Workbooks.ps1 -ResourceGroup "rg-winrehealth-we-prod" -Location "westeurope" -DeployAll

.EXAMPLE
    .\Deploy-Workbooks.ps1 -ResourceGroup "rg-winre" -Location "eastus" -DeployExecutive -Verbose

.EXAMPLE
    # Deploy with custom tags
    $tags = @{ Environment = 'Production'; CostCenter = 'IT' }
    .\Deploy-Workbooks.ps1 -ResourceGroup "rg-winre" -Location "westeurope" -DeployAll -Tags $tags

.EXAMPLE
    # Dry run validation
    .\Deploy-Workbooks.ps1 -ResourceGroup "rg-winre" -Location "westeurope" -DeployAll -DryRun

.NOTES
    Version: 1.0.0
    Author: WinRE Health Monitor Team
    Requires: Azure CLI 2.50.0+
    Prerequisites:
    - Azure CLI installed and authenticated (az login)
    - Contributor role on target resource group
    - Workbook Contributor role (or higher) on resource group
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$Location,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [switch]$DeployExecutive,

    [Parameter(Mandatory = $false)]
    [switch]$DeployOperational,

    [Parameter(Mandatory = $false)]
    [switch]$DeployAll,

    [Parameter(Mandatory = $false)]
    [ValidateSet('shared', 'user')]
    [string]$WorkbookKind = 'shared',

    [Parameter(Mandatory = $false)]
    [hashtable]$Tags = @{},

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptPath)
$DashboardPath = Join-Path $RepoRoot "Config\Dashboards"

# ============================================================================
# Functions
# ============================================================================

function Write-Banner {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " WinRE Health Monitor - Workbook Deployment" -ForegroundColor Cyan
    Write-Host " Version: 1.0.0" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step {
    param([string]$Message)
    Write-Host "▶ $Message" -ForegroundColor Green
}

function Write-Info {
    param([string]$Message)
    Write-Host "  ℹ $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "  ✓ $Message" -ForegroundColor Green
}

function Write-Warning {
    param([string]$Message)
    Write-Host "  ⚠ $Message" -ForegroundColor Yellow
}

function Write-ErrorMessage {
    param([string]$Message)
    Write-Host "  ✗ $Message" -ForegroundColor Red
}

function Test-AzureCLI {
    Write-Step "Checking Azure CLI installation..."
    try {
        $azVersion = az version --query '\"azure-cli\"' -o tsv 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Azure CLI not found"
        }
        Write-Success "Azure CLI version: $azVersion"
        return $true
    }
    catch {
        Write-ErrorMessage "Azure CLI is not installed or not in PATH"
        Write-Info "Install from: https://learn.microsoft.com/cli/azure/install-azure-cli"
        return $false
    }
}

function Test-AzureLogin {
    Write-Step "Verifying Azure CLI authentication..."
    try {
        $account = az account show 2>$null | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $null -eq $account) {
            throw "Not logged in"
        }
        Write-Success "Authenticated as: $($account.user.name)"
        Write-Info "Subscription: $($account.name) ($($account.id))"
        return $account
    }
    catch {
        Write-ErrorMessage "Not authenticated to Azure"
        Write-Info "Run: az login"
        return $null
    }
}

function Test-ResourceGroup {
    param([string]$Name)
    Write-Step "Verifying resource group: $Name"
    try {
        $rg = az group show --name $Name 2>$null | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $null -eq $rg) {
            Write-Warning "Resource group '$Name' does not exist"
            return $false
        }
        Write-Success "Resource group exists: $($rg.location)"
        return $true
    }
    catch {
        Write-Warning "Resource group '$Name' not found"
        return $false
    }
}

function Test-TemplateFile {
    param(
        [string]$Path,
        [string]$Name
    )
    Write-Step "Validating template: $Name"
    if (-not (Test-Path $Path)) {
        Write-ErrorMessage "Template file not found: $Path"
        return $false
    }
    Write-Success "Found: $Path"
    
    # Validate it's valid JSON
    try {
        Get-Content $Path -Raw | ConvertFrom-Json | Out-Null
        Write-Success "Template is valid JSON"
    }
    catch {
        Write-ErrorMessage "Template is not valid JSON: $_"
        return $false
    }
    
    return $true
}

function Deploy-Workbook {
    param(
        [string]$Name,
        [string]$TemplatePath,
        [string]$ResourceGroup,
        [string]$Location,
        [string]$Kind,
        [hashtable]$Tags,
        [bool]$IsDryRun
    )
    
    Write-Step "Deploying workbook: $Name"
    
    $deploymentName = "workbook-$Name-$(Get-Date -Format 'yyyyMMddHHmmss')"
    
    # Build parameters
    $params = @(
        "--resource-group", $ResourceGroup,
        "--template-file", $TemplatePath,
        "--name", $deploymentName,
        "--parameters", "location=$Location",
        "--parameters", "kind=$Kind"
    )
    
    # Add tags if provided
    if ($Tags.Count -gt 0) {
        try {
            # Validate tag values are serializable
            foreach ($key in $Tags.Keys) {
                $value = $Tags[$key]
                if ($null -ne $value -and -not ($value -is [string] -or $value -is [int] -or $value -is [bool])) {
                    Write-Warning "Tag '$key' has non-primitive value type. Converting to string."
                    $Tags[$key] = $value.ToString()
                }
            }
            $tagsJson = $Tags | ConvertTo-Json -Compress
            $params += "--parameters"
            $params += "tags=$tagsJson"
        }
        catch {
            Write-Warning "Failed to serialize tags: $_. Continuing without tags."
        }
    }
    
    # Add what-if for dry run
    if ($IsDryRun) {
        $params += "--what-if"
        Write-Info "DRY RUN: Validating deployment (no changes will be made)"
    }
    
    try {
        Write-Info "Deployment name: $deploymentName"
        
        # Execute deployment
        $result = az deployment group create @params 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorMessage "Deployment failed"
            Write-Host $result -ForegroundColor Red
            return $false
        }
        
        if (-not $IsDryRun) {
            try {
                $deployment = $result | ConvertFrom-Json -ErrorAction Stop
                if ($null -eq $deployment) {
                    Write-Warning "Deployment succeeded but response is empty"
                    return $true
                }
                
                Write-Success "Deployment completed successfully"
                Write-Info "Deployment ID: $($deployment.id)"
                
                if ($deployment.properties.outputs.workbookResourceId) {
                    Write-Success "Workbook Resource ID: $($deployment.properties.outputs.workbookResourceId.value)"
                }
            }
            catch [System.ArgumentException] {
                Write-Warning "Deployment succeeded but response JSON is malformed. Deployment likely completed successfully."
                Write-Verbose "JSON parsing error: $_"
                return $true  # Deployment succeeded even if we can't parse the output
            }
            catch {
                Write-Warning "Deployment succeeded but failed to parse response: $_"
                Write-Verbose "Response content: $result"
                return $true  # Deployment succeeded even if we can't parse the output
            }
        }
        else {
            Write-Success "Validation completed - no errors found"
        }
        
        return $true
    }
    catch {
        Write-ErrorMessage "Deployment error: $_"
        return $false
    }
}

function Get-WorkbookList {
    param([string]$ResourceGroup)
    Write-Step "Listing deployed workbooks..."
    try {
        # Correct Azure CLI command for listing workbooks
        # Note: There's no direct 'az monitor workbook list' command
        # We use Azure Resource Graph or REST API
        $output = az resource list `
            --resource-group $ResourceGroup `
            --resource-type "Microsoft.Insights/workbooks" `
            --query "[].{Name:name, DisplayName:properties.displayName, Location:location}" `
            -o json 2>$null
        
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to list workbooks (exit code: $LASTEXITCODE)"
            return @()
        }
        
        if ([string]::IsNullOrWhiteSpace($output)) {
            Write-Info "No workbooks found in resource group"
            return @()
        }
        
        try {
            $workbooks = $output | ConvertFrom-Json -ErrorAction Stop
            
            # Validate workbooks is an array
            if ($null -eq $workbooks) {
                Write-Info "No workbooks found in resource group"
                return @()
            }
            
            # Handle single item (not array) or array
            if ($workbooks -is [System.Array]) {
                $count = $workbooks.Count
            }
            elseif ($null -ne $workbooks.Name) {
                # Single workbook
                $workbooks = @($workbooks)
                $count = 1
            }
            else {
                Write-Info "No workbooks found in resource group"
                return @()
            }
            
            Write-Success "Found $count workbook(s):"
            foreach ($wb in $workbooks) {
                Write-Info "  - $($wb.DisplayName) [$($wb.Name)]"
            }
            return $workbooks
        }
        catch [System.ArgumentException] {
            Write-Warning "Failed to parse workbook list: Malformed JSON from Azure CLI"
            Write-Verbose "JSON parsing error: $_"
            Write-Verbose "Output was: $output"
            return @()
        }
        catch {
            Write-Warning "Failed to parse workbook list: $_"
            Write-Verbose "Output was: $output"
            return @()
        }
    }
    catch {
        Write-Warning "Could not list workbooks: $_"
        return @()
    }
}

# ============================================================================
# Main Execution
# ============================================================================

Write-Banner

# Validation checks
Write-Host "Pre-deployment Validation" -ForegroundColor Yellow
Write-Host "─────────────────────────────────────────────────────────────" -ForegroundColor Yellow

if (-not (Test-AzureCLI)) {
    exit 1
}

$account = Test-AzureLogin
if ($null -eq $account) {
    exit 1
}

# Set subscription if provided
if ($SubscriptionId) {
    Write-Step "Setting active subscription: $SubscriptionId"
    az account set --subscription $SubscriptionId 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-ErrorMessage "Failed to set subscription"
        exit 1
    }
    Write-Success "Subscription set"
}

# Verify resource group
if (-not (Test-ResourceGroup -Name $ResourceGroup)) {
    Write-ErrorMessage "Resource group validation failed"
    Write-Info "Create the resource group first: az group create --name $ResourceGroup --location $Location"
    exit 1
}

# Determine which workbooks to deploy
$workbooksToDeploy = @()

if ($DeployAll) {
    $DeployExecutive = $true
    $DeployOperational = $true
}

if ($DeployExecutive) {
    $execPath = Join-Path $DashboardPath "WinRE-Executive-Workbook.json"
    if (Test-TemplateFile -Path $execPath -Name "Executive Dashboard") {
        $workbooksToDeploy += @{
            Name = "Executive"
            Path = $execPath
            DisplayName = "WinRE Executive Dashboard"
        }
    }
}

if ($DeployOperational) {
    $operPath = Join-Path $DashboardPath "WinREHealthWorkbook.json"
    if (Test-TemplateFile -Path $operPath -Name "Operational Dashboard") {
        $workbooksToDeploy += @{
            Name = "Operational"
            Path = $operPath
            DisplayName = "WinRE Health Dashboard"
        }
    }
}

if ($workbooksToDeploy.Count -eq 0) {
    Write-ErrorMessage "No workbooks selected for deployment"
    Write-Info "Use -DeployExecutive, -DeployOperational, or -DeployAll"
    exit 1
}

# Deployment summary
Write-Host ""
Write-Host "Deployment Configuration" -ForegroundColor Yellow
Write-Host "─────────────────────────────────────────────────────────────" -ForegroundColor Yellow
Write-Info "Resource Group: $ResourceGroup"
Write-Info "Location: $Location"
Write-Info "Workbook Kind: $WorkbookKind"
Write-Info "Workbooks to deploy: $($workbooksToDeploy.Count)"
foreach ($wb in $workbooksToDeploy) {
    Write-Info "  - $($wb.DisplayName)"
}
if ($Tags.Count -gt 0) {
    Write-Info "Tags: $($Tags.Keys -join ', ')"
}
if ($DryRun) {
    Write-Warning "DRY RUN MODE - No changes will be made"
}
Write-Host ""

# Confirm deployment
if (-not $DryRun -and -not $Force) {
    $confirm = Read-Host "Proceed with deployment? (Y/N)"
    if ($confirm -ne 'Y' -and $confirm -ne 'y') {
        Write-Warning "Deployment cancelled by user"
        exit 0
    }
}

# Deploy workbooks
Write-Host "Workbook Deployment" -ForegroundColor Yellow
Write-Host "─────────────────────────────────────────────────────────────" -ForegroundColor Yellow

$successCount = 0
$failCount = 0

foreach ($wb in $workbooksToDeploy) {
    $success = Deploy-Workbook `
        -Name $wb.Name `
        -TemplatePath $wb.Path `
        -ResourceGroup $ResourceGroup `
        -Location $Location `
        -Kind $WorkbookKind `
        -Tags $Tags `
        -IsDryRun $DryRun
    
    if ($success) {
        $successCount++
    }
    else {
        $failCount++
    }
    Write-Host ""
}

# List deployed workbooks
if (-not $DryRun -and $successCount -gt 0) {
    Write-Host ""
    Get-WorkbookList -ResourceGroup $ResourceGroup
}

# Summary
Write-Host ""
Write-Host "Deployment Summary" -ForegroundColor Yellow
Write-Host "─────────────────────────────────────────────────────────────" -ForegroundColor Yellow

if ($DryRun) {
    Write-Success "Validation completed"
    Write-Info "Templates: $($workbooksToDeploy.Count) validated"
}
else {
    Write-Host "  Total workbooks: $($workbooksToDeploy.Count)" -ForegroundColor Cyan
    Write-Host "  Successful: $successCount" -ForegroundColor Green
    if ($failCount -gt 0) {
        Write-Host "  Failed: $failCount" -ForegroundColor Red
    }
}

Write-Host ""

if ($failCount -gt 0) {
    Write-ErrorMessage "Some deployments failed"
    exit 1
}

Write-Success "Deployment completed successfully"
Write-Host ""
Write-Info "Access workbooks at:"
Write-Info "  Azure Portal → Log Analytics workspace → Workbooks"
Write-Info "  Or: https://portal.azure.com/#blade/AppInsightsExtension/UsageNotebookBlade/ComponentId/%2Fsubscriptions%2F$($account.id)%2FresourceGroups%2F$ResourceGroup"
Write-Host ""

exit 0
