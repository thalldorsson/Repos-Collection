Import-Module 'c:\Git-Repos-Crayon-User\Projects\Dev_claude_M365-Exchange_Phishing\PhishIR\PhishIR.psm1' -Force -ErrorAction Stop
Write-Output 'Module import: SUCCESS'
$exported = (Get-Command -Module PhishIR).Name
Write-Output "Exported functions: $($exported.Count)"
Write-Output 'Key functions validation:'
@('Invoke-MailPurge','Get-MailboxPersistenceArtifacts','Build-ContentMatchQuery') | ForEach-Object {
    if($exported -contains $_){
        Write-Output "  ✓ $_"
    } else {
        Write-Output "  ✗ $_ MISSING"
    }
}
