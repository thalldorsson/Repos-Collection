function Set-FinOpsNotificationPolicy {
    <#
    .SYNOPSIS
        Configures notification policies for FinOps operations.
    
    .DESCRIPTION
        Manages notification policies that define when and where to send notifications
        during FinOps operations. Policies can trigger on completion, failure, or both.
        
        Policies are stored in a module-scoped registry and can be retrieved using
        Get-FinOpsNotificationPolicy or removed using Remove-FinOpsNotificationPolicy.
    
    .PARAMETER PolicyName
        Unique name for the notification policy.
    
    .PARAMETER TriggerOn
        Array of trigger conditions: 'Completion', 'Failure', or 'Both'.
        Default: Both
    
    .PARAMETER TeamsWebhookUrl
        Microsoft Teams webhook URL for notifications.
    
    .PARAMETER JiraIssueTemplate
        Jira issue template configuration (hashtable with project, issueType, etc).
    
    .PARAMETER Enabled
        Whether the policy is enabled. Default: $true
    
    .EXAMPLE
        Set-FinOpsNotificationPolicy -PolicyName "ProductionAlerts" `
            -TriggerOn @('Failure') `
            -TeamsWebhookUrl "https://outlook.office.com/webhook/..."
    
    .EXAMPLE
        $jiraTemplate = @{
            Project = 'FINOPS'
            IssueType = 'Task'
            Priority = 'High'
        }
        Set-FinOpsNotificationPolicy -PolicyName "OnboardingNotifications" `
            -TriggerOn @('Completion', 'Failure') `
            -TeamsWebhookUrl $teamsUrl `
            -JiraIssueTemplate $jiraTemplate
    
    .EXAMPLE
        # Disable a policy
        Set-FinOpsNotificationPolicy -PolicyName "ProductionAlerts" -Enabled $false
    
    .OUTPUTS
        PSCustomObject representing the notification policy.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PolicyName,
        
        [Parameter()]
        [ValidateSet('Completion', 'Failure', 'Both')]
        [string[]]$TriggerOn = @('Both'),
        
        [Parameter()]
        [ValidatePattern('^https://')]
        [string]$TeamsWebhookUrl,
        
        [Parameter()]
        [hashtable]$JiraIssueTemplate,
        
        [Parameter()]
        [bool]$Enabled = $true
    )
    
    try {
        Write-Verbose "=== Setting Notification Policy ==="
        Write-Verbose "Policy Name: $PolicyName"
        
        # Confirm operation
        if (-not $PSCmdlet.ShouldProcess("Notification Policy: $PolicyName", "Create or update policy")) {
            Write-Verbose "Operation cancelled by user"
            return
        }
        
        # Initialize module-scoped policy registry if it doesn't exist
        if (-not $script:FinOpsNotificationPolicies) {
            $script:FinOpsNotificationPolicies = @{}
            Write-Verbose "Initialized notification policy registry"
        }
        
        # Check if policy already exists
        $isUpdate = $script:FinOpsNotificationPolicies.ContainsKey($PolicyName)
        $existingPolicy = if ($isUpdate) { $script:FinOpsNotificationPolicies[$PolicyName] } else { $null }
        
        # Normalize TriggerOn array
        $normalizedTriggers = @()
        if ($TriggerOn -contains 'Both') {
            $normalizedTriggers = @('Completion', 'Failure')
        } else {
            $normalizedTriggers = $TriggerOn | Select-Object -Unique
        }
        
        # Build policy object
        $policy = [PSCustomObject]@{
            PolicyName        = $PolicyName
            TriggerOn         = $normalizedTriggers
            TeamsWebhookUrl   = if ($TeamsWebhookUrl) { $TeamsWebhookUrl } elseif ($existingPolicy) { $existingPolicy.TeamsWebhookUrl } else { $null }
            JiraIssueTemplate = if ($JiraIssueTemplate) { $JiraIssueTemplate } elseif ($existingPolicy) { $existingPolicy.JiraIssueTemplate } else { $null }
            Enabled           = $Enabled
            CreatedAt         = if ($existingPolicy) { $existingPolicy.CreatedAt } else { Get-Date }
            ModifiedAt        = Get-Date
            CreatedBy         = if ($existingPolicy) { $existingPolicy.CreatedBy } else { $env:USERNAME }
            ModifiedBy        = $env:USERNAME
        }
        
        # Validate that at least one notification channel is configured
        if (-not $policy.TeamsWebhookUrl -and -not $policy.JiraIssueTemplate) {
            Write-Warning "Policy '$PolicyName' has no notification channels configured (Teams or Jira). Policy created but will not send notifications."
        }
        
        # Store policy in registry
        $script:FinOpsNotificationPolicies[$PolicyName] = $policy
        
        Write-Verbose "Policy '$PolicyName' $(if($isUpdate){'updated'}else{'created'}) successfully"
        
        # Display summary
        Write-Host "`n=== Notification Policy $(if($isUpdate){'Updated'}else{'Created'}) ===" -ForegroundColor Green
        Write-Host "Policy Name: " -NoNewline
        Write-Host $policy.PolicyName -ForegroundColor Cyan
        Write-Host "Enabled: " -NoNewline
        Write-Host $policy.Enabled -ForegroundColor $(if($policy.Enabled){'Green'}else{'Red'})
        Write-Host "Triggers: " -NoNewline
        Write-Host ($policy.TriggerOn -join ', ') -ForegroundColor Yellow
        Write-Host "Teams Webhook: " -NoNewline
        Write-Host $(if($policy.TeamsWebhookUrl){'Configured'}else{'Not configured'}) -ForegroundColor $(if($policy.TeamsWebhookUrl){'Green'}else{'Gray'})
        Write-Host "Jira Template: " -NoNewline
        Write-Host $(if($policy.JiraIssueTemplate){'Configured'}else{'Not configured'}) -ForegroundColor $(if($policy.JiraIssueTemplate){'Green'}else{'Gray'})
        Write-Host "Modified: " -NoNewline
        Write-Host $policy.ModifiedAt.ToString('yyyy-MM-dd HH:mm:ss') -ForegroundColor Gray
        Write-Host "Modified By: " -NoNewline
        Write-Host $policy.ModifiedBy -ForegroundColor Gray
        
        return $policy
        
    } catch {
        Write-Error "Failed to set notification policy: $_"
        throw
    }
}

