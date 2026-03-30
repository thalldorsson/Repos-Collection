function Update-PhishIRTenantRateLimits {
    <#
    .SYNOPSIS
    Adapt tenant execution concurrency and rate limits based on telemetry.
    .DESCRIPTION
    Reads a telemetry file (JSON lines) capturing operation attempts/failures per tenant and
    adjusts execution.concurrency within configured min/max boundaries. Increase concurrency
    if recent failure ratio is below successBoostThreshold; decrease if above failureThreshold.
    .PARAMETER Tenant
    Tenant object (from Get-PhishIRTenantConfig).
    .PARAMETER TelemetryPath
    Path to telemetry file. Defaults to PHISHIR_TELEMETRY_PATH or storage base path + 'phishir-tenant-telemetry.jsonl'.
    .PARAMETER DryRun
    Show proposed changes without applying.
    .OUTPUTS
    PSCustomObject summarizing adjustment.
    .EXAMPLE
    $cfg = Get-PhishIRTenantConfig -Validate
    Update-PhishIRTenantRateLimits -Tenant $cfg.tenants[0]
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)][object]$Tenant,
        [string]$TelemetryPath,
        [switch]$DryRun
    )
    if (-not $Tenant.rateAdaptation.enabled) { return [PSCustomObject]@{ Adjusted=$false; Reason='Rate adaptation disabled'; Concurrency=$Tenant.execution.concurrency } }

    if (-not $TelemetryPath) {
        if ($env:PHISHIR_TELEMETRY_PATH) { $TelemetryPath = $env:PHISHIR_TELEMETRY_PATH } else { $TelemetryPath = Join-Path $env:TEMP 'phishir-tenant-telemetry.jsonl' }
    }
    if (-not (Test-Path $TelemetryPath)) { return [PSCustomObject]@{ Adjusted=$false; Reason='Telemetry file not found'; Path=$TelemetryPath; Concurrency=$Tenant.execution.concurrency } }

    $window = $Tenant.rateAdaptation.telemetryWindow
    $failureThreshold = $Tenant.rateAdaptation.failureThreshold
    $successBoostThreshold = $Tenant.rateAdaptation.successBoostThreshold
    $minC = $Tenant.rateAdaptation.minConcurrency
    $maxC = $Tenant.rateAdaptation.maxConcurrency
    $baseC = $Tenant.execution.baseConcurrency

    $records = Get-Content -Path $TelemetryPath -ErrorAction SilentlyContinue | Select-Object -Last $window | ForEach-Object { $_ | ConvertFrom-Json }
    $tenantRecords = $records | Where-Object { $_.tenantId -eq $Tenant.tenantId }
    if (-not $tenantRecords) { return [PSCustomObject]@{ Adjusted=$false; Reason='No records for tenant'; Concurrency=$Tenant.execution.concurrency } }

    $attempted = ($tenantRecords | Measure-Object -Property operationsAttempted -Sum).Sum
    $failed = ($tenantRecords | Measure-Object -Property operationsFailed -Sum).Sum
    if (-not $attempted -or $attempted -eq 0) { return [PSCustomObject]@{ Adjusted=$false; Reason='No attempted ops'; Concurrency=$Tenant.execution.concurrency } }
    $ratio = [math]::Round($failed / $attempted, 4)

    $current = $Tenant.execution.concurrency
    $new = $current
    $action = 'none'

    if ($ratio -gt $failureThreshold) {
        $new = [math]::Max($current - 1, $minC)
        $action = 'decrease'
    } elseif ($ratio -lt $successBoostThreshold -and $current -lt $maxC) {
        $new = [math]::Min($current + 1, $maxC)
        $action = 'increase'
    }

    if ($DryRun) {
        return [PSCustomObject]@{ Adjusted=($new -ne $current); Action=$action; FailureRatio=$ratio; OldConcurrency=$current; NewConcurrency=$new; DryRun=$true }
    }

    $Tenant.execution.concurrency = $new
    [PSCustomObject]@{ Adjusted=($new -ne $current); Action=$action; FailureRatio=$ratio; OldConcurrency=$current; NewConcurrency=$new; DryRun=$false }
}

Export-ModuleMember -Function Update-PhishIRTenantRateLimits
