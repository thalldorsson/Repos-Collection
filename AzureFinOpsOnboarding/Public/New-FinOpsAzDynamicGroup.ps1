function New-FinOpsAzDynamicGroup {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$CustomerName,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$EmailDomain,

        [Parameter()]
        [string]$Description,

        [Parameter()]
        [string]$AccessToken
    )

    begin {
        if (-not $AccessToken) {
            try {
                $token = Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com" -ErrorAction Stop
                $AccessToken = $token.Token
            }
            catch {
                throw "Provide -AccessToken or sign in with Connect-AzAccount -AuthScope https://graph.microsoft.com"
            }
        }

        $headers = @{
            Authorization = "Bearer $AccessToken"
            'Content-Type' = 'application/json'
        }
    }

    process {
        $groupName = "FinOps-Customer-" + ($CustomerName -replace '[^\w\s-]', '')
        $effectiveDescription = if ($Description) { $Description } else { "FinOps dynamic group for $CustomerName - Auto-populated based on email domain $EmailDomain" }
        $membershipRule = "(user.userPrincipalName -contains `"$EmailDomain`")"

        $checkUri = "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$groupName'"
        $existingGroups = Invoke-FinOpsRestMethodWithRetry -Uri $checkUri -Headers $headers -Method Get -ErrorAction Stop

        if ($existingGroups.value -and $existingGroups.value.Count -gt 0) {
            return [PSCustomObject]@{
                Success       = $false
                GroupName     = $groupName
                GroupId       = $existingGroups.value[0].id
                Message       = "Group already exists"
                AlreadyExists = $true
            }
        }

        $groupObject = @{
            displayName                   = $groupName
            description                   = $effectiveDescription
            mailEnabled                   = $false
            mailNickname                  = $groupName -replace '[^\w]', ''
            securityEnabled               = $true
            groupTypes                    = @("DynamicMembership")
            membershipRule                = $membershipRule
            membershipRuleProcessingState = "On"
        }

        if ($PSCmdlet.ShouldProcess($groupName, "Create dynamic group")) {
            $body = $groupObject | ConvertTo-Json -Depth 10
            $response = Invoke-FinOpsRestMethodWithRetry -Uri "https://graph.microsoft.com/v1.0/groups" -Headers $headers -Method Post -Body $body -ContentType 'application/json' -ErrorAction Stop

            return [PSCustomObject]@{
                Success         = $true
                GroupName       = $response.displayName
                GroupId         = $response.id
                MembershipRule  = $response.membershipRule
                Description     = $response.description
                GroupTypes      = $response.groupTypes
                CreatedDateTime = $response.createdDateTime
                Message         = "Dynamic group created successfully"
            }
        }
        else {
            return [PSCustomObject]@{
                Success        = $true
                GroupName      = $groupName
                MembershipRule = $membershipRule
                Description    = $effectiveDescription
                Message        = "WhatIf: Group would be created"
                WhatIf         = $true
            }
        }
    }
}
