function Start-FinOpsBatchCustomerOnboarding {
    <#
    .SYNOPSIS
        Executes FinOps onboarding for multiple customers in parallel with controlled throttling.
    
    .DESCRIPTION
        Orchestrates batch customer onboarding by retrieving configuration from database (preferred)
        or Jira issues (fallback), then executing Invoke-FinOpsOnboarding for each customer.
        
        Uses PowerShell 7+ ForEach-Object -Parallel with throttling to prevent overwhelming APIs.
        Soft limit: 2 parallel operations (recommended)
        Hard limit: 4 parallel operations (maximum)
        
        Configuration precedence:
        1. Database (Get-FinOpsAzCustomerAppCredential) - primary source
        2. Jira (Get-FinOpsOnboardingFromJiraIssue) - fallback when DB returns null
        
        Emits structured logs when Jira fallback is used to highlight missing DB configuration.
    
    .PARAMETER CustomerIdentifiers
        Array of customer identifiers. Can be:
        - Jira issue keys (e.g., "FINOPS-123")
        - Customer names (for DB lookup)
        Required.
    
    .PARAMETER ThrottleLimit
        Maximum number of parallel customer onboarding operations.
        Valid range: 1-4
        Default: 2 (soft limit, recommended)
        Hard maximum: 4
    
    .PARAMETER ConnectionString
        SQL connection string for database lookups.
        If not specified, uses environment variable AFO_SQL_CONNECTION.
    
    .PARAMETER JiraBaseUrl
        Base URL for Jira instance (e.g., https://company.atlassian.net).
        Required when Jira fallback is needed.
    
    .PARAMETER JiraUsername
        Jira username/email for authentication.
        Required when Jira fallback is needed.
    
    .PARAMETER JiraApiToken
        Jira API token (SecureString) for authentication.
        Required when Jira fallback is needed.
    
    .PARAMETER UseAtlassianMcp
        Use Atlassian MCP provider for Jira operations instead of direct REST calls.
    
    .PARAMETER SkipReservations
        Skip reservation validation for all customers.
    
    .PARAMETER SkipCosts
        Skip cost validation for all customers.
    
    .PARAMETER SkipEmissions
        Skip emissions validation for all customers.
    
    .PARAMETER ReportFormat
        Report format for all customers. Options: Json, Markdown, Html, Excel, Both, None.
        Default: Json
    
    .PARAMETER OutputDirectory
        Base output directory for customer reports.
        Subdirectories will be created per customer.
    
    .PARAMETER PublishToJira
        Automatically publish onboarding results to Jira for each customer.
    
    .PARAMETER JiraTransitionStatus
        Target Jira status to transition issues to after onboarding completion.
    
    .PARAMETER MaxRetries
        Maximum retry attempts for transient failures per customer.
        Default: 3
    
    .PARAMETER ShowProgress
        Display progress bar during batch processing.
    
    .EXAMPLE
        # Batch onboard 3 customers using database configuration (soft limit)
        $identifiers = @("Customer1", "Customer2", "Customer3")
        $results = Start-FinOpsBatchCustomerOnboarding -CustomerIdentifiers $identifiers `
            -ConnectionString "Server=sqlserver;Database=FinOps;..." `
            -ThrottleLimit 2
    
    .EXAMPLE
        # Batch onboard using Jira issues with fallback to database
        $jiraToken = ConvertTo-SecureString "your-api-token" -AsPlainText -Force
        $results = Start-FinOpsBatchCustomerOnboarding `
            -CustomerIdentifiers @("FINOPS-123", "FINOPS-124") `
            -JiraBaseUrl "https://company.atlassian.net" `
            -JiraUsername "admin@company.com" `
            -JiraApiToken $jiraToken `
            -ConnectionString $connStr `
            -PublishToJira `
            -ThrottleLimit 2
    
    .EXAMPLE
        # Maximum parallelism (hard limit) for urgent batch
        $results = Start-FinOpsBatchCustomerOnboarding `
            -CustomerIdentifiers $urgentCustomers `
            -ConnectionString $connStr `
            -ThrottleLimit 4 `
            -SkipEmissions
    
    .OUTPUTS
        PSCustomObject with properties:
        - ProcessingMode: 'Parallel' or 'Sequential'
        - PowerShellVersion: Version used
        - CustomerCount: Total customers processed
        - SuccessCount: Successful onboardings
        - FailureCount: Failed onboardings
        - DurationSeconds: Total processing time
        - Results: Array of per-customer results
        - ConfigurationSources: Summary of DB vs Jira config usage
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$CustomerIdentifiers,

        [Parameter()]
        [ValidateRange(1, 4)]
        [int]$ThrottleLimit = 2,

        [Parameter()]
        [string]$ConnectionString,

        [Parameter()]
        [string]$JiraBaseUrl,

        [Parameter()]
        [string]$JiraUsername,

        [Parameter()]
        [SecureString]$JiraApiToken,

        [Parameter()]
        [switch]$UseAtlassianMcp,

        [Parameter()]
        [switch]$SkipReservations,

        [Parameter()]
        [switch]$SkipCosts,

        [Parameter()]
        [switch]$SkipEmissions,

        [Parameter()]
        [ValidateSet('Json', 'Markdown', 'Html', 'Excel', 'Both', 'None')]
        [string]$ReportFormat = 'Json',

        [Parameter()]
        [string]$OutputDirectory,

        [Parameter()]
        [switch]$PublishToJira,

        [Parameter()]
        [string]$JiraTransitionStatus,

        [Parameter()]
        [ValidateRange(1, 10)]
        [int]$MaxRetries = 3,

        [Parameter()]
        [switch]$ShowProgress
    )

    begin {
        $startTime = Get-Date
        $psVersion = $PSVersionTable.PSVersion
        $useParallel = $psVersion.Major -ge 7
        
        Write-Verbose "Starting batch customer onboarding"
        Write-Verbose "Customer count: $($CustomerIdentifiers.Count)"
        Write-Verbose "Throttle limit: $ThrottleLimit"
        Write-Verbose "PowerShell version: $psVersion"
        Write-Verbose "Processing mode: $(if ($useParallel) { 'Parallel' } else { 'Sequential' })"
        
        # Warn if throttle limit exceeds soft recommendation
        if ($ThrottleLimit -gt 2) {
            Write-Warning "ThrottleLimit set to $ThrottleLimit (above soft limit of 2). Monitor API rate limits carefully."
        }

        # Validate Jira parameters if fallback needed
        $jiraConfigured = $JiraBaseUrl -and $JiraUsername -and $JiraApiToken
        if (-not $ConnectionString -and -not $jiraConfigured) {
            throw "Either ConnectionString or complete Jira configuration (BaseUrl, Username, ApiToken) must be provided."
        }

        # Initialize counters
        $script:configSourceStats = @{
            Database = 0
            JiraFallback = 0
            Failed = 0
        }
    }

    process {
        if ($PSCmdlet.ShouldProcess("$($CustomerIdentifiers.Count) customers", "Execute batch onboarding")) {
            
            # Build common parameters for all customers
            $commonParams = @{
                SkipReservations = $SkipReservations
                SkipCosts = $SkipCosts
                SkipEmissions = $SkipEmissions
                ReportFormat = $ReportFormat
                PublishToJira = $PublishToJira
            }
            
            if ($OutputDirectory) { $commonParams.OutputDirectory = $OutputDirectory }
            if ($JiraTransitionStatus) { $commonParams.JiraTransitionStatus = $JiraTransitionStatus }
            if ($JiraBaseUrl) { $commonParams.JiraBaseUrl = $JiraBaseUrl }
            if ($JiraUsername) { $commonParams.JiraUsername = $JiraUsername }
            if ($JiraApiToken) { $commonParams.JiraApiToken = $JiraApiToken }
            if ($UseAtlassianMcp) { $commonParams.UseJiraMcp = $true }

            # Process customers
            if ($useParallel) {
                Write-Verbose "Using parallel processing with ThrottleLimit=$ThrottleLimit"
                
                $results = $CustomerIdentifiers | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
                    $identifier = $_
                    $connStr = $using:ConnectionString
                    $jiraBaseUrl = $using:JiraBaseUrl
                    $jiraUsername = $using:JiraUsername
                    $jiraApiToken = $using:JiraApiToken
                    $useJiraMcp = $using:UseAtlassianMcp
                    $commonParams = $using:commonParams
                    
                    $customerResult = [PSCustomObject]@{
                        Identifier = $identifier
                        ConfigSource = $null
                        Success = $false
                        Error = $null
                        OnboardingResult = $null
                        DurationSeconds = 0
                    }
                    
                    $customerStart = Get-Date
                    
                    try {
                        # Try database first
                        $config = $null
                        if ($connStr) {
                            try {
                                $config = Get-FinOpsAzCustomerAppCredential -CustomerName $identifier -ConnectionString $connStr -ErrorAction SilentlyContinue
                                if ($config) {
                                    $customerResult.ConfigSource = 'Database'
                                    Write-Verbose "[${identifier}] Configuration loaded from database"
                                }
                            }
                            catch {
                                Write-Verbose "[${identifier}] Database lookup failed: $($_.Exception.Message)"
                            }
                        }
                        
                        # Fallback to Jira if DB didn't return config
                        if (-not $config -and $jiraBaseUrl) {
                            Write-Warning "[${identifier}] Database configuration not found. Falling back to Jira issue: $identifier"
                            $config = Get-FinOpsOnboardingFromJiraIssue -IssueKey $identifier `
                                -BaseUrl $jiraBaseUrl -Username $jiraUsername -ApiToken $jiraApiToken `
                                -UseAtlassianMcp:$useJiraMcp
                            
                            if ($config) {
                                $customerResult.ConfigSource = 'JiraFallback'
                                Write-Warning "[${identifier}] Using Jira configuration. Consider populating database for this customer."
                            }
                        }
                        
                        if (-not $config) {
                            throw "No configuration found in database or Jira for identifier: $identifier"
                        }
                        
                        # Build onboarding parameters
                        $onboardingParams = $commonParams.Clone()
                        $onboardingParams.TenantId = $config.TenantId
                        $onboardingParams.ApplicationId = $config.ApplicationId
                        $onboardingParams.ClientSecret = $config.ClientSecret  # Should be SecureString
                        $onboardingParams.CustomerName = $config.CustomerName
                        $onboardingParams.PrimaryDomain = $config.PrimaryDomain
                        
                        if ($config.Country) { $onboardingParams.Country = $config.Country }
                        if ($config.CompanyName) { $onboardingParams.CompanyName = $config.CompanyName }
                        if ($config.TenantName) { $onboardingParams.TenantName = $config.TenantName }
                        if ($config.IsEA) { $onboardingParams.IsEA = $config.IsEA }
                        if ($config.IssueKey) { $onboardingParams.JiraIssueKey = $config.IssueKey }
                        
                        # Execute onboarding
                        $onboardingResult = Invoke-FinOpsOnboarding @onboardingParams -PassThru -ErrorAction Stop
                        
                        $customerResult.Success = $true
                        $customerResult.OnboardingResult = $onboardingResult
                    }
                    catch {
                        $customerResult.Success = $false
                        $customerResult.Error = $_.Exception.Message
                        Write-Error "[${identifier}] Onboarding failed: $($_.Exception.Message)"
                    }
                    finally {
                        $customerResult.DurationSeconds = (Get-Date).Subtract($customerStart).TotalSeconds
                    }
                    
                    $customerResult
                }
            }
            else {
                # Sequential processing (PowerShell 5.1 fallback)
                Write-Verbose "Using sequential processing (PowerShell version < 7)"
                
                $results = @()
                $current = 0
                
                foreach ($identifier in $CustomerIdentifiers) {
                    $current++
                    
                    if ($ShowProgress) {
                        Write-Progress -Activity "Batch Customer Onboarding" `
                            -Status "Processing $identifier ($current of $($CustomerIdentifiers.Count))" `
                            -PercentComplete (($current / $CustomerIdentifiers.Count) * 100)
                    }
                    
                    $customerResult = [PSCustomObject]@{
                        Identifier = $identifier
                        ConfigSource = $null
                        Success = $false
                        Error = $null
                        OnboardingResult = $null
                        DurationSeconds = 0
                    }
                    
                    $customerStart = Get-Date
                    
                    try {
                        # Try database first
                        $config = $null
                        if ($ConnectionString) {
                            try {
                                $config = Get-FinOpsAzCustomerAppCredential -CustomerName $identifier -ConnectionString $ConnectionString -ErrorAction SilentlyContinue
                                if ($config) {
                                    $customerResult.ConfigSource = 'Database'
                                    $script:configSourceStats.Database++
                                    Write-Verbose "[$identifier] Configuration loaded from database"
                                }
                            }
                            catch {
                                Write-Verbose "[$identifier] Database lookup failed: $($_.Exception.Message)"
                            }
                        }
                        
                        # Fallback to Jira
                        if (-not $config -and $jiraConfigured) {
                            Write-Warning "[$identifier] Database configuration not found. Falling back to Jira issue: $identifier"
                            $config = Get-FinOpsOnboardingFromJiraIssue -IssueKey $identifier `
                                -BaseUrl $JiraBaseUrl -Username $JiraUsername -ApiToken $JiraApiToken `
                                -UseAtlassianMcp:$UseAtlassianMcp
                            
                            if ($config) {
                                $customerResult.ConfigSource = 'JiraFallback'
                                $script:configSourceStats.JiraFallback++
                                Write-Warning "[$identifier] Using Jira configuration. Consider populating database for this customer."
                            }
                        }
                        
                        if (-not $config) {
                            $script:configSourceStats.Failed++
                            throw "No configuration found in database or Jira for identifier: $identifier"
                        }
                        
                        # Build onboarding parameters
                        $onboardingParams = $commonParams.Clone()
                        $onboardingParams.TenantId = $config.TenantId
                        $onboardingParams.ApplicationId = $config.ApplicationId
                        $onboardingParams.ClientSecret = $config.ClientSecret
                        $onboardingParams.CustomerName = $config.CustomerName
                        $onboardingParams.PrimaryDomain = $config.PrimaryDomain
                        
                        if ($config.Country) { $onboardingParams.Country = $config.Country }
                        if ($config.CompanyName) { $onboardingParams.CompanyName = $config.CompanyName }
                        if ($config.TenantName) { $onboardingParams.TenantName = $config.TenantName }
                        if ($config.IsEA) { $onboardingParams.IsEA = $config.IsEA }
                        if ($config.IssueKey) { $onboardingParams.JiraIssueKey = $config.IssueKey }
                        
                        # Execute onboarding
                        $onboardingResult = Invoke-FinOpsOnboarding @onboardingParams -PassThru -ErrorAction Stop
                        
                        $customerResult.Success = $true
                        $customerResult.OnboardingResult = $onboardingResult
                    }
                    catch {
                        $customerResult.Success = $false
                        $customerResult.Error = $_.Exception.Message
                        Write-Error "[$identifier] Onboarding failed: $($_.Exception.Message)"
                    }
                    finally {
                        $customerResult.DurationSeconds = (Get-Date).Subtract($customerStart).TotalSeconds
                    }
                    
                    $results += $customerResult
                }
                
                if ($ShowProgress) {
                    Write-Progress -Activity "Batch Customer Onboarding" -Completed
                }
            }
            
            # Calculate statistics
            $endTime = Get-Date
            $duration = $endTime.Subtract($startTime).TotalSeconds
            
            $successCount = ($results | Where-Object { $_.Success }).Count
            $failureCount = ($results | Where-Object { -not $_.Success }).Count
            
            # Build summary
            $summary = [PSCustomObject]@{
                ProcessingMode = if ($useParallel) { 'Parallel' } else { 'Sequential' }
                PowerShellVersion = $psVersion.ToString()
                ThrottleLimit = $ThrottleLimit
                CustomerCount = $CustomerIdentifiers.Count
                SuccessCount = $successCount
                FailureCount = $failureCount
                DurationSeconds = [Math]::Round($duration, 2)
                Results = $results
                ConfigurationSources = [PSCustomObject]@{
                    Database = ($results | Where-Object { $_.ConfigSource -eq 'Database' }).Count
                    JiraFallback = ($results | Where-Object { $_.ConfigSource -eq 'JiraFallback' }).Count
                    Failed = ($results | Where-Object { -not $_.ConfigSource }).Count
                }
            }
            
            # Output summary
            Write-Host "`n=== Batch Customer Onboarding Summary ===" -ForegroundColor Cyan
            Write-Host "Total customers: $($summary.CustomerCount)"
            Write-Host "Successful: $($summary.SuccessCount)" -ForegroundColor Green
            Write-Host "Failed: $($summary.FailureCount)" -ForegroundColor $(if ($summary.FailureCount -gt 0) { 'Red' } else { 'Green' })
            Write-Host "Duration: $($summary.DurationSeconds) seconds"
            Write-Host "Processing mode: $($summary.ProcessingMode)"
            Write-Host "`nConfiguration sources:"
            Write-Host "  Database: $($summary.ConfigurationSources.Database)"
            Write-Host "  Jira fallback: $($summary.ConfigurationSources.JiraFallback)" -ForegroundColor $(if ($summary.ConfigurationSources.JiraFallback -gt 0) { 'Yellow' } else { 'White' })
            Write-Host "  Failed to load: $($summary.ConfigurationSources.Failed)" -ForegroundColor $(if ($summary.ConfigurationSources.Failed -gt 0) { 'Red' } else { 'White' })
            
            return $summary
        }
    }
}
