function New-FinOpsTeamsChannel {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$TeamId,
        [Parameter(Mandatory)][string]$ChannelName,
        [string]$Description,
        [switch]$SendWelcomeMessage
    )

    begin {
        $requiredScopes = @('Channel.Create','ChannelSettings.ReadWrite.All','Group.ReadWrite.All')
        if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Teams)) { Install-Module Microsoft.Graph.Teams -Scope CurrentUser -Force -ErrorAction Stop }
        Import-Module Microsoft.Graph.Teams -ErrorAction Stop

        $ctx = $null
        try { $ctx = Get-MgContext -ErrorAction SilentlyContinue } catch {}
        $needsConnect = $true
        if ($ctx -and ($requiredScopes | ForEach-Object { $ctx.Scopes -contains $_ }) -notcontains $false) { $needsConnect = $false }
        if ($needsConnect) { Connect-MgGraph -Scopes $requiredScopes -UseDeviceCode -NoWelcome -ErrorAction Stop | Out-Null }
    }

    process {
        if ($PSCmdlet.ShouldProcess("Team $TeamId", "Create channel $ChannelName")) {
            $channelParams = @{ displayName = $ChannelName; description = $Description; membershipType = 'standard' }
            $channel = New-MgTeamChannel -TeamId $TeamId -BodyParameter $channelParams -ErrorAction Stop
            $channelId = $channel.Id
            Write-Host "Channel created: $channelId" -ForegroundColor Green

            Write-Host "`nManual webhook setup required:" -ForegroundColor Gray
            Write-Host "1) In Teams, open team $TeamId" -ForegroundColor Gray
            Write-Host "2) Open channel '$ChannelName'" -ForegroundColor Gray
            Write-Host "3) Choose ... then Connectors then Incoming Webhook" -ForegroundColor Gray
            Write-Host "4) Name it 'FinOps Notifications', create, and copy the webhook URL" -ForegroundColor Gray
            Write-Host "5) Register it: Register-FinOpsWebhook -Url [webhook-url]" -ForegroundColor Gray

            if ($SendWelcomeMessage -and $env:FINOPS_TEAMS_WEBHOOK_URL) {
                Send-FinOpsTeamsNotification -WebhookUrl $env:FINOPS_TEAMS_WEBHOOK_URL `
                    -Title "FinOps Notifications" -Message "Channel '$ChannelName' ready." `
                    -ThemeColor "0078D4" -ErrorAction SilentlyContinue
            }

            [PSCustomObject]@{
                ChannelId = $channelId
                ChannelName = $ChannelName
                TeamId = $TeamId
                CreatedAt = Get-Date
            }
        }
    }
}
