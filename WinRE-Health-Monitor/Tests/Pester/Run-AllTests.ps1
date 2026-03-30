#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

$Config = New-PesterConfiguration
$Config.Run.Path = "$PSScriptRoot"
$Config.Output.Verbosity = 'Detailed'
$Config.CodeCoverage.Enabled = $true
$Config.CodeCoverage.Path = @(
    "$PSScriptRoot\..\..\Scripts\**\*.ps1",
    "$PSScriptRoot\..\..\Scripts\**\*.psm1"
)
$Config.TestResult.Enabled = $true
$Config.TestResult.OutputFormat = 'NUnitXml'
$Config.TestResult.OutputPath = "$PSScriptRoot\..\..\test-results-pester.xml"

Invoke-Pester -Configuration $Config
