function Get-FinOpsNotificationPolicy {
    <#
    .SYNOPSIS
        Retrieves notification policies.
    
    .DESCRIPTION
        Gets one or all notification policies from the module-scoped registry.
        If PolicyName is specified, returns that specific policy.
        If PolicyName is omitted, returns all policies.
        
        This is a helper function for Set-FinOpsNotificationPolicy and is used
        to query existing notification configurations.
    
    .PARAMETER PolicyName
        Optional policy name. If omitted, returns all policies.
    
    .EXAMPLE
        # Get all policies
        Get-FinOpsNotificationPolicy
    
    .EXAMPLE
        # Get specific policy
        Get-FinOpsNotificationPolicy -PolicyName "ProductionAlerts"
    
    .EXAMPLE
        # Check if any policies are enabled
        $enabledPolicies = Get-FinOpsNotificationPolicy | Where-Object { $_.Enabled }
    
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
                $policy = $script:FinOpsNotificationPolicies[$PolicyName]
                
                Write-Host "`n=== Notification Policy ===" -ForegroundColor Cyan
                Write-Host "Policy Name: " -NoNewline
                Write-Host $policy.PolicyName -ForegroundColor Green
                Write-Host "Enabled: " -NoNewline
                Write-Host $policy.Enabled -ForegroundColor $(if($policy.Enabled){'Green'}else{'Red'})
                Write-Host "Triggers: " -NoNewline
                Write-Host ($policy.TriggerOn -join ', ') -ForegroundColor Yellow
                Write-Host "Teams: " -NoNewline
                Write-Host $(if($policy.TeamsWebhookUrl){'Configured'}else{'Not configured'}) -ForegroundColor $(if($policy.TeamsWebhookUrl){'Green'}else{'Gray'})
                Write-Host "Jira: " -NoNewline
                Write-Host $(if($policy.JiraIssueTemplate){'Configured'}else{'Not configured'}) -ForegroundColor $(if($policy.JiraIssueTemplate){'Green'}else{'Gray'})
                Write-Host "Created: " -NoNewline
                Write-Host $policy.CreatedAt.ToString('yyyy-MM-dd HH:mm:ss') -ForegroundColor Gray
                Write-Host "Modified: " -NoNewline
                Write-Host $policy.ModifiedAt.ToString('yyyy-MM-dd HH:mm:ss') -ForegroundColor Gray
                
                return $policy
            } else {
                Write-Warning "Policy '$PolicyName' not found"
                return $null
            }
        }
        
        # Return all policies
        Write-Verbose "Retrieving all policies (count: $($script:FinOpsNotificationPolicies.Count))"
        
        if ($script:FinOpsNotificationPolicies.Count -eq 0) {
            Write-Verbose "No policies registered"
            Write-Host "`nNo notification policies registered" -ForegroundColor Gray
            return @()
        }
        
        $policies = $script:FinOpsNotificationPolicies.Values | Sort-Object PolicyName
        
        # Display summary table
        Write-Host "`n=== Notification Policies ($($policies.Count)) ===" -ForegroundColor Cyan
        Write-Host ""
        
        $table = @()
        foreach ($p in $policies) {
            $table += [PSCustomObject]@{
                Name        = $p.PolicyName
                Enabled     = if ($p.Enabled) { '✓' } else { '✗' }
                Triggers    = ($p.TriggerOn -join ', ')
                Teams       = if ($p.TeamsWebhookUrl) { '✓' } else { '✗' }
                Jira        = if ($p.JiraIssueTemplate) { '✓' } else { '✗' }
                Modified    = $p.ModifiedAt.ToString('yyyy-MM-dd HH:mm')
            }
        }
        
        $table | Format-Table -AutoSize
        
        return $policies
        
    } catch {
        Write-Error "Failed to get notification policy: $_"
        throw
    }
}
