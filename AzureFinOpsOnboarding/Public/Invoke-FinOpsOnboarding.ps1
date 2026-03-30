<#
.SYNOPSIS
Executes comprehensive Azure FinOps onboarding validation and reporting.

.DESCRIPTION
Validates Azure infrastructure, billing, reservations, costs, and emissions for a customer tenant.
Generates HTML/Markdown reports and optionally integrates with Jira for issue management.
Supports EA (Enterprise Agreement) billing, managed identity authentication, and comprehensive cost analysis.

.PARAMETER TenantId
The Azure tenant ID (GUID) for the customer.

.PARAMETER ApplicationId
The service principal application ID for authentication.

.PARAMETER ClientSecret
The secure client secret for the service principal.

.PARAMETER CustomerName
The name of the customer organization.

.PARAMETER PrimaryDomain
The primary domain for the customer (e.g., contoso.com).

.PARAMETER CompanyName
Optional company name override.

.PARAMETER Country
Optional customer country/region.

.PARAMETER TenantName
Optional display name for the tenant.

.PARAMETER IsEA
Indicates if the customer uses Enterprise Agreement (EA) billing.

.PARAMETER SkipReservations
Skip Azure Reservations validation.

.PARAMETER SkipCosts
Skip cost analysis and recommendations.

.PARAMETER SkipEmissions
Skip carbon emissions calculation.

.PARAMETER ReportFormat
Output format: 'Json', 'Markdown', 'Both', or 'None'. Default is 'Both'.

.PARAMETER OutputDirectory
Directory for report output. Default is './Output'.

.PARAMETER CostLookbackStartDays
Number of days back to start cost analysis (default: 60).

.PARAMETER CostLookbackEndDays
Number of days back to end cost analysis (default: 30).

.PARAMETER JiraIssueKey
Optional Jira issue key to update with results.

.PARAMETER JiraUsername
Optional Jira username for authentication.

.PARAMETER JiraApiToken
Optional Jira API token (SecureString).

.PARAMETER JiraBaseUrl
Optional Jira base URL (overrides default from config).

.PARAMETER JiraTransitionStatus
Optional status to transition Jira issue to after completion.

.PARAMETER PublishToJira
Publish results to Jira issue.

.PARAMETER UseJiraMcp
Use Jira MCP (Model Context Protocol) delegates for issue updates.

.PARAMETER ProgressParentId
Parent progress activity ID for nested progress tracking.

.PARAMETER PassThru
Return the results object to the pipeline.

.EXAMPLE
# Basic onboarding
Invoke-FinOpsOnboarding `
    -TenantId "00000000-0000-0000-0000-000000000000" `
    -ApplicationId "app-id-guid" `
    -ClientSecret (ConvertTo-SecureString "secret" -AsPlainText -Force) `
    -CustomerName "Contoso" `
    -PrimaryDomain "contoso.com" `
    -IsEA

