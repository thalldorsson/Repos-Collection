function Resume-FinOpsOnboarding {
    <#
    .SYNOPSIS
        Resumes a prior onboarding by performing a full rerun.
    
    .DESCRIPTION
        Executes a complete onboarding rerun (not selective retry) while preserving
        metadata from the prior attempt. Logs that this is a resume operation and
        appends resume metadata to the result object showing the original attempt timestamp.
        
        This is useful for scenarios where onboarding partially succeeded and you want
        to rerun all checks while maintaining audit trail of the original attempt.
    
    .PARAMETER PriorResult
        The orchestrator result object from a previous Invoke-FinOpsOnboarding execution.
    
    .PARAMETER TenantId
        Azure AD tenant ID (GUID). Can be inferred from PriorResult if present.
    
    .PARAMETER ApplicationId
        Service principal application (client) ID. Can be inferred from PriorResult if present.
    
    .PARAMETER ClientSecret
        Service principal client secret as SecureString.
    
    .PARAMETER CustomerName
        Customer name. Can be inferred from PriorResult if present.
    
    .PARAMETER PrimaryDomain
        Primary domain. Can be inferred from PriorResult if present.
    
    .PARAMETER CompanyName
        Optional company name. Can be inferred from PriorResult if present.
    
    .PARAMETER Country
        Optional country. Can be inferred from PriorResult if present.
    
    .PARAMETER TenantName
        Optional tenant name. Can be inferred from PriorResult if present.
    
    .PARAMETER IsEA
        Enterprise Agreement flag. Can be inferred from PriorResult if present.
    
    .PARAMETER SkipReservations
        Skip reservation checks. Can be inferred from PriorResult if present.
    
    .PARAMETER SkipCosts
        Skip cost checks. Can be inferred from PriorResult if present.
    
    .PARAMETER SkipEmissions
        Skip emissions checks. Can be inferred from PriorResult if present.
    
    .PARAMETER ReportFormat
        Report format. Can be inferred from PriorResult if present.
    
    .PARAMETER OutputDirectory
        Output directory path. Can be inferred from PriorResult if present.
    
    .PARAMETER CostLookbackStartDays
        Cost lookback start days. Can be inferred from PriorResult if present.
    
    .PARAMETER CostLookbackEndDays
        Cost lookback end days. Can be inferred from PriorResult if present.
    
    .PARAMETER JiraIssueKey
        Jira issue key. Can be inferred from PriorResult if present.
    
    .PARAMETER JiraUsername
        Jira username. Can be inferred from PriorResult if present.
    
    .PARAMETER JiraApiToken
        Jira API token as SecureString.
    
    .PARAMETER JiraBaseUrl
        Jira base URL. Can be inferred from PriorResult if present.
    
    .PARAMETER JiraTransitionStatus
        Jira transition status. Can be inferred from PriorResult if present.
    
    .PARAMETER PublishToJira
        Publish to Jira. Can be inferred from PriorResult if present.
    
    .PARAMETER UseJiraMcp
        Use Jira MCP. Can be inferred from PriorResult if present.
    
    .PARAMETER PassThru
        Return the orchestrator result object.
    
    .EXAMPLE
        $result = Invoke-FinOpsOnboarding -TenantId $tid -CustomerName "Contoso" ...
        # Some checks failed, resume with same parameters
        $resumedResult = Resume-FinOpsOnboarding -PriorResult $result -ClientSecret $secret
    
    .EXAMPLE
        # Resume with updated parameters
        Resume-FinOpsOnboarding -PriorResult $result `
            -ClientSecret $secret `
            -SkipEmissions `
            -PassThru
    
    .OUTPUTS
        PSCustomObject with orchestrator result including ResumeMeta property.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [PSCustomObject]$PriorResult,
        
        [Parameter()]
        [string]$TenantId,
        
        [Parameter()]
        [string]$ApplicationId,
        
        [Parameter(Mandatory)]
        [SecureString]$ClientSecret,
        
        [Parameter()]
        [string]$CustomerName,
        
        [Parameter()]
        [string]$PrimaryDomain,
        
        [Parameter()]
        [string]$CompanyName,
        
        [Parameter()]
        [string]$Country,
        
        [Parameter()]
        [string]$TenantName,
        
        [Parameter()]
        [switch]$IsEA,
        
        [Parameter()]
        [switch]$SkipReservations,
        
        [Parameter()]
        [switch]$SkipCosts,
        
        [Parameter()]
        [switch]$SkipEmissions,
        
        [Parameter()]
        [ValidateSet('Json', 'Markdown', 'Both', 'None')]
        [string]$ReportFormat,
        
        [Parameter()]
        [string]$OutputDirectory,
        
        [Parameter()]
        [int]$CostLookbackStartDays,
        
        [Parameter()]
        [int]$CostLookbackEndDays,
        
        [Parameter()]
        [string]$JiraIssueKey,
        
        [Parameter()]
        [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
        [string]$JiraUsername,
        
        [Parameter()]
        [SecureString]$JiraApiToken,
        
        [Parameter()]
        [string]$JiraBaseUrl,
        
        [Parameter()]
        [string]$JiraTransitionStatus,
        
        [Parameter()]
        [switch]$PublishToJira,
        
        [Parameter()]
        [switch]$UseJiraMcp,
        
        [Parameter()]
        [switch]$PassThru
    )
    
    try {
        Write-Verbose "=== Resume Azure FinOps Onboarding ==="
        
        # Validate PriorResult structure
        if (-not $PriorResult.CustomerName) {
            throw "Invalid PriorResult: Missing CustomerName property. Ensure this is an orchestrator result from Invoke-FinOpsOnboarding."
        }
        
        # Build resume metadata
        $resumeMeta = [PSCustomObject]@{
            OriginalAttemptTimestamp = if ($PriorResult.Timestamp) { $PriorResult.Timestamp } else { [DateTime]::MinValue }
            OriginalExecutionId      = if ($PriorResult.ExecutionId) { $PriorResult.ExecutionId } else { [Guid]::Empty }
            ResumeTimestamp          = Get-Date
            ResumeExecutionId        = [Guid]::NewGuid()
            ResumeReason             = 'Full rerun requested via Resume-FinOpsOnboarding'
            OriginalCheckCount       = $PriorResult.CheckResults.Count
            OriginalPassedCount      = ($PriorResult.CheckResults | Where-Object { $_.Success }).Count
            OriginalFailedCount      = ($PriorResult.CheckResults | Where-Object { -not $_.Success }).Count
        }
        
        Write-Host "`n=== Resuming Onboarding ===" -ForegroundColor Cyan
        Write-Host "Original Attempt: " -NoNewline
        Write-Host $(if($resumeMeta.OriginalAttemptTimestamp -ne [DateTime]::MinValue){$resumeMeta.OriginalAttemptTimestamp.ToString('yyyy-MM-dd HH:mm:ss')}else{'Unknown'}) -ForegroundColor Yellow
        Write-Host "Customer: " -NoNewline
        Write-Host $PriorResult.CustomerName -ForegroundColor Green
        Write-Host "Original Results: " -NoNewline
        Write-Host "$($resumeMeta.OriginalPassedCount)/$($resumeMeta.OriginalCheckCount) passed" -ForegroundColor $(if($resumeMeta.OriginalFailedCount -eq 0){'Green'}else{'Yellow'})
        Write-Host "`nThis is a FULL RERUN (not selective retry)`n" -ForegroundColor Yellow
        
        # Infer parameters from PriorResult if not explicitly provided
        $invokeParams = @{
            ClientSecret = $ClientSecret
            PassThru     = $true
        }
        
        # Required parameters with fallback to PriorResult
        $invokeParams.TenantId = if ($TenantId) { $TenantId } else { $PriorResult.TenantId }
        $invokeParams.ApplicationId = if ($ApplicationId) { $ApplicationId } else { $PriorResult.ApplicationId }
        $invokeParams.CustomerName = if ($CustomerName) { $CustomerName } else { $PriorResult.CustomerName }
        $invokeParams.PrimaryDomain = if ($PrimaryDomain) { $PrimaryDomain } else { $PriorResult.PrimaryDomain }
        
        # Validate required parameters are available
        if (-not $invokeParams.TenantId) { throw "TenantId must be provided or present in PriorResult" }
        if (-not $invokeParams.ApplicationId) { throw "ApplicationId must be provided or present in PriorResult" }
        if (-not $invokeParams.CustomerName) { throw "CustomerName must be provided or present in PriorResult" }
        if (-not $invokeParams.PrimaryDomain) { throw "PrimaryDomain must be provided or present in PriorResult" }
        
        # Optional parameters with fallback
        if ($CompanyName) { $invokeParams.CompanyName = $CompanyName } elseif ($PriorResult.CompanyName) { $invokeParams.CompanyName = $PriorResult.CompanyName }
        if ($Country) { $invokeParams.Country = $Country } elseif ($PriorResult.Country) { $invokeParams.Country = $PriorResult.Country }
        if ($TenantName) { $invokeParams.TenantName = $TenantName } elseif ($PriorResult.TenantName) { $invokeParams.TenantName = $PriorResult.TenantName }
        
        # Switch parameters
        if ($PSBoundParameters.ContainsKey('IsEA')) { 
            if ($IsEA) { $invokeParams.IsEA = $true }
        } elseif ($PriorResult.IsEA) { 
            $invokeParams.IsEA = $true 
        }
        
        if ($PSBoundParameters.ContainsKey('SkipReservations')) { 
            if ($SkipReservations) { $invokeParams.SkipReservations = $true }
        } elseif ($PriorResult.SkipReservations) { 
            $invokeParams.SkipReservations = $true 
        }
        
        if ($PSBoundParameters.ContainsKey('SkipCosts')) { 
            if ($SkipCosts) { $invokeParams.SkipCosts = $true }
        } elseif ($PriorResult.SkipCosts) { 
            $invokeParams.SkipCosts = $true 
        }
        
        if ($PSBoundParameters.ContainsKey('SkipEmissions')) { 
            if ($SkipEmissions) { $invokeParams.SkipEmissions = $true }
        } elseif ($PriorResult.SkipEmissions) { 
            $invokeParams.SkipEmissions = $true 
        }
        
        if ($PSBoundParameters.ContainsKey('PublishToJira')) { 
            if ($PublishToJira) { $invokeParams.PublishToJira = $true }
        } elseif ($PriorResult.PublishToJira) { 
            $invokeParams.PublishToJira = $true 
        }
        
        if ($PSBoundParameters.ContainsKey('UseJiraMcp')) { 
            if ($UseJiraMcp) { $invokeParams.UseJiraMcp = $true }
        } elseif ($PriorResult.UseJiraMcp) { 
            $invokeParams.UseJiraMcp = $true 
        }
        
        # String parameters
        if ($ReportFormat) { $invokeParams.ReportFormat = $ReportFormat } elseif ($PriorResult.ReportFormat) { $invokeParams.ReportFormat = $PriorResult.ReportFormat }
        if ($OutputDirectory) { $invokeParams.OutputDirectory = $OutputDirectory } elseif ($PriorResult.OutputDirectory) { $invokeParams.OutputDirectory = $PriorResult.OutputDirectory }
        if ($JiraIssueKey) { $invokeParams.JiraIssueKey = $JiraIssueKey } elseif ($PriorResult.JiraIssueKey) { $invokeParams.JiraIssueKey = $PriorResult.JiraIssueKey }
        if ($JiraUsername) { $invokeParams.JiraUsername = $JiraUsername } elseif ($PriorResult.JiraUsername) { $invokeParams.JiraUsername = $PriorResult.JiraUsername }
        if ($JiraBaseUrl) { $invokeParams.JiraBaseUrl = $JiraBaseUrl } elseif ($PriorResult.JiraBaseUrl) { $invokeParams.JiraBaseUrl = $PriorResult.JiraBaseUrl }
        if ($JiraTransitionStatus) { $invokeParams.JiraTransitionStatus = $JiraTransitionStatus } elseif ($PriorResult.JiraTransitionStatus) { $invokeParams.JiraTransitionStatus = $PriorResult.JiraTransitionStatus }
        if ($JiraApiToken) { $invokeParams.JiraApiToken = $JiraApiToken }
        
        # Integer parameters
        if ($CostLookbackStartDays) { $invokeParams.CostLookbackStartDays = $CostLookbackStartDays } elseif ($PriorResult.CostLookbackStartDays) { $invokeParams.CostLookbackStartDays = $PriorResult.CostLookbackStartDays }
        if ($CostLookbackEndDays) { $invokeParams.CostLookbackEndDays = $CostLookbackEndDays } elseif ($PriorResult.CostLookbackEndDays) { $invokeParams.CostLookbackEndDays = $PriorResult.CostLookbackEndDays }
        
        # Log effective parameters
        Write-Verbose "Effective parameters for resume:"
        Write-Verbose "  TenantId: $($invokeParams.TenantId)"
        Write-Verbose "  ApplicationId: $($invokeParams.ApplicationId)"
        Write-Verbose "  CustomerName: $($invokeParams.CustomerName)"
        Write-Verbose "  IsEA: $(if($invokeParams.IsEA){'Yes'}else{'No'})"
        Write-Verbose "  SkipReservations: $(if($invokeParams.SkipReservations){'Yes'}else{'No'})"
        Write-Verbose "  SkipCosts: $(if($invokeParams.SkipCosts){'Yes'}else{'No'})"
        Write-Verbose "  SkipEmissions: $(if($invokeParams.SkipEmissions){'Yes'}else{'No'})"
        
        # Confirm operation
        if (-not $PSCmdlet.ShouldProcess("Customer: $($invokeParams.CustomerName)", "Resume FinOps onboarding (full rerun)")) {
            Write-Verbose "Operation cancelled by user"
            return
        }
        
        # Call Invoke-FinOpsOnboarding with all parameters
        Write-Verbose "Invoking Invoke-FinOpsOnboarding..."
        $newResult = Invoke-FinOpsOnboarding @invokeParams
        
        # Append resume metadata to result
        if ($newResult) {
            $newResult | Add-Member -MemberType NoteProperty -Name 'ResumeMeta' -Value $resumeMeta -Force
            
            # Add reference to prior result
            $newResult | Add-Member -MemberType NoteProperty -Name 'PriorResult' -Value $PriorResult -Force
            
            Write-Verbose "Resume metadata appended to result"
            
            # Display summary
            Write-Host "`n=== Resume Complete ===" -ForegroundColor Green
            Write-Host "New Execution ID: " -NoNewline
            Write-Host $resumeMeta.ResumeExecutionId -ForegroundColor Cyan
            Write-Host "New Results: " -NoNewline
            $newPassCount = ($newResult.CheckResults | Where-Object { $_.Success }).Count
            $newTotalCount = $newResult.CheckResults.Count
            Write-Host "$newPassCount/$newTotalCount passed" -ForegroundColor $(if($newPassCount -eq $newTotalCount){'Green'}else{'Yellow'})
            
            # Compare results
            $improvement = $newPassCount - $resumeMeta.OriginalPassedCount
            if ($improvement -gt 0) {
                Write-Host "Improvement: " -NoNewline
                Write-Host "+$improvement checks now passing" -ForegroundColor Green
            } elseif ($improvement -lt 0) {
                Write-Host "Regression: " -NoNewline
                Write-Host "$improvement checks now failing" -ForegroundColor Red
            } else {
                Write-Host "No change in pass/fail count" -ForegroundColor Gray
            }
        }
        
        if ($PassThru) {
            return $newResult
        }
        
    } catch {
        Write-Error "Failed to resume onboarding: $_"
        throw
    }
}
