<#
Pester tests for rate limit adaptation (dry run)
#>
Import-Module ../PhishIR/PhishIR.psd1 -Force
Describe 'Update-PhishIRTenantRateLimits dry run' {
    $config = Get-PhishIRTenantConfig -Validate
    $tenant = $config.tenants | Select-Object -First 1
    It 'Runs without throwing' {
        { Update-PhishIRTenantRateLimits -Tenant $tenant -DryRun } | Should -Not -Throw
    }
}
