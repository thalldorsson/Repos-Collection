function Invoke-FinOpsOnboarding {
    [CmdletBinding()]
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
        [switch]$PassThru
    )

    Write-Verbose "=== Starting Azure FinOps Onboarding ==="
    Write-Verbose "Customer: $CustomerName"
    Write-Verbose "Primary Domain: $PrimaryDomain"
    Write-Verbose "Tenant ID: $TenantId"
    Write-Verbose "Application ID: $ApplicationId"
    Write-Verbose "EA Mode: $IsEA"
    
    # Calculate total steps for progress
    $totalSteps = 5  # Auth, Subscriptions, Billing (if EA), Reservations, Costs, Emissions
    if (-not $IsEA) { $totalSteps-- }
    if ($SkipReservations) { $totalSteps-- }
    if ($SkipCosts) { $totalSteps-- }
    if ($SkipEmissions) { $totalSteps-- }
    
    $currentStep = 0
    
    # Step 1: Acquire token
    $currentStep++
    Write-Progress -Activity "Azure FinOps Onboarding: $CustomerName" -Status "Authenticating..." -PercentComplete (($currentStep / $totalSteps) * 100)
    Write-Verbose "[$currentStep/$totalSteps] Acquiring bearer token for tenant: $TenantId"
    $token = Get-FinOpsBearerToken -TenantId $TenantId -ApplicationId $ApplicationId -ClientSecret $ClientSecret
    Write-Verbose "Authentication successful"

    # Step 2: Subscriptions
    $currentStep++
    Write-Progress -Activity "Azure FinOps Onboarding: $CustomerName" -Status "Checking subscriptions..." -PercentComplete (($currentStep / $totalSteps) * 100)
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
        Write-Progress -Activity "Azure FinOps Onboarding: $CustomerName" -Status "Checking billing accounts..." -PercentComplete (($currentStep / $totalSteps) * 100)
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
        Write-Progress -Activity "Azure FinOps Onboarding: $CustomerName" -Status "Checking reservations..." -PercentComplete (($currentStep / $totalSteps) * 100)
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
        Write-Progress -Activity "Azure FinOps Onboarding: $CustomerName" -Status "Analyzing costs..." -PercentComplete (($currentStep / $totalSteps) * 100)
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
        Write-Progress -Activity "Azure FinOps Onboarding: $CustomerName" -Status "Checking emissions data..." -PercentComplete (($currentStep / $totalSteps) * 100)
        Write-Verbose "[$currentStep/$totalSteps] Testing emissions data access"
        $emissionsResult = Test-FinOpsAzEmissions -Token $token -SubscriptionIds $subscriptionIds[0]
        Write-Verbose "Emissions check completed: Success=$($emissionsResult.Success)"
    } else {
        Write-Verbose "Cannot check emissions: No subscriptions available"
        $emissionsResult = New-FinOpsCheckResult -Name 'Emissions' -Success $false -ErrorDetail 'No subscriptions available'
    }
    
    Write-Progress -Activity "Azure FinOps Onboarding: $CustomerName" -Completed

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

    if ($PassThru) {
        $orchestrator | Add-Member -NotePropertyName GeneratedFiles -NotePropertyValue $written -Force
        return $orchestrator
    }
}
