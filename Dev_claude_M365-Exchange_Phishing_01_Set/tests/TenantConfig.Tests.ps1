<#
Pester tests for tenant configuration loader
#>
Import-Module ../PhishIR/PhishIR.psd1 -Force
Describe 'Get-PhishIRTenantConfig' {
    It 'Loads configuration successfully' {
        $config = Get-PhishIRTenantConfig -Validate
        $config | Should -Not -BeNullOrEmpty
        $config.tenants | Should -Not -BeNullOrEmpty
    }
    It 'Contains schemaVersion after overlay merge (node layer)' -Skip {
        # Placeholder - node overlay logic not directly testable here
    }
}
