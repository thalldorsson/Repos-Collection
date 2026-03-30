#Requires -Module Pester

BeforeAll {
    $moduleRoot = Join-Path -Path $PSScriptRoot -ChildPath '..'
    $modulePath = Join-Path -Path $moduleRoot -ChildPath 'PhishIR.psd1'
    Import-Module $modulePath -Force

    $samplesDir = Join-Path $moduleRoot '..' | Join-Path -ChildPath 'samples'
    $script:SamplePath = Join-Path $samplesDir 'tenants.sample.json'
}

Describe 'Get-PhishIRTenantConfig' {
    It 'Should load sample configuration and return tenants' {
        $cfg = Get-PhishIRTenantConfig -Path $SamplePath -Validate
        $cfg.version | Should -Be '1.0'
        $cfg.tenants.Count | Should -BeGreaterThan 0
        $cfg.tenants[0].displayName | Should -Not -BeNullOrEmpty
        $cfg.tenants[0].resolvedMailboxes.Count | Should -BeGreaterThan 0
    }

    It 'Should apply PHISHIR_OUTPUT_ROOT override' {
        $env:PHISHIR_OUTPUT_ROOT = 'C:/OverrideRoot'
        $cfg = Get-PhishIRTenantConfig -Path $SamplePath -Validate
        ($cfg.tenants | ForEach-Object { $_.output.root } | Select-Object -Unique) | Should -Contain 'C:/OverrideRoot'
        Remove-Item Env:PHISHIR_OUTPUT_ROOT -ErrorAction SilentlyContinue
    }

    It 'Should fall back to default root token when no env override' {
        $cfg = Get-PhishIRTenantConfig -Path $SamplePath -Validate
        ($cfg.tenants | ForEach-Object { $_.output.root } | Select-Object -Unique) | Should -Contain './out'
    }

    It 'Should throw when required field missing' {
        # Create a broken temp file (missing tenantId, tenantDomain, featureFlags, output)
        $broken = '{"version":"1.0","tenants":[{"displayName":"X"}]}'
        $tempPath = Join-Path $TestDrive 'broken-tenants.json'
        $broken | Out-File -FilePath $tempPath -Encoding UTF8
        { Get-PhishIRTenantConfig -Path $tempPath -Validate } | Should -Throw
    }
}

Describe 'Confirm-PhishIRTenantOperation' {
    BeforeAll {
        $cfg = Get-PhishIRTenantConfig -Path $SamplePath -Validate
        $script:Tenant = $cfg.tenants[0]
    }

    It 'Approves purge with correct phrase' {
        $result = Confirm-PhishIRTenantOperation -Tenant $Tenant -Operation Purge -Phrase $Tenant.approvals.purgePhrase
        $result.Approved | Should -BeTrue
        $result.Forced | Should -BeFalse
    }

    It 'Throws on incorrect phrase' {
        { Confirm-PhishIRTenantOperation -Tenant $Tenant -Operation Purge -Phrase 'WRONG PHRASE' } | Should -Throw
    }

    It 'Bypasses with Force even when phrase incorrect' {
        $result = Confirm-PhishIRTenantOperation -Tenant $Tenant -Operation Purge -Phrase 'WRONG' -Force
        $result.Approved | Should -BeTrue
        $result.Forced   | Should -BeTrue
    }
}

Describe 'Update-PhishIRTenantRateLimits (adaptation)' {
    It 'Should propose increase when failure ratio below successBoostThreshold' {
        $cfg = Get-PhishIRTenantConfig -Path $SamplePath -Validate
        $tenant = $cfg.tenants[0]
        # Use sample telemetry content
        $telemetryContent = Get-Content -Path (Join-Path $samplesDir 'telemetry.sample.jsonl') -Raw
        $telemetryPath = Join-Path $TestDrive 'telemetry.jsonl'
        $telemetryContent | Out-File -FilePath $telemetryPath -Encoding UTF8
        $env:PHISHIR_TELEMETRY_PATH = $telemetryPath
        $dry = Update-PhishIRTenantRateLimits -Tenant $tenant -DryRun
        $dry.Action | Should -Be 'increase'
        $dry.NewConcurrency | Should -Be ($tenant.execution.concurrency + 1)
        Remove-Item Env:PHISHIR_TELEMETRY_PATH -ErrorAction SilentlyContinue
    }
}
