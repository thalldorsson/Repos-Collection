function Test-FinOpsConfiguration {
    <#
    .SYNOPSIS
        Validates the FinOps onboarding configuration file.
    
    .DESCRIPTION
        Tests the configuration JSON file for required fields, correct formats, and optionally
        validates connectivity to external services (Azure, Key Vault, Jira).
        
        This function helps catch configuration errors early before running lengthy onboarding processes.
    
    .PARAMETER ConfigPath
        Path to the configuration JSON file. Defaults to 'config.json' in the current directory.
    
    .PARAMETER ValidateConnectivity
        Optional switch to perform deep validation by testing actual connectivity to:
        - Azure tenant (if defaultTenantId is provided)
        - Azure Key Vault (if keyVaultName is provided)
        - Jira instance (if jiraBaseUrl is provided)
    
    .EXAMPLE
        Test-FinOpsConfiguration
        
        Validates the default config.json file for structure and format.
    
    .EXAMPLE
        Test-FinOpsConfiguration -ConfigPath 'C:\configs\custom-config.json'
        
        Validates a custom configuration file.
    
    .EXAMPLE
        Test-FinOpsConfiguration -ValidateConnectivity
        
        Validates configuration and tests actual connectivity to Azure, Key Vault, and Jira.
    
    .OUTPUTS
        Boolean. Returns $true if validation passes, $false otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ConfigPath = 'config.json',
        
        [Parameter(Mandatory = $false)]
        [switch]$ValidateConnectivity
    )
    
    Write-Host "`n=== FinOps Configuration Validation ===" -ForegroundColor Cyan
    Write-Host "Config file: $ConfigPath`n" -ForegroundColor Gray
    
    $validationPassed = $true
    
    # Check if file exists
    if (-not (Test-Path $ConfigPath)) {
        Write-Host "[FAIL] Configuration file not found: $ConfigPath" -ForegroundColor Red
        return $false
    }
    Write-Host "[PASS] Configuration file exists" -ForegroundColor Green
    
    # Load JSON
    try {
        $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
        Write-Host "[PASS] Configuration file is valid JSON" -ForegroundColor Green
    } catch {
        Write-Host "[FAIL] Configuration file is not valid JSON: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
    
    # Validate GUID format for Tenant ID
    if ($config.defaultTenantId) {
        $guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        if ($config.defaultTenantId -match $guidPattern) {
            Write-Host "[PASS] defaultTenantId is a valid GUID" -ForegroundColor Green
        } else {
            Write-Host "[FAIL] defaultTenantId is not a valid GUID format: $($config.defaultTenantId)" -ForegroundColor Red
            $validationPassed = $false
        }
    } else {
        Write-Host "[WARN] defaultTenantId is not set (optional but recommended)" -ForegroundColor Yellow
    }
    
    # Validate output directory path
    if ($config.outputDirectory) {
        $parentDir = Split-Path -Path $config.outputDirectory -Parent
        if ($parentDir -and (Test-Path $parentDir)) {
            Write-Host "[PASS] outputDirectory parent path exists" -ForegroundColor Green
        } elseif (-not $parentDir) {
            Write-Host "[PASS] outputDirectory uses relative path" -ForegroundColor Green
        } else {
            Write-Host "[WARN] outputDirectory parent path does not exist: $parentDir" -ForegroundColor Yellow
        }
    } else {
        Write-Host "[WARN] outputDirectory is not set (will use default)" -ForegroundColor Yellow
    }
    
    # Validate cost lookback settings
    if ($config.costLookback) {
        if ($config.costLookback.months -is [int] -and $config.costLookback.months -gt 0) {
            Write-Host "[PASS] costLookback.months is a valid positive integer" -ForegroundColor Green
        } else {
            Write-Host "[FAIL] costLookback.months must be a positive integer" -ForegroundColor Red
            $validationPassed = $false
        }
    } else {
        Write-Host "[WARN] costLookback settings not configured (will use defaults)" -ForegroundColor Yellow
    }
    
    # Validate Jira URL format
    if ($config.jiraBaseUrl) {
        if ($config.jiraBaseUrl -match '^https?://') {
            Write-Host "[PASS] jiraBaseUrl is a valid URL format" -ForegroundColor Green
        } else {
            Write-Host "[FAIL] jiraBaseUrl must start with http:// or https://" -ForegroundColor Red
            $validationPassed = $false
        }
    } else {
        Write-Host "[INFO] jiraBaseUrl is not set (Jira integration disabled)" -ForegroundColor Cyan
    }
    
    # Validate Key Vault configuration
    if ($config.keyVaultName) {
        # Key Vault names must be 3-24 characters, alphanumeric and hyphens only
        if ($config.keyVaultName -match '^[a-zA-Z0-9-]{3,24}$') {
            Write-Host "[PASS] keyVaultName is a valid format (3-24 chars, alphanumeric + hyphens)" -ForegroundColor Green
        } else {
            Write-Host "[FAIL] keyVaultName must be 3-24 characters, alphanumeric and hyphens only" -ForegroundColor Red
            $validationPassed = $false
        }
    } else {
        Write-Host "[INFO] keyVaultName is not set (secrets must be provided directly)" -ForegroundColor Cyan
    }
    
    # Validate secrets configuration
    if ($config.secrets) {
        $secretKeys = @('powerBiTenantId', 'powerBiApplicationId', 'powerBiClientSecret', 'jiraApiToken')
        $foundSecrets = 0
        foreach ($key in $secretKeys) {
            if ($config.secrets.$key) {
                $foundSecrets++
            }
        }
        
        if ($foundSecrets -gt 0) {
            Write-Host "[PASS] Found $foundSecrets secret configuration(s)" -ForegroundColor Green
        } else {
            Write-Host "[WARN] No secrets configured (must be provided at runtime or via Key Vault)" -ForegroundColor Yellow
        }
    }
    
    # === Connectivity Validation (Optional Deep Check) ===
    if ($ValidateConnectivity) {
        Write-Host "`n--- Connectivity Validation ---" -ForegroundColor Cyan
        
        # Test Azure tenant connectivity
        if ($config.defaultTenantId) {
            Write-Host "Testing Azure tenant connectivity..." -ForegroundColor Gray
            try {
                $context = Get-AzContext
                if ($context -and $context.Tenant.Id -eq $config.defaultTenantId) {
                    Write-Host "[PASS] Connected to Azure tenant: $($config.defaultTenantId)" -ForegroundColor Green
                } else {
                    Write-Host "[WARN] Not connected to configured tenant. Current: $($context.Tenant.Id)" -ForegroundColor Yellow
                    Write-Host "        Run: Connect-AzAccount -Tenant $($config.defaultTenantId)" -ForegroundColor Gray
                }
            } catch {
                Write-Host "[WARN] Unable to verify Azure connectivity: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        
        # Test Key Vault connectivity
        if ($config.keyVaultName) {
            Write-Host "Testing Key Vault connectivity..." -ForegroundColor Gray
            try {
                $vault = Get-AzKeyVault -VaultName $config.keyVaultName -ErrorAction Stop
                if ($vault) {
                    Write-Host "[PASS] Successfully connected to Key Vault: $($config.keyVaultName)" -ForegroundColor Green
                }
            } catch {
                Write-Host "[FAIL] Cannot connect to Key Vault '$($config.keyVaultName)': $($_.Exception.Message)" -ForegroundColor Red
                $validationPassed = $false
            }
        }
        
        # Test Jira connectivity
        if ($config.jiraBaseUrl) {
            Write-Host "Testing Jira connectivity..." -ForegroundColor Gray
            try {
                $testUri = "$($config.jiraBaseUrl.TrimEnd('/'))/rest/api/2/serverInfo"
                $response = Invoke-FinOpsRestMethodWithRetry -Uri $testUri -Method Get -ErrorAction Stop -TimeoutSeconds 10
                Write-Host "[PASS] Successfully connected to Jira: $($response.serverTitle)" -ForegroundColor Green
            } catch {
                Write-Host "[WARN] Cannot connect to Jira '$($config.jiraBaseUrl)': $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host "        This may require authentication. Check jiraApiToken configuration." -ForegroundColor Gray
            }
        }
    }
    
    # Summary
    Write-Host "`n=== Validation Summary ===" -ForegroundColor Cyan
    if ($validationPassed) {
        Write-Host "Configuration validation PASSED" -ForegroundColor Green
    } else {
        Write-Host "Configuration validation FAILED - please fix errors above" -ForegroundColor Red
    }
    
    return $validationPassed
}