function Get-FinOpsNotificationPolicy {
    <#
    .SYNOPSIS
        Retrieves notification policies.
    
    .DESCRIPTION
        Gets one or all notification policies from the module-scoped registry.
        If PolicyName is specified, returns that specific policy.
        If PolicyName is omitted, returns all policies.
    
    .PARAMETER PolicyName
        Optional policy name. If omitted, returns all policies.
    
    .EXAMPLE
        Get-FinOpsNotificationPolicy
    
    .EXAMPLE
        Get-FinOpsNotificationPolicy -PolicyName "ProductionAlerts"
    
    .OUTPUTS
        PSCustomObject or array of PSCustomObjects representing notification policies.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$PolicyName
    )
    
    try {
        Write-Verbose "=== Getting Notification Policy ==="
        
        # Initialize registry if it doesn't exist
        if (-not $script:FinOpsNotificationPolicies) {
            $script:FinOpsNotificationPolicies = @{}
            Write-Verbose "No policies registered"
            return $null
        }
        
        # Return specific policy if name provided
        if ($PolicyName) {
            Write-Verbose "Retrieving policy: $PolicyName"
            
            if ($script:FinOpsNotificationPolicies.ContainsKey($PolicyName)) {
                return $script:FinOpsNotificationPolicies[$PolicyName]
            } else {
                Write-Warning "Policy '$PolicyName' not found"
                return $null
            }
        }
        
        # Return all policies
        Write-Verbose "Retrieving all policies (count: $($script:FinOpsNotificationPolicies.Count))"
        
        if ($script:FinOpsNotificationPolicies.Count -eq 0) {
            Write-Verbose "No policies registered"
            return @()
        }
        
        return $script:FinOpsNotificationPolicies.Values | Sort-Object PolicyName
        
    } catch {
        Write-Error "Failed to get notification policy: $_"
        throw
    }
}

