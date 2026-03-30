<#
Pester tests for Office macro hardening detection
#>
Describe 'Set-OfficeMacroHardeningLocal.ps1 detection' {
    It 'Detects current state without enforcement' {
        $script = Join-Path (Get-Location) 'Set-OfficeMacroHardeningLocal.ps1'
        $output = & $script -WhatIf 2>&1 | Out-String
        $output | Should -Match 'Detected current user policy state'
    }
}
