
function Undo-FinOpsOnboarding {
    <#
    .SYNOPSIS
        Minimal rollback helper for FinOps onboarding artifacts.

    .DESCRIPTION
        Best-effort cleanup guarded by -Force and ShouldProcess. If helper functions
        are available, it will:
        - Revoke Power BI access via Revoke-FinOpsPowerBIReportAccess (if EntraGroupId provided)
        - Remove webhooks via Get-FinOpsWebhooks/Remove-FinOpsWebhook
        - Add a Jira comment via Add-FinOpsJiraComment
        No database deletion is performed in this minimal version.

    .PARAMETER OrchestratorResult
        Optional Invoke-FinOpsOnboarding result object to auto-fill TenantId, CustomerName, JiraIssueKey.

    .PARAMETER TenantId
        Customer tenant ID (GUID).

    .PARAMETER CustomerName
        Customer display name.

    .PARAMETER EntraGroupId
        Entra group ID that was granted report access (if known). Used for Power BI revoke.

    .PARAMETER JiraIssueKey
        Jira issue key for audit comment.

    .PARAMETER Force
        Required to proceed with rollback actions.

    .PARAMETER SkipPowerBIRevoke
        Skip Power BI access revoke step.

    .PARAMETER SkipWebhookRemoval
        Skip webhook removal step.

    .PARAMETER SkipJiraComment
        Skip Jira comment step.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param(
        [Parameter(ParameterSetName='Orchestrator')][pscustomobject]$OrchestratorResult,
        [Parameter(ParameterSetName='Manual')][ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')][string]$TenantId,
        [Parameter(ParameterSetName='Manual')][string]$CustomerName,
        [string]$EntraGroupId,
        [string]$JiraIssueKey,
        [switch]$Force,
        [switch]$SkipPowerBIRevoke,
        [switch]$SkipWebhookRemoval,
        [switch]$SkipJiraComment
    )

    if ($PSCmdlet.ParameterSetName -eq 'Orchestrator' -and $OrchestratorResult) {
        if (-not $TenantId)     { $TenantId    = $OrchestratorResult.TenantId }
        if (-not $CustomerName) { $CustomerName = $OrchestratorResult.CustomerName }
        if (-not $JiraIssueKey) { $JiraIssueKey = $OrchestratorResult.JiraIssueKey }
    }

    if (-not $TenantId -or -not $CustomerName) {
        throw "TenantId and CustomerName are required."
    }

    if (-not $Force) {
        Write-Warning "Rollback requires -Force. Use -WhatIf to preview."
        return
    }

    $result = [PSCustomObject]@{
        Success          = $true
        CustomerName     = $CustomerName
        TenantId         = $TenantId
        PowerBIRevoked   = $false
        DatabaseDeleted  = $false
        WebhooksRemoved  = 0
        JiraCommentAdded = $false
        Errors           = @()
        CompletedAt      = $null
    }

    if ($PSCmdlet.ShouldProcess("Tenant $TenantId", "Rollback onboarding for $CustomerName")) {
        # Power BI revoke (if helper + group id provided)
        if (-not $SkipPowerBIRevoke -and $EntraGroupId -and (Get-Command Revoke-FinOpsPowerBIReportAccess -ErrorAction SilentlyContinue)) {
            try {
                Revoke-FinOpsPowerBIReportAccess -EntraGroupId $EntraGroupId -ReportName 'FinOps Overview' -ErrorAction Stop | Out-Null
                $result.PowerBIRevoked = $true
            }
            catch {
                $result.Errors += $_.Exception.Message
                $result.Success = $false
            }
        }

        # Webhook cleanup
        if (-not $SkipWebhookRemoval -and (Get-Command Get-FinOpsWebhooks -ErrorAction SilentlyContinue) -and (Get-Command Remove-FinOpsWebhook -ErrorAction SilentlyContinue)) {
            try {
                $hooks = Get-FinOpsWebhooks | Where-Object { $_.Context.CustomerName -eq $CustomerName }
                foreach ($h in $hooks) {
                    try {
                        Remove-FinOpsWebhook -Name $h.Name -ErrorAction Stop
                        $result.WebhooksRemoved++
                    }
                    catch {
                        $result.Errors += $_.Exception.Message
                        $result.Success = $false
                    }
                }
            }
            catch {
                $result.Errors += $_.Exception.Message
                $result.Success = $false
            }
        }

        # Jira comment
        if (-not $SkipJiraComment -and $JiraIssueKey -and (Get-Command Add-FinOpsJiraComment -ErrorAction SilentlyContinue)) {
            try {
                Add-FinOpsJiraComment -IssueKey $JiraIssueKey -Comment "Rollback executed for $CustomerName ($TenantId)" -ErrorAction Stop
                $result.JiraCommentAdded = $true
            }
            catch {
                $result.Errors += $_.Exception.Message
                $result.Success = $false
            }
        }

        $result.CompletedAt = Get-Date
    }

    return $result
}
