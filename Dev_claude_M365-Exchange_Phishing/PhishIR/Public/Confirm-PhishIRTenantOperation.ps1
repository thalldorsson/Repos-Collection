function Confirm-PhishIRTenantOperation {
    <#
    .SYNOPSIS
    Enforce tenant approval phrases for destructive PhishIR operations.

    .DESCRIPTION
    Validates that a provided confirmation phrase matches the tenant's configured approval phrase
    for the specified operation (Purge or HardDelete). If approvals are not required for the tenant
    the confirmation auto-approves. Supports Force override for automation scenarios. Throws on
    mismatch unless Force is used.

    Expected tenant.approvals properties:
      requireApproval (bool)
      purgePhrase (string)        -> used when -Operation Purge
      hardDeletePhrase (string)   -> used when -Operation HardDelete

    .PARAMETER Tenant
    Tenant object from Get-PhishIRTenantConfig.

    .PARAMETER Operation
    Operation requiring confirmation. Supported: Purge, HardDelete.

    .PARAMETER Phrase
    The user-provided confirmation phrase. Must match configured phrase exactly (case-sensitive)
    unless -Force is specified.

    .PARAMETER Force
    Bypass phrase enforcement (still records decision). Use sparingly and only in controlled automation.

    .OUTPUTS
    PSCustomObject containing Approval metadata (Approved, Operation, ExpectedPhraseHash, ProvidedPhraseHash, Forced, TenantDisplayName).

    .EXAMPLE
    $cfg = Get-PhishIRTenantConfig -Validate
    Confirm-PhishIRTenantOperation -Tenant $cfg.tenants[0] -Operation Purge -Phrase "CONFIRM: purge approved for Contoso"

    .EXAMPLE
    Confirm-PhishIRTenantOperation -Tenant $tenant -Operation HardDelete -Phrase "wrong" -Force
    # Returns Approved with Forced=$true despite mismatch.

    .NOTES
    Hashes (SHA256 prefix) used instead of exposing full phrases in logs/outputs.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)][object]$Tenant,
        [Parameter(Mandatory)][ValidateSet('Purge','HardDelete')][string]$Operation,
        [Parameter()][string]$Phrase,
        [switch]$Force
    )

    $approved = $false
    $forced = $false
    $expectedPhrase = $null
    $propName = if ($Operation -eq 'Purge') { 'purgePhrase' } else { 'hardDeletePhrase' }

    if (-not ($Tenant.PSObject.Properties.Name -contains 'approvals') -or -not $Tenant.approvals) {
        # No approvals block at all => auto approve
        $approved = $true
        $expectedPhrase = '<none>'
    } elseif (-not ($Tenant.approvals.PSObject.Properties.Name -contains 'requireApproval') -or -not $Tenant.approvals.requireApproval) {
        $approved = $true
        $expectedPhrase = '<not-required>'
    } else {
        if (-not ($Tenant.approvals.PSObject.Properties.Name -contains $propName)) {
            throw "Tenant '$($Tenant.displayName)' missing expected approvals property '$propName'"
        }
        $expectedPhrase = $Tenant.approvals.$propName
        if (-not $expectedPhrase) {
            throw "Tenant '$($Tenant.displayName)' missing expected approvals property '$propName'"
        }
        if ($Force) {
            $approved = $true
            $forced = $true
        } else {
            if (-not $Phrase) {
                throw "Confirmation phrase required for operation $Operation on tenant '$($Tenant.displayName)'"
            }
            if ($Phrase -ceq $expectedPhrase) {
                $approved = $true
            } else {
                throw "Approval phrase mismatch for operation $Operation on tenant '$($Tenant.displayName)'"
            }
        }
    }

    $expectedHash = if ($expectedPhrase -and $expectedPhrase -notin '<none>','<not-required>') { (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($expectedPhrase))) -Algorithm SHA256).Hash.Substring(0,12) } else { $expectedPhrase }
    $providedHash = if ($Phrase) { (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($Phrase))) -Algorithm SHA256).Hash.Substring(0,12) } else { '<none>' }

    [PSCustomObject]@{
        Approved = $approved
        Forced = $forced
        Operation = $Operation
        TenantDisplayName = $Tenant.displayName
        ExpectedPhraseHash = $expectedHash
        ProvidedPhraseHash = $providedHash
        Timestamp = (Get-Date).ToString('o')
    }
}

Export-ModuleMember -Function Confirm-PhishIRTenantOperation