function Remove-FinOpsNotificationPolicy {
    <#
    .SYNOPSIS
        Removes a notification policy.
    
    .DESCRIPTION
        Deletes a notification policy from the module-scoped registry.
    
    .PARAMETER PolicyName
        Name of the policy to remove.
    
    .EXAMPLE
        Remove-FinOpsNotificationPolicy -PolicyName "ProductionAlerts"
    
    .OUTPUTS
        None
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PolicyName
    )
    
    try {
        Write-Verbose "=== Removing Notification Policy ==="
        Write-Verbose "Policy Name: $PolicyName"
        
        # Initialize registry if it doesn't exist
        if (-not $script:FinOpsNotificationPolicies) {
            $script:FinOpsNotificationPolicies = @{}
            Write-Warning "No policies registered"
            return
        }
        
        # Check if policy exists
        if (-not $script:FinOpsNotificationPolicies.ContainsKey($PolicyName)) {
            Write-Warning "Policy '$PolicyName' not found"
            return
        }
        
        # Confirm operation
        if (-not $PSCmdlet.ShouldProcess("Notification Policy: $PolicyName", "Remove policy")) {
            Write-Verbose "Operation cancelled by user"
            return
        }
        
        # Remove policy
        $script:FinOpsNotificationPolicies.Remove($PolicyName)
        
        Write-Verbose "Policy '$PolicyName' removed successfully"
        
        Write-Host "`n=== Notification Policy Removed ===" -ForegroundColor Yellow
        Write-Host "Policy Name: " -NoNewline
        Write-Host $PolicyName -ForegroundColor Cyan
        
    } catch {
        Write-Error "Failed to remove notification policy: $_"
        throw
    }
}

function Invoke-FinOpsNotificationPolicy {
    <#
    .SYNOPSIS
        Invokes notification policies based on trigger conditions (internal helper).
    
    .DESCRIPTION
        Internal helper function that evaluates notification policies and sends
        notifications based on trigger conditions. Called by orchestrator functions.
    
    .PARAMETER TriggerType
        Trigger type: 'Completion' or 'Failure'.
    
    .PARAMETER Context
        Context object with information about the operation (customer, result, etc).
    
    .EXAMPLE
        Invoke-FinOpsNotificationPolicy -TriggerType 'Completion' -Context $orchestratorResult
    
    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Completion', 'Failure')]
        [string]$TriggerType,
        
        [Parameter(Mandatory)]
        [PSCustomObject]$Context
    )
    
    try {
        Write-Verbose "=== Invoking Notification Policies ==="
        Write-Verbose "Trigger Type: $TriggerType"
        
        # Get all enabled policies
        $policies = Get-FinOpsNotificationPolicy | Where-Object { $_.Enabled -and ($_.TriggerOn -contains $TriggerType) }
        
        if (-not $policies -or $policies.Count -eq 0) {
            Write-Verbose "No enabled policies match trigger type: $TriggerType"
            return
        }
        
        Write-Verbose "Found $($policies.Count) matching policy/policies"
        
        foreach ($policy in $policies) {
            Write-Verbose "Executing policy: $($policy.PolicyName)"
            
            # Send Teams notification if configured
            if ($policy.TeamsWebhookUrl) {
                try {
                    Write-Verbose "Sending Teams notification for policy: $($policy.PolicyName)"
                    Send-FinOpsTeamsNotification -WebhookUrl $policy.TeamsWebhookUrl -OrchestratorObject $Context -ErrorAction Continue
                } catch {
                    Write-Warning "Failed to send Teams notification for policy '$($policy.PolicyName)': $_"
                }
            }
            
            # Create Jira issue if template configured
            if ($policy.JiraIssueTemplate) {
                try {
                    Write-Verbose "Creating Jira issue for policy: $($policy.PolicyName)"
                    # Implementation would use New-FinOpsJiraIssue or similar
                    Write-Warning "Jira issue creation not yet implemented in Invoke-FinOpsNotificationPolicy"
                } catch {
                    Write-Warning "Failed to create Jira issue for policy '$($policy.PolicyName)': $_"
                }
            }
        }
        
    } catch {
        Write-Warning "Failed to invoke notification policies: $_"
    }
}
