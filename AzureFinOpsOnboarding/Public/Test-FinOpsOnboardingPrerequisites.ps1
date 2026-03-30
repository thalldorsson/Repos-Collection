function Test-FinOpsOnboardingPrerequisites {
    <#
    .SYNOPSIS
        Lightweight pre-flight check before running FinOps onboarding.

    .DESCRIPTION
        Validates essentials only:
        - PowerShell version (5.1 supported, 7+ preferred)
        - Required modules (Az.Accounts required, MicrosoftPowerBIMgmt optional)
        - Service principal authentication via Get-FinOpsBearerToken
        - Subscription visibility via Test-FinOpsAzSubscriptions

    .PARAMETER TenantId
        Entra tenant ID (GUID).

    .PARAMETER ApplicationId
        Service principal app/client ID (GUID).

    .PARAMETER ClientSecret
        Service principal client secret as SecureString.

    .PARAMETER SkipModuleChecks
        Skip module presence checks.

    .PARAMETER SkipSubscriptionCheck
        Skip subscription visibility test.

    .PARAMETER PassThru
        Return result object without console summary.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')][string]$TenantId,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')][string]$ApplicationId,
        [Parameter(Mandatory)][SecureString]$ClientSecret,
        [switch]$SkipModuleChecks,
        [switch]$SkipSubscriptionCheck,
        [switch]$PassThru
    )

    $result = [PSCustomObject]@{
        OverallSuccess = $false
        PowerShellOk   = $false
        Modules        = @()
        ModulesOk      = $true
        AuthOk         = $false
        SubscriptionOk = $false
        CheckedAt      = Get-Date
    }

    # PowerShell version (5.1+)
    $psv = $PSVersionTable.PSVersion
    $result.PowerShellOk = ($psv.Major -gt 5) -or ($psv.Major -eq 5 -and $psv.Minor -ge 1)
    if (-not $result.PowerShellOk) {
        Write-Error "PowerShell 5.1 or 7+ required (detected $psv)"
    }
    elseif ($psv.Major -eq 5) {
        Write-Verbose "PowerShell 5.1 detected; 7+ recommended for best compatibility."
    }

    # Module presence
    if (-not $SkipModuleChecks) {
        $modulesToCheck = @(
            @{ Name='Az.Accounts'; Required=$true }
            @{ Name='MicrosoftPowerBIMgmt'; Required=$false }
        )

        foreach ($m in $modulesToCheck) {
            $installed = Get-Module -ListAvailable -Name $m.Name | Select-Object -First 1
            $result.Modules += [PSCustomObject]@{ Name=$m.Name; Required=$m.Required; Installed=[bool]$installed }
            if ($m.Required -and -not $installed) {
                $result.ModulesOk = $false
                Write-Warning "Required module $($m.Name) not installed. Install-Module -Name $($m.Name) -Scope CurrentUser"
            }
        }
    }

    # Authentication
    try {
        $token = Get-FinOpsBearerToken -TenantId $TenantId -ApplicationId $ApplicationId -ClientSecret $ClientSecret -ErrorAction Stop
        $result.AuthOk = [bool]$token
    }
    catch {
        Write-Error "Failed to acquire bearer token: $($_.Exception.Message)"
    }

    # Subscription visibility
    if (-not $SkipSubscriptionCheck -and $result.AuthOk) {
        try {
            $subs = Test-FinOpsAzSubscriptions -Token $token -ErrorAction Stop
            $result.SubscriptionOk = [bool]$subs.Success
        }
        catch {
            Write-Warning "Subscription visibility check failed: $($_.Exception.Message)"
        }
    }

    $checks = @($result.PowerShellOk, $result.AuthOk)
    if (-not $SkipModuleChecks) { $checks += $result.ModulesOk }
    if (-not $SkipSubscriptionCheck) { $checks += $result.SubscriptionOk }
    $result.OverallSuccess = ($checks -notcontains $false)

    if ($PassThru) { return $result }
    $result
}
