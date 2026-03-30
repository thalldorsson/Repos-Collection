function Register-FinOpsWebhook {
    <#
    .SYNOPSIS
        Registers a webhook for FinOps event notifications.
    
    .DESCRIPTION
        Configures webhook endpoints to receive notifications for FinOps events such as
        onboarding start, completion, or failure. Supports HMAC-SHA256 signing for security.
        
        Webhooks receive JSON payloads with event details and can be used to integrate
        with Teams, Slack, custom systems, or automation workflows.
    
    .PARAMETER Url
        Webhook endpoint URL (must be https://).
    
    .PARAMETER Events
        Array of event names to subscribe to. Valid events:
        - OnboardingStarted
        - OnboardingCompleted
        - OnboardingFailed
        - CheckCompleted
        - CheckFailed
        - ValidationWarning
    
    .PARAMETER Headers
        Optional custom headers to include in webhook requests.
    
    .PARAMETER Secret
        Optional secret for HMAC-SHA256 signature generation (recommended for security).
        Signature is sent in X-FinOps-Signature header as 'sha256=<signature>'.
    
    .PARAMETER Name
        Optional friendly name for the webhook registration.
    
    .EXAMPLE
        Register-FinOpsWebhook -Url 'https://hooks.slack.com/services/...' `
            -Events 'OnboardingCompleted', 'OnboardingFailed'
    
    .EXAMPLE
        # Secure webhook with HMAC signing
        $secret = ConvertTo-SecureString 'my-webhook-secret' -AsPlainText -Force
        Register-FinOpsWebhook -Url 'https://api.example.com/webhook' `
            -Events 'OnboardingStarted', 'OnboardingCompleted', 'OnboardingFailed' `
            -Secret $secret `
            -Name 'Production Webhook'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^https://')]
        [string]$Url,
        
        [Parameter(Mandatory)]
        [ValidateSet('OnboardingStarted', 'OnboardingCompleted', 'OnboardingFailed', 
                     'CheckCompleted', 'CheckFailed', 'ValidationWarning')]
        [string[]]$Events,
        
        [Parameter()]
        [hashtable]$Headers = @{},
        
        [Parameter()]
        [SecureString]$Secret,
        
        [Parameter()]
        [string]$Name
    )
    
    # Initialize webhooks array if not exists
    if (-not $script:FinOpsWebhooks) {
        $script:FinOpsWebhooks = @()
    }
    
    $webhook = [PSCustomObject]@{
        Name = if ($Name) { $Name } else { "Webhook-$($script:FinOpsWebhooks.Count + 1)" }
        Url = $Url
        Events = $Events
        Headers = $Headers
        Secret = $Secret
        Enabled = $true
        CreatedAt = (Get-Date).ToUniversalTime()
    }
    
    $script:FinOpsWebhooks += $webhook
    
    Write-FinOpsLog -Level 'Info' -Message "Webhook registered" -Context @{
        Name = $webhook.Name
        Url = $Url
        Events = ($Events -join ', ')
    } -Category 'Webhook'
    
    return $webhook
}

