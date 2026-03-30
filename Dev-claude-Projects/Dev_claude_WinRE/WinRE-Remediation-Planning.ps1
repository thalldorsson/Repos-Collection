param(
    [Parameter(Mandatory=$true)]
    [string]$WorkspaceId,

    [Parameter(Mandatory=$true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory=$true)]
    [string]$SubscriptionId,

    [int]$MaxDevices = 200
)

# WinRE Remediation Planning Helper
# Reads WinREHealth_CL from Log Analytics and exports a CSV of auto-remediation candidates

Write-Host "[WinRE] Building remediation planning export from workspace $WorkspaceId..." -ForegroundColor Cyan

Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.OperationalInsights -ErrorAction Stop

Select-AzSubscription -SubscriptionId $SubscriptionId | Out-Null

$ws = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroup -Name $WorkspaceId -ErrorAction Stop

$kql = @"
WinREHealth_CL
| where KB5034441Vulnerable_b == true
| where RemediationReady_b == true
| project TimeGenerated, ComputerName_s, Manufacturer_s, Model_s, Domain_s,
          Severity_s, PartitionSizeMB_d, PartitionFreeMB_d, SupportedMaxSizeMB_d,
          CanGrowTo500MB_b, IsLastPartition_b, AdjacentToOSPartition_b,
          TpmPresent_b, TpmReady_b, PendingReboot_b,
          RecommendedAction_s, RecommendedActionCode_s
| top $MaxDevices by TimeGenerated desc
"@

$results = Invoke-AzOperationalInsightsQuery -WorkspaceId $ws.CustomerId -Query $kql -ErrorAction Stop

if ($results.Tables[0].Rows.Count -eq 0) {
    Write-Host "[WinRE] No remediation candidates found (RemediationReady == true)." -ForegroundColor Yellow
    return
}

$rows = $results.Tables[0] | ConvertTo-Json | ConvertFrom-Json

$outPath = Join-Path (Get-Location) "WinRE-Remediation-Candidates.csv"
$rows.Rows | ForEach-Object {
    [PSCustomObject]@{
        TimeGenerated          = $_[0]
        ComputerName           = $_[1]
        Manufacturer           = $_[2]
        Model                  = $_[3]
        Domain                 = $_[4]
        Severity               = $_[5]
        PartitionSizeMB        = $_[6]
        PartitionFreeMB        = $_[7]
        SupportedMaxSizeMB     = $_[8]
        CanGrowTo500MB         = $_[9]
        IsLastPartition        = $_[10]
        AdjacentToOSPartition  = $_[11]
        TpmPresent             = $_[12]
        TpmReady               = $_[13]
        PendingReboot          = $_[14]
        RecommendedAction      = $_[15]
        RecommendedActionCode  = $_[16]
    }
} | Export-Csv -NoTypeInformation -Path $outPath -Encoding UTF8

Write-Host "[WinRE] Exported remediation candidates to $outPath" -ForegroundColor Green
