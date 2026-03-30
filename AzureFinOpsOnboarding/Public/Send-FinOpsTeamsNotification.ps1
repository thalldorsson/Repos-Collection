function Send-FinOpsTeamsNotification {
    <#
    .SYNOPSIS
        Sends formatted notifications to Microsoft Teams.
    
    .DESCRIPTION
        Sends Adaptive Card notifications to Microsoft Teams channels via webhook.
        Creates rich, formatted cards with status indicators, facts, and action buttons.
        
        Supports both orchestrator result objects and custom messages.
    
    .PARAMETER WebhookUrl
        Microsoft Teams webhook URL (configure in Teams channel connectors).
    
    .PARAMETER OrchestratorObject
        FinOps orchestrator result object from Invoke-FinOpsOnboarding.
    
    .PARAMETER Title
        Custom notification title (overrides default).
    
    .PARAMETER Message
        Custom notification message.
    
    .PARAMETER IncludeDetails
        Include detailed check results in the card.
    
    .PARAMETER ThemeColor
        Card theme color (hex format). Auto-set based on status if not provided.
    
    .PARAMETER ActionButtons
        Array of action buttons to include. Each button has Title and Url properties.
    
    .EXAMPLE
        # Send onboarding result notification
        $result = Invoke-FinOpsOnboarding -TenantId $tid -CustomerName "Contoso" ...
        Send-FinOpsTeamsNotification -WebhookUrl $teamsWebhook -OrchestratorObject $result
    
    .EXAMPLE
        # Send custom notification
        Send-FinOpsTeamsNotification -WebhookUrl $teamsWebhook `
            -Title "FinOps Alert" `
            -Message "Monthly validation completed" `
            -ThemeColor "0078D4"
    
    .EXAMPLE
        # Include action buttons
        $buttons = @(
            @{ Title = 'View Portal'; Url = 'https://portal.azure.com' }
            @{ Title = 'View Report'; Url = 'https://finops.company.com/report/123' }
        )
        Send-FinOpsTeamsNotification -WebhookUrl $teamsWebhook `
            -OrchestratorObject $result `
            -ActionButtons $buttons
    #>
    [CmdletBinding(DefaultParameterSetName = 'Orchestrator')]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^https://')]
        [string]$WebhookUrl,
        
        [Parameter(Mandatory, ParameterSetName = 'Orchestrator')]
        [PSCustomObject]$OrchestratorObject,
        
        [Parameter(ParameterSetName = 'Custom')]
        [string]$Title,
        
        [Parameter(ParameterSetName = 'Custom')]
        [string]$Message,
        
        [Parameter(ParameterSetName = 'Orchestrator')]
        [switch]$IncludeDetails,
        
        [Parameter()]
        [string]$ThemeColor,
        
        [Parameter()]
        [hashtable[]]$ActionButtons
    )
    
    if ($PSCmdlet.ParameterSetName -eq 'Orchestrator') {
        # Build card from orchestrator result
        $passedChecks = ($OrchestratorObject.CheckResults | Where-Object { $_.Success }).Count
        $totalChecks = $OrchestratorObject.CheckResults.Count
        $allPassed = $passedChecks -eq $totalChecks
        
        $statusEmoji = if ($allPassed) { '✅' } else { '⚠️' }
        $statusText = if ($allPassed) { 'Success' } else { 'Partial Success' }
        
        # Auto-set theme color based on status
        if (-not $ThemeColor) {
            $ThemeColor = if ($allPassed) { '28A745' } else { 'FFC107' }  # Green or Yellow
        }
        
        # Build facts array
        $facts = @(
            @{
                title = 'Status'
                value = "$statusEmoji $statusText"
            },
            @{
                title = 'Customer'
                value = $OrchestratorObject.CustomerName
            },
            @{
                title = 'Tenant ID'
                value = $OrchestratorObject.TenantId
            },
            @{
                title = 'Checks Passed'
                value = "$passedChecks / $totalChecks"
            },
            @{
                title = 'Duration'
                value = "$([Math]::Round($OrchestratorObject.Duration.TotalMinutes, 2)) minutes"
            },
            @{
                title = 'Completed'
                value = $OrchestratorObject.CompletedAt.ToString('yyyy-MM-dd HH:mm:ss UTC')
            }
        )
        
        # Build card body
        $cardBody = @(
            @{
                type = 'TextBlock'
                text = "FinOps Onboarding: $($OrchestratorObject.CustomerName)"
                size = 'Large'
                weight = 'Bolder'
                wrap = $true
            },
            @{
                type = 'FactSet'
                facts = $facts
            }
        )
        
        # Add detailed check results if requested
        if ($IncludeDetails) {
            $cardBody += @{
                type = 'TextBlock'
                text = 'Check Results'
                weight = 'Bolder'
                size = 'Medium'
                separator = $true
                spacing = 'Medium'
            }
            
            foreach ($check in $OrchestratorObject.CheckResults) {
                $checkEmoji = if ($check.Success) { '✅' } else { '❌' }
                $checkText = "$checkEmoji **$($check.Name)**: " + $(if ($check.Success) { 'Passed' } else { $check.ErrorDetail })
                
                $cardBody += @{
                    type = 'TextBlock'
                    text = $checkText
                    wrap = $true
                    spacing = 'Small'
                }
            }
        }
        
        # Add default action buttons
        $actions = @()
        if (-not $ActionButtons) {
            $ActionButtons = @(
                @{
                    Title = 'View Azure Portal'
                    Url = "https://portal.azure.com/#@$($OrchestratorObject.TenantId)"
                }
            )
        }
    }
    else {
        # Custom message card
        if (-not $ThemeColor) {
            $ThemeColor = '0078D4'  # Default blue
        }
        
        $cardBody = @(
            @{
                type = 'TextBlock'
                text = $Title
                size = 'Large'
                weight = 'Bolder'
                wrap = $true
            }
        )
        
        if ($Message) {
            $cardBody += @{
                type = 'TextBlock'
                text = $Message
                wrap = $true
            }
        }
    }
    
    # Build action buttons
    $actions = @()
    if ($ActionButtons) {
        foreach ($button in $ActionButtons) {
            $actions += @{
                type = 'Action.OpenUrl'
                title = $button.Title
                url = $button.Url
            }
        }
    }
    
    # Build Adaptive Card
    $adaptiveCard = @{
        type = 'message'
        attachments = @(
            @{
                contentType = 'application/vnd.microsoft.card.adaptive'
                contentUrl = $null
                content = @{
                    '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
                    type = 'AdaptiveCard'
                    version = '1.4'
                    msteams = @{
                        width = 'Full'
                    }
                    body = $cardBody
                    actions = $actions
                }
            }
        )
    }
    
    # Send to Teams
    try {
        $body = $adaptiveCard | ConvertTo-Json -Depth 20
        $response = Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $body -ContentType 'application/json' -ErrorAction Stop
        
        Write-FinOpsLog -Level 'Info' -Message "Teams notification sent" -Context @{
            Title = if ($Title) { $Title } else { "FinOps: $($OrchestratorObject.CustomerName)" }
        } -Category 'Notification'
        
        return $true
    }
    catch {
        Write-FinOpsLog -Level 'Error' -Message "Failed to send Teams notification" -Context @{
            Error = $_.Exception.Message
        } -Category 'Notification' -Exception $_.Exception
        
        throw
    }
}

function New-FinOpsTeamsWebhook {
    <#
    .SYNOPSIS
        Helper to register a Teams webhook for automatic notifications.
    
    .DESCRIPTION
        Convenience function to register a Microsoft Teams webhook that automatically
        sends notifications for FinOps events.
    
    .PARAMETER WebhookUrl
        Microsoft Teams incoming webhook URL.
    
    .PARAMETER Events
        Events to send notifications for. Default is OnboardingCompleted and OnboardingFailed.
    
    .PARAMETER IncludeDetails
        Include detailed check results in notifications.
    
    .PARAMETER Name
        Friendly name for this webhook.
    
    .EXAMPLE
        New-FinOpsTeamsWebhook -WebhookUrl 'https://outlook.office.com/webhook/...' `
            -Name 'Production Team'
    
    .EXAMPLE
        # Send detailed notifications
        New-FinOpsTeamsWebhook -WebhookUrl $webhook `
            -Events 'OnboardingStarted', 'OnboardingCompleted', 'OnboardingFailed' `
            -IncludeDetails
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^https://')]
        [string]$WebhookUrl,
        
        [Parameter()]
        [ValidateSet('OnboardingStarted', 'OnboardingCompleted', 'OnboardingFailed')]
        [string[]]$Events = @('OnboardingCompleted', 'OnboardingFailed'),
        
        [Parameter()]
        [switch]$IncludeDetails,
        
        [Parameter()]
        [string]$Name = 'Teams Notification'
    )
    
    # Store Teams-specific settings
    $script:FinOpsTeamsSettings = @{
        WebhookUrl = $WebhookUrl
        IncludeDetails = $IncludeDetails
    }
    
    # Register as generic webhook with custom handler
    Register-FinOpsWebhook -Url $WebhookUrl -Events $Events -Name $Name
    
    Write-FinOpsLog -Level 'Info' -Message "Teams webhook registered" -Context @{
        Name = $Name
        Events = ($Events -join ', ')
        IncludeDetails = $IncludeDetails
    } -Category 'Notification'
}
