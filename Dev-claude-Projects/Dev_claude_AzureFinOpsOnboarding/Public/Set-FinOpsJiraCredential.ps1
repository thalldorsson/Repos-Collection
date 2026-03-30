function Set-FinOpsJiraCredential {
    <#!
.SYNOPSIS
    Caches Jira username and API token (SecureString) for subsequent Jira helper commands.
.DESCRIPTION
    Stores credentials in module script scope variables so all Jira functions can be invoked without specifying -Username / -ApiToken each time.
    Also sets an Authorization header used internally. Does not persist to disk. You can clear with Clear-AfoJiraCredential (future) or by reloading the session.
.PARAMETER Username
    Jira account email.
.PARAMETER ApiToken
    Jira API token as SecureString (preferred). If you only have a plain text token, convert with: $tok = Read-Host 'Token' -AsSecureString
.EXAMPLE
    $tok = Read-Host 'Jira API token' -AsSecureString
    Set-FinOpsJiraCredential -Username you@org.com -ApiToken $tok
    Get-FinOpsJiraIssue -IssueKey ABC-1   # no need to pass -Username/-ApiToken
#>
    [CmdletBinding()] param(
        [Parameter(Mandatory)][ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')][string]$Username,
        [Parameter(Mandatory)][SecureString]$ApiToken
    )
    $script:AfoJiraUsername = $Username
    $script:AfoJiraApiToken = $ApiToken
    Write-Verbose "Jira credential cached for $Username"
}