.EXAMPLE
# With Jira integration
Invoke-FinOpsOnboarding `
    -TenantId $tenantId `
    -ApplicationId $appId `
    -ClientSecret $secret `
    -CustomerName "Fabrikam" `
    -PrimaryDomain "fabrikam.com" `
    -JiraIssueKey "FOP-123" `
    -JiraUsername "user@example.com" `
    -JiraApiToken $jiraToken `
    -PublishToJira

.OUTPUTS
PSCustomObject with onboarding results (when -PassThru is used).

.NOTES
Requires Azure PowerShell (Az) module and appropriate permissions.
Configuration can be loaded from config.json in module root.

.LINK
https://github.com/thorsteinnhalldors/AzureFinOpsOnboarding

.LINK
Connect-FinOpsAzure

#>
function Invoke-FinOpsOnboarding {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ApplicationId,
        [Parameter(Mandatory)][SecureString]$ClientSecret,
        [Parameter(Mandatory)][string]$CustomerName,
        [Parameter(Mandatory)][string]$PrimaryDomain,
        [string]$CompanyName,
        [string]$Country,
        [string]$TenantName,
        [switch]$IsEA,
        [switch]$SkipReservations,
        [switch]$SkipCosts,
        [switch]$SkipEmissions,
        [ValidateSet('Json', 'Markdown', 'Both', 'None')][string]$ReportFormat = 'Both',
        [string]$OutputDirectory = (Join-Path $PSScriptRoot '..' | Join-Path -ChildPath 'Output'),
        [int]$CostLookbackStartDays = 60,
        [int]$CostLookbackEndDays = 30,
        [string]$JiraIssueKey,
        [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')][string]$JiraUsername,
        [SecureString]$JiraApiToken,
        [string]$JiraBaseUrl,
        [string]$JiraTransitionStatus,
        [switch]$PublishToJira,
        [switch]$UseJiraMcp,
        [int]$ProgressParentId = -1,
        [switch]$PassThru
    )

    # Confirm operation with user if needed
    if (-not $PSCmdlet.ShouldProcess("Customer: $CustomerName (Tenant: $TenantId)", "Execute FinOps onboarding validation")) {
        Write-Verbose "Operation cancelled by user"
        return
    }

    Write-Verbose "=== Starting Azure FinOps Onboarding ==="
    Write-Verbose "Customer: $CustomerName"
    Write-Verbose "Primary Domain: $PrimaryDomain"
    Write-Verbose "Tenant ID: $TenantId"
    Write-Verbose "Application ID: $ApplicationId"
    Write-Verbose "EA Mode: $IsEA"
    
    # Calculate total steps for progress (8 milestones: Auth, Subs, Billing, Reservations, Costs, Emissions, Reports, Jira)
    $totalSteps = 8
    if (-not $IsEA) { $totalSteps-- }
    if ($SkipReservations) { $totalSteps-- }
    if ($SkipCosts) { $totalSteps-- }
    if ($SkipEmissions) { $totalSteps-- }
    if (-not $PublishToJira -or -not $JiraIssueKey) { $totalSteps-- }
    
    $currentStep = 0
    $progressId = if ($ProgressParentId -ge 0) { $ProgressParentId + 100 } else { 1 }
    $progressParams = @{
        Id = $progressId
        Activity = "Azure FinOps Onboarding: $CustomerName"
    }
    if ($ProgressParentId -ge 0) {
        $progressParams.ParentId = $ProgressParentId
    }
    
    # Step 1: Acquire token
    $currentStep++
    Write-Progress @progressParams -Status "Step $currentStep/$totalSteps : Authenticating..." -PercentComplete (($currentStep / $totalSteps) * 100)
    Write-Verbose "[$currentStep/$totalSteps] Acquiring bearer token for tenant: $TenantId"
    $token = Get-FinOpsBearerToken -TenantId $TenantId -ApplicationId $ApplicationId -ClientSecret $ClientSecret
    Write-Verbose "Authentication successful"

    # Step 2: Subscriptions
    $currentStep++
    Write-Progress @progressParams -Status "Step $currentStep/$totalSteps : Checking subscriptions..." -PercentComplete (($currentStep / $totalSteps) * 100)
    Write-Verbose "[$currentStep/$totalSteps] Testing subscription access"
    $subResult = Test-FinOpsAzSubscriptions -Token $token -IncludeData
    $subscriptionIds = @()
    if ($subResult.Success -and $subResult.Data) { 
        $subscriptionIds = $subResult.Data.subscriptionId
        Write-Verbose "Found $($subscriptionIds.Count) subscription(s)"
    } else {
        Write-Verbose "Subscription check failed: $($subResult.Error)"
    }

    # Step 3: Billing accounts (if EA flag)
    $billingResult = $null
    $enrollmentId = '0'
    $mcaBillingId = '0'
    if ($IsEA) {
        $currentStep++
        Write-Progress @progressParams -Status "Step $currentStep/$totalSteps : Checking billing accounts..." -PercentComplete (($currentStep / $totalSteps) * 100)
        Write-Verbose "[$currentStep/$totalSteps] Testing EA/MCA billing account access"
        $billingResult = Test-FinOpsAzBillingAccounts -Token $token -IncludeData
        if ($billingResult.Success -and $billingResult.Data) {
            # Heuristic: name with colon indicates MCA
            $first = $billingResult.Data | Select-Object -First 1
            if ($first.name -like '*:*') { 
                $mcaBillingId = $first.name
                Write-Verbose "Detected MCA billing account: $mcaBillingId"
            } else { 
                $enrollmentId = $first.name
                Write-Verbose "Detected EA enrollment ID: $enrollmentId"
            }
        } else {
            Write-Verbose "Billing account check failed: $($billingResult.Error)"
        }
    }

    # Step 4: Reservations
    if (-not $SkipReservations) {
        $currentStep++
        Write-Progress @progressParams -Status "Step $currentStep/$totalSteps : Checking reservations..." -PercentComplete (($currentStep / $totalSteps) * 100)
        Write-Verbose "[$currentStep/$totalSteps] Testing reservation access"
        $reservationResult = Test-FinOpsAzReservations -Token $token
        Write-Verbose "Reservation check completed: Success=$($reservationResult.Success)"
    } else {
        Write-Verbose "Skipping reservation check (per request)"
        $reservationResult = New-FinOpsCheckResult -Name 'Reservations' -Success $true -ErrorDetail 'Skipped'
    }

    # Step 5: Costs (use first subscription if available)
    $costResult = $null
    if ($SkipCosts) {
        Write-Verbose "Skipping cost check (per request)"
        $costResult = New-FinOpsCheckResult -Name 'Costs' -Success $true -ErrorDetail 'Skipped'
    } elseif ($subscriptionIds.Count -gt 0) {
        $currentStep++
        Write-Progress @progressParams -Status "Step $currentStep/$totalSteps : Analyzing costs..." -PercentComplete (($currentStep / $totalSteps) * 100)
        $window = Get-FinOpsCostDateWindow -StartOffsetDays $CostLookbackStartDays -EndOffsetDays $CostLookbackEndDays
        Write-Verbose "[$currentStep/$totalSteps] Testing cost data access (subscription: $($subscriptionIds[0]))"
        Write-Verbose "Cost window: $($window.Start) to $($window.End)"
        $costResult = Test-FinOpsAzCosts -Token $token -SubscriptionId $subscriptionIds[0] -StartDate $window.Start -EndDate $window.End
        Write-Verbose "Cost check completed: Success=$($costResult.Success)"
    } else {
        Write-Verbose "Cannot check costs: No subscriptions available"
        $costResult = New-FinOpsCheckResult -Name 'Costs' -Success $false -ErrorDetail 'No subscriptions available for cost query'
    }

    # Step 6: Emissions
    if ($SkipEmissions) {
        Write-Verbose "Skipping emissions check (per request)"
        $emissionsResult = New-FinOpsCheckResult -Name 'Emissions' -Success $true -ErrorDetail 'Skipped'
    } elseif ($subscriptionIds.Count -gt 0) {
        $currentStep++
        Write-Progress @progressParams -Status "Step $currentStep/$totalSteps : Checking emissions data..." -PercentComplete (($currentStep / $totalSteps) * 100)
        Write-Verbose "[$currentStep/$totalSteps] Testing emissions data access"
        $emissionsResult = Test-FinOpsAzEmissions -Token $token -SubscriptionIds $subscriptionIds[0]
        Write-Verbose "Emissions check completed: Success=$($emissionsResult.Success)"
    } else {
        Write-Verbose "Cannot check emissions: No subscriptions available"
        $emissionsResult = New-FinOpsCheckResult -Name 'Emissions' -Success $false -ErrorDetail 'No subscriptions available'
    }
    
    # Step 7: Generate reports
    $currentStep++
    Write-Progress @progressParams -Status "Step $currentStep/$totalSteps : Generating reports..." -PercentComplete (($currentStep / $totalSteps) * 100)
    Write-Verbose "[$currentStep/$totalSteps] Preparing onboarding results"

    $secretName = ($CustomerName -replace '\W', '') + 'ACCSecret'
    $secretExpiry = Get-FinOpsSecretExpiryKey

    $checks = @($subResult)
    if ($billingResult) { $checks += $billingResult }
    $checks += @($reservationResult, $costResult, $emissionsResult)

    $orchestrator = [pscustomobject]@{
        SchemaVersion = '1.0'
        GeneratedAt = (Get-Date).ToUniversalTime().ToString('o')
        ToolVersion = '0.1.0'
        Customer = [pscustomobject]@{
            Name = $CustomerName
            PrimaryDomain = $PrimaryDomain
            TenantId = $TenantId
            ApplicationId = $ApplicationId
            IsEA = [bool]$IsEA
            CompanyName = $CompanyName
            Country = $Country
            TenantName = $TenantName
        }
        Identifiers = [pscustomobject]@{
            EnrollmentId = $enrollmentId
            MCABillingId = $mcaBillingId
            SecretName = $secretName
            SecretExpiry = $secretExpiry
        }
        Checks = $checks
    }

    $paths = Resolve-FinOpsOutputPath -BaseDirectory $OutputDirectory -CustomerName $CustomerName
    $written = @()
    switch ($ReportFormat) {
        'Json' { $written += Write-FinOpsManifest -Path $paths.Json -OrchestratorObject $orchestrator }
        'Markdown' { $written += Write-FinOpsReport -Path $paths.Markdown -OrchestratorObject $orchestrator }
        'Both' { 
            $written += Write-FinOpsManifest -Path $paths.Json -OrchestratorObject $orchestrator
            $written += Write-FinOpsReport -Path $paths.Markdown -OrchestratorObject $orchestrator
        }
        'None' { }
    }

    # Publish to Jira if requested
    if ($PublishToJira -and $JiraIssueKey) {
        $currentStep++
        Write-Progress @progressParams -Status "Step $currentStep/$totalSteps : Publishing to Jira..." -PercentComplete (($currentStep / $totalSteps) * 100)
        Write-Verbose "[$currentStep/$totalSteps] Publishing onboarding results to Jira issue: $JiraIssueKey"
        try {
            $jiraParams = @{
                OrchestratorObject = $orchestrator
                IssueKey = $JiraIssueKey
            }
            if ($JiraBaseUrl) { $jiraParams.BaseUrl = $JiraBaseUrl }
            if ($JiraUsername) { $jiraParams.Username = $JiraUsername }
            if ($JiraApiToken) { $jiraParams.ApiToken = $JiraApiToken }
            if ($JiraTransitionStatus) { $jiraParams.TransitionToStatus = $JiraTransitionStatus }
            if ($UseJiraMcp) { $jiraParams.UseAtlassianMcp = $true }
            
            Publish-FinOpsOnboardingToJira @jiraParams
            Write-Verbose "Jira issue updated successfully"
        }
        catch {
            Write-Warning "Failed to publish to Jira: $_"
            if (-not $PassThru) { throw }
        }
    }
    elseif ($PublishToJira -and -not $JiraIssueKey) {
        Write-Warning "PublishToJira specified but JiraIssueKey is empty"
    }
    
    # Complete progress
    Write-Progress @progressParams -Completed

    if ($PassThru) {
        $orchestrator | Add-Member -NotePropertyName GeneratedFiles -NotePropertyValue $written -Force
        return $orchestrator
    }
}
