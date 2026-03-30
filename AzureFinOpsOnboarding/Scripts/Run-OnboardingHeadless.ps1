param(
  [Parameter(Mandatory)][string]$TenantId,
  [Parameter(Mandatory)][string]$ApplicationId,
  [Parameter(Mandatory)][string]$CustomerName,
  [Parameter(Mandatory)][string]$PrimaryDomain,
  [Parameter(Mandatory)][SecureString]$ClientSecret,
  [switch]$IsEA
)
Import-Module (Join-Path $PSScriptRoot '..' 'AzureFinOpsOnboarding.psd1') -Force
Invoke-FinOpsOnboarding -TenantId $TenantId -ApplicationId $ApplicationId -ClientSecret $ClientSecret -CustomerName $CustomerName -PrimaryDomain $PrimaryDomain -IsEA:$IsEA -Verbose -PassThru | Format-List
