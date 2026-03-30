function Grant-FinOpsPowerBIReportAccess {
    <#
    .SYNOPSIS
    Grants an Entra ID group access to a Power BI report by name and returns a shareable link.

    .DESCRIPTION
    Looks up a Power BI report by name (optionally within a specific workspace), resolves an Entra ID group
    by display name (or accepts a direct ObjectId), and grants the specified access right to the group
    using the Power BI REST API. Returns a PSCustomObject including a report link suitable for sharing in email.

    Requires MicrosoftPowerBIMgmt module for authentication and REST calls. Attempts to use Microsoft Graph
    (Microsoft.Graph.Groups) to resolve the Entra group ObjectId when only a name is provided.

    .PARAMETER ReportName
    The display name of the report in Power BI.

    .PARAMETER EntraGroup
    Display name of the Entra ID (Azure AD) group to grant access to.

    .PARAMETER EntraGroupId
    ObjectId (GUID) of the Entra ID group. If provided, takes precedence over EntraGroup.

    .PARAMETER AccessRight
    Access right to grant. Defaults to 'Read'.

    .PARAMETER PassThru
    If specified, returns the result object to the pipeline.

    .PARAMETER UsePowerBIMcp
    Use registered MCP delegates instead of direct Power BI API calls.
    Requires Register-FinOpsPowerBIMcpProvider to be called first.

    .EXAMPLE
    Grant-FinOpsPowerBIReportAccess -ReportName "FinOps Overview" -EntraGroup "FinOps-Customer-Australd2aa" -AccessRight Read

    .EXAMPLE
    # Using MCP delegates
    Register-FinOpsPowerBIMcpProvider -GetReportScript { ... } -GrantReportAccessScript { ... }
    Grant-FinOpsPowerBIReportAccess -ReportName "FinOps Overview" -EntraGroup "FinOps-Customer" -UsePowerBIMcp

    .OUTPUTS
    PSCustomObject with properties: ReportName, WorkspaceName, WorkspaceId, ReportId, GrantedTo, GrantedToId, AccessRight, ShareLink
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ReportName,
        [Parameter()][string]$EntraGroup,
        [Parameter()][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$EntraGroupId,
        [Parameter()][ValidateSet('Read')][string]$AccessRight = 'Read',
        [switch]$PassThru,
        [switch]$UsePowerBIMcp
    )

    # No helper functions needed

    try {
        # MCP path: Use registered delegates
        if ($UsePowerBIMcp) {
            Write-Verbose "Using Power BI MCP delegates"
            
            $report = Invoke-FinOpsPowerBIMcp -Operation GetReport -Arguments @{ ReportName = $ReportName }
            if (-not $report) { throw "Report not found via MCP: $ReportName" }
            
            $reportId = $report.Id
            $workspaceId = $report.WorkspaceId
            
            $ws = Invoke-FinOpsPowerBIMcp -Operation GetWorkspace -Arguments @{ WorkspaceId = $workspaceId }
            if (-not $ws) { throw "Workspace not found via MCP: $workspaceId" }
            
            $principalId = $null
            $principalName = $null
            if ($EntraGroupId) {
                $principalId = $EntraGroupId
                $principalName = $EntraGroupId
            } elseif ($EntraGroup) {
                $principalName = $EntraGroup
                Write-Verbose "Resolving Entra group: $EntraGroup"
                
                if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Groups)) {
                    Install-Module -Name Microsoft.Graph.Groups -Scope CurrentUser -Force -ErrorAction Stop
                }
                Import-Module Microsoft.Graph.Groups -ErrorAction Stop
                
                $ctx = $null
                try { $ctx = Get-MgContext -ErrorAction SilentlyContinue } catch {}
                if (-not $ctx) {
                    # Use device code flow to avoid loopback redirect URI issues
                    Connect-MgGraph -Scopes Group.Read.All -NoWelcome -UseDeviceCode -ErrorAction Stop | Out-Null
                }
                
                $safeName = $EntraGroup.Replace("'","''")
                $mgGroup = Get-MgGroup -Filter "displayName eq '$safeName'" -ConsistencyLevel eventual -ErrorAction Stop
                
                if (-not $mgGroup) { throw "Entra group not found: '$EntraGroup'" }
                if ($mgGroup -is [array] -and $mgGroup.Count -gt 1) {
                    throw "Multiple groups found named '$EntraGroup'. Use -EntraGroupId."
                }
                
                $principalId = $mgGroup.Id
                Write-Verbose "Resolved group '$EntraGroup' to ID: $principalId"
            } else {
                throw "Provide either -EntraGroup or -EntraGroupId"
            }
            
            if ($PSCmdlet.ShouldProcess("Report $ReportName ($reportId)", "Grant $AccessRight to group $principalId")) {
                Write-Verbose "Granting $AccessRight access via Power BI MCP"
                Invoke-FinOpsPowerBIMcp -Operation GrantReportAccess -Arguments @{
                    ReportId = $reportId
                    WorkspaceId = $workspaceId
                    PrincipalId = $principalId
                    PrincipalType = 'Group'
                    AccessRight = $AccessRight
                }
            }
            
            $shareLink = "https://app.powerbi.com/groups/$workspaceId/reports/$reportId"
            
            $result = [PSCustomObject]@{
                ReportName    = $report.Name
                WorkspaceName = $ws.Name
                WorkspaceId   = $workspaceId
                ReportId      = $reportId
                GrantedTo     = $principalName
                GrantedToId   = $principalId
                AccessRight   = $AccessRight
                ShareLink     = $shareLink
            }
            
            if ($PassThru) { return $result } else { $result | Out-String | Write-Verbose }
            $result
            return
        }
        
        # Standard path: Direct Power BI API
        Write-Verbose "Ensuring MicrosoftPowerBIMgmt module is available"
        if (-not (Get-Module -ListAvailable -Name MicrosoftPowerBIMgmt.Profile)) {
            Write-Verbose "Installing MicrosoftPowerBIMgmt.Profile module for current user"
            Install-Module -Name MicrosoftPowerBIMgmt.Profile -Scope CurrentUser -Force -ErrorAction Stop
        }
        if (-not (Get-Module -ListAvailable -Name MicrosoftPowerBIMgmt)) {
            Write-Verbose "Installing MicrosoftPowerBIMgmt meta module for current user"
            Install-Module -Name MicrosoftPowerBIMgmt -Scope CurrentUser -Force -ErrorAction Stop
        }
        Import-Module MicrosoftPowerBIMgmt -ErrorAction Stop

        # Connect to Power BI (if not already connected)
        $token = $null
        try { $token = Get-PowerBIAccessToken -AsString -ErrorAction Stop } catch {}
        if (-not $token) {
            Write-Verbose "Attempting to connect to Power BI using Az context"
            # Try to use existing Az connection first
            $azContext = $null
            try { $azContext = Get-AzContext -ErrorAction SilentlyContinue } catch {}
            
            if ($azContext) {
                Write-Verbose "Found Az context, attempting to get Power BI token from Az account"
                try {
                    # Get token using Az account for Power BI resource
                    $tokenResponse = Get-AzAccessToken -ResourceUrl "https://analysis.windows.net/powerbi/api" -ErrorAction Stop
                    if ($tokenResponse -and $tokenResponse.Token) {
                        Write-Verbose "Successfully obtained Power BI token from Az context"
                        # Set environment variable that Power BI cmdlets will use
                        $env:PBI_ACCESS_TOKEN = $tokenResponse.Token
                        $token = "Bearer $($tokenResponse.Token)"
                    }
                } catch {
                    Write-Verbose "Failed to get Power BI token from Az context: $_"
                }
            }
            
            # Fallback to interactive connection if Az token didn't work
            if (-not $token) {
                Write-Warning @"
Power BI authentication required. This will open a browser for authentication.

To avoid browser authentication issues, you can:
1. Use: Connect-AzAccount (then retry this command)
2. Or use: Connect-PowerBIServiceAccount (before running this command)

Attempting interactive Power BI connection now...
"@
                try {
                    Connect-PowerBIServiceAccount -ErrorAction Stop | Out-Null
                    $token = Get-PowerBIAccessToken -AsString -ErrorAction Stop
                } catch {
                    throw "Failed to authenticate to Power BI. Error: $_`n`nPlease run 'Connect-AzAccount' or 'Connect-PowerBIServiceAccount' first."
                }
            }
        }

        # Locate report using admin API to get workspace info
        Write-Verbose "Looking up report by name across organization: $ReportName"
        $reports = Get-PowerBIReport -Name $ReportName -Scope Organization -ErrorAction Stop
        if (-not $reports) { throw "Report not found: $ReportName" }
        if ($reports.Count -gt 1) {
            $names = ($reports | Select-Object -First 10 | ForEach-Object { 
                $wsIdDisplay = if ($_.WorkspaceId) { $_.WorkspaceId } else { "unknown" }
                "{0} (WorkspaceId={1}, ReportId={2})" -f $_.Name, $wsIdDisplay, $_.Id 
            }) -join "; "
            throw "Multiple reports found named '$ReportName'. Candidates: $names"
        }
        $report = $reports
        
        if (-not $report) { throw "Report '$ReportName' not found." }
        $reportId = $report.Id
        
        # Debug: Show all properties of the report object
        Write-Verbose "Report object properties:"
        $report.PSObject.Properties | ForEach-Object {
            Write-Verbose "  $($_.Name) = $($_.Value)"
        }
        
        # Extract workspace ID - use admin API to find workspace containing this report
        $workspaceId = $null
        Write-Verbose "Using admin API to find workspace containing report ID: $reportId"
        
        # Call admin API to get all workspaces and find which one contains this report
        try {
            Write-Verbose "Calling Power BI admin API: /admin/groups?`$expand=reports"
            $workspacesResponse = Invoke-PowerBIRestMethod -Url "admin/groups?`$expand=reports" -Method Get -ErrorAction Stop | ConvertFrom-Json
            
            foreach ($workspace in $workspacesResponse.value) {
                if ($workspace.reports | Where-Object { $_.id -eq $reportId }) {
                    $workspaceId = $workspace.id
                    Write-Verbose "Found report in workspace: $($workspace.name) (ID: $workspaceId)"
                    break
                }
            }
            
            if (-not $workspaceId) {
                throw "Report '$ReportName' (ID: $reportId) not found in any workspace. Verify you have Power BI Admin permissions."
            }
        } catch {
            throw "Failed to locate workspace for report: $_"
        }
        
        # Get workspace details
        Write-Verbose "Looking up workspace with ID: $workspaceId"
        $ws = $null
        try {
            $ws = Get-PowerBIWorkspace -Id $workspaceId -Scope Organization -ErrorAction Stop
        } catch {
            Write-Verbose "Failed to get workspace via Get-PowerBIWorkspace: $_"
            # Fallback: create minimal workspace object
            $ws = [PSCustomObject]@{
                Id = $workspaceId
                Name = "Workspace-$workspaceId"
            }
            Write-Verbose "Using fallback workspace object"
        }
        
        if (-not $ws) {
            throw "Cannot access workspace with ID: $workspaceId. Verify you have workspace admin/member permissions."
        }

        # Resolve Entra group id
        $principalId = $null
        $principalName = $null
        if ($EntraGroupId) {
            $principalId = $EntraGroupId
            $principalName = $EntraGroupId
        } elseif ($EntraGroup) {
            $principalName = $EntraGroup
            Write-Verbose "Resolving Entra group: $EntraGroup"
            
            # Prefer Microsoft Graph
            if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Groups)) {
                Write-Verbose "Installing Microsoft.Graph.Groups module for current user"
                Install-Module -Name Microsoft.Graph.Groups -Scope CurrentUser -Force -ErrorAction Stop
            }
            Import-Module Microsoft.Graph.Groups -ErrorAction Stop
            
            # Ensure connection
            $ctx = $null
            try { $ctx = Get-MgContext -ErrorAction SilentlyContinue } catch {}
            if (-not $ctx) {
                Write-Verbose "Connecting to Microsoft Graph (Group.Read.All) using device code authentication"
                try {
                    # Use device code flow to avoid loopback redirect URI issues
                    Connect-MgGraph -Scopes Group.Read.All -NoWelcome -UseDeviceCode -ErrorAction Stop | Out-Null
                    $ctx = Get-MgContext
                } catch {
                    throw "Failed to connect to Microsoft Graph: $_. Ensure you have permissions to read groups."
                }
            }
            Write-Verbose "Connected to Graph as: $($ctx.Account) (Tenant: $($ctx.TenantId))"
            
            $safeName = $EntraGroup.Replace("'","''")
            Write-Verbose "Searching for group with displayName eq '$safeName'"
            
            try {
                $mgGroup = Get-MgGroup -Filter "displayName eq '$safeName'" -ConsistencyLevel eventual -Count groupCount -ErrorAction Stop
            } catch {
                throw "Failed to query Microsoft Graph for group '$EntraGroup': $_. Verify you have Group.Read.All permission and the group exists."
            }
            
            if (-not $mgGroup) { 
                Write-Verbose "No group found with exact name match. Searching all groups for partial match..."
                try {
                    $allGroups = Get-MgGroup -Filter "startsWith(displayName, '$($EntraGroup.Substring(0, [Math]::Min(10, $EntraGroup.Length)))')" -ConsistencyLevel eventual -Top 50 -ErrorAction SilentlyContinue
                    if ($allGroups) {
                        $suggestions = ($allGroups | Select-Object -First 10 | ForEach-Object { "'$($_.DisplayName)' (Id: $($_.Id))" }) -join "`n  "
                        throw "Entra group not found by name: '$EntraGroup'`n`nSimilar groups found:`n  $suggestions`n`nProvide exact name or use -EntraGroupId parameter."
                    }
                } catch {}
                throw "Entra group not found by name: '$EntraGroup'. Verify the group exists and you have permission to read it."
            }
            
            if ($mgGroup -is [array] -and $mgGroup.Count -gt 1) {
                $ids = ($mgGroup | Select-Object -First 10 | ForEach-Object { "'$($_.DisplayName)' (Id: $($_.Id))" }) -join "`n  "
                throw "Multiple groups found named '$EntraGroup'. Provide -EntraGroupId. Candidates:`n  $ids"
            }
            
            $principalId = $mgGroup.Id
            Write-Verbose "Resolved group '$EntraGroup' to ID: $principalId"
            
        } else {
            throw "Provide either -EntraGroup or -EntraGroupId"
        }

        $principal = [PSCustomObject]@{
            identifier    = $principalId
            principalType = 'Group'
            accessRight   = $AccessRight
        }
        $body = $principal | ConvertTo-Json -Depth 5

        $url = "groups/$workspaceId/reports/$reportId/users"

        if ($PSCmdlet.ShouldProcess("Report $ReportName ($reportId)", "Grant $AccessRight to group $principalId")) {
            Write-Verbose "Granting $AccessRight access to report via Power BI REST: $url"
            try {
                # Use Power BI REST cmdlet to ensure correct token/resource
                Invoke-PowerBIRestMethod -Url $url -Method Post -Body $body -ContentType 'application/json' -ErrorAction Stop | Out-Null
            } catch {
                if ($_.Exception.Message -match 'Unauthorized|403') {
                    $errMsg = @"
Failed to grant report access: Unauthorized

This error typically occurs when:
1. You are not a workspace Admin or Member (need at least Contributor role)
2. The workspace is configured to restrict permission changes
3. You need Power BI Service Administrator rights

To resolve:
- Verify you have Admin/Member role on workspace '$($ws.Name)'
- Check with workspace owner if permission changes are restricted
- If you're a Power BI Service Admin, ensure you've enabled admin mode in your connection

Current user: $((Get-PowerBIAccessToken).Username)
Workspace: $($ws.Name) ($workspaceId)
Report: $($report.Name) ($reportId)
"@
                    throw $errMsg
                }
                throw
            }
        }

        # Build share link
        # Build a stable share link (permissions required). Tenant hint omitted intentionally for reliability across contexts.
        $shareLink = "https://app.powerbi.com/groups/$workspaceId/reports/$reportId"

        $result = [PSCustomObject]@{
            ReportName   = $report.Name
            WorkspaceName= $ws.Name
            WorkspaceId  = $workspaceId
            ReportId     = $reportId
            GrantedTo    = $principalName
            GrantedToId  = $principalId
            AccessRight  = $AccessRight
            ShareLink    = $shareLink
        }

        if ($PassThru) { return $result } else { $result | Out-String | Write-Verbose }
        $result

    } catch {
        Write-Error "Failed to grant report access: $_"
        return $null
    }
}