function Send-FinOpsWebhook {
    <#
    .SYNOPSIS
        Sends webhook notifications for FinOps events.
    
    .DESCRIPTION
        Internal function to dispatch webhook notifications to registered endpoints.
        Automatically called by FinOps operations when events occur.
    
    .PARAMETER Event
        Event name that occurred.
    
    .PARAMETER Payload
        Event payload data (hashtable).
    
    .PARAMETER CorrelationId
        Optional correlation ID for request tracking.
    
    .EXAMPLE
        Send-FinOpsWebhook -Event 'OnboardingCompleted' -Payload @{
            CustomerName = 'Contoso'
            Success = $true
            Duration = 125.5
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Event,
        
        [Parameter(Mandatory)]
        [hashtable]$Payload,
        
        [Parameter()]
        [string]$CorrelationId
    )
    
    if (-not $script:FinOpsWebhooks -or $script:FinOpsWebhooks.Count -eq 0) {
        Write-Verbose "No webhooks registered"
        return
    }
    
    # Find webhooks subscribed to this event
    $matchingWebhooks = $script:FinOpsWebhooks | Where-Object { 
        $_.Enabled -and $_.Events -contains $Event 
    }
    
    if ($matchingWebhooks.Count -eq 0) {
        Write-Verbose "No webhooks subscribed to event: $Event"
        return
    }
    
    Write-FinOpsLog -Level 'Debug' -Message "Sending webhook notifications" -Context @{
        Event = $Event
        WebhookCount = $matchingWebhooks.Count
    } -Category 'Webhook'
    
    foreach ($webhook in $matchingWebhooks) {
        try {
            # Build webhook payload
            $webhookPayload = @{
                Event = $Event
                Timestamp = (Get-Date).ToUniversalTime().ToString('o')
                Payload = $Payload
                ModuleVersion = '1.6.0'
            }
            
            if ($CorrelationId) {
                $webhookPayload.CorrelationId = $CorrelationId
            }
            
            $body = $webhookPayload | ConvertTo-Json -Depth 10
            
            # Prepare headers
            $headers = $webhook.Headers.Clone()
            $headers['Content-Type'] = 'application/json'
            $headers['User-Agent'] = 'AzureFinOpsOnboarding/1.6.0'
            
            if ($CorrelationId) {
                $headers['X-Correlation-ID'] = $CorrelationId
            }
            
            # Sign payload with HMAC-SHA256 if secret provided
            if ($webhook.Secret) {
                $secretPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($webhook.Secret)
                )
                
                $hmac = New-Object System.Security.Cryptography.HMACSHA256
                $hmac.Key = [System.Text.Encoding]::UTF8.GetBytes($secretPlain)
                $hash = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($body))
                $signature = [BitConverter]::ToString($hash).Replace('-', '').ToLower()
                
                $headers['X-FinOps-Signature'] = "sha256=$signature"
            }
            
            # Send webhook request
            $response = Invoke-RestMethod -Uri $webhook.Url -Method Post -Body $body -Headers $headers -TimeoutSec 10 -ErrorAction Stop
            
            Write-FinOpsLog -Level 'Info' -Message "Webhook sent successfully" -Context @{
                Name = $webhook.Name
                Event = $Event
                Url = $webhook.Url
            } -Category 'Webhook'
        }
        catch {
            Write-FinOpsLog -Level 'Warning' -Message "Webhook delivery failed" -Context @{
                Name = $webhook.Name
                Event = $Event
                Url = $webhook.Url
                Error = $_.Exception.Message
            } -Category 'Webhook' -Exception $_.Exception
            
            # Don't throw - webhook failures should not break operations
        }
    }
}

function Get-FinOpsWebhooks {
    <#
    .SYNOPSIS
        Lists all registered webhooks.
    
    .DESCRIPTION
        Returns all registered webhook configurations.
    
    .EXAMPLE
        Get-FinOpsWebhooks | Format-Table Name, Url, Events
    #>
    [CmdletBinding()]
    param()
    
    if (-not $script:FinOpsWebhooks) {
        return @()
    }
    
    return $script:FinOpsWebhooks
}

function Remove-FinOpsWebhook {
    <#
    .SYNOPSIS
        Removes a registered webhook.
    
    .DESCRIPTION
        Unregisters a webhook by name or URL.
    
    .PARAMETER Name
        Webhook name to remove.
    
    .PARAMETER Url
        Webhook URL to remove.
    
    .EXAMPLE
        Remove-FinOpsWebhook -Name 'Production Webhook'
    
    .EXAMPLE
        Remove-FinOpsWebhook -Url 'https://hooks.slack.com/services/...'
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByName')]
        [string]$Name,
        
        [Parameter(Mandatory, ParameterSetName = 'ByUrl')]
        [string]$Url
    )
    
    if (-not $script:FinOpsWebhooks) {
        Write-Warning "No webhooks registered"
        return
    }
    
    if ($PSCmdlet.ParameterSetName -eq 'ByName') {
        $script:FinOpsWebhooks = $script:FinOpsWebhooks | Where-Object { $_.Name -ne $Name }
        Write-FinOpsLog -Level 'Info' -Message "Webhook removed" -Context @{ Name = $Name } -Category 'Webhook'
    }
    else {
        $script:FinOpsWebhooks = $script:FinOpsWebhooks | Where-Object { $_.Url -ne $Url }
        Write-FinOpsLog -Level 'Info' -Message "Webhook removed" -Context @{ Url = $Url } -Category 'Webhook'
    }
}

function Enable-FinOpsWebhook {
    <#
    .SYNOPSIS
        Enables a disabled webhook.
    
    .PARAMETER Name
        Webhook name to enable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )
    
    $webhook = $script:FinOpsWebhooks | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($webhook) {
        $webhook.Enabled = $true
        Write-FinOpsLog -Level 'Info' -Message "Webhook enabled" -Context @{ Name = $Name } -Category 'Webhook'
    }
    else {
        Write-Warning "Webhook not found: $Name"
    }
}

function Disable-FinOpsWebhook {
    <#
    .SYNOPSIS
        Disables a webhook without removing it.
    
    .PARAMETER Name
        Webhook name to disable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )
    
    $webhook = $script:FinOpsWebhooks | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($webhook) {
        $webhook.Enabled = $false
        Write-FinOpsLog -Level 'Info' -Message "Webhook disabled" -Context @{ Name = $Name } -Category 'Webhook'
    }
    else {
        Write-Warning "Webhook not found: $Name"
    }
}
