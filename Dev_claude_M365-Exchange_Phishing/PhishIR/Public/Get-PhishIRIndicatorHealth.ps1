function Get-PhishIRIndicatorHealth {
    <#
    .SYNOPSIS
    Generate health summary and statistics for Defender threat indicators.

    .DESCRIPTION
    Analyzes current Defender for Endpoint threat indicators and generates comprehensive
    health metrics including:
    - Total active indicators by action type (Block/Allow/Warn)
    - Expiration distribution (expiring soon, expired)
    - Threat type breakdown
    - Performance metrics (submission success rate, propagation status)
    - Recommendations for cleanup and renewal

    .PARAMETER IncludeExpired
    Include expired indicators in analysis. Default is active indicators only.

    .PARAMETER ExpiringWithinDays
    Highlight indicators expiring within specified days. Default is 7.

    .PARAMETER ExportPath
    Optional path to export health report as JSON or CSV.

    .PARAMETER Format
    Export format: JSON or CSV. Default is JSON.

    .EXAMPLE
    Get-PhishIRIndicatorHealth

    Display health summary of active indicators.

    .EXAMPLE
    Get-PhishIRIndicatorHealth -ExpiringWithinDays 30 -ExportPath ".\indicator-health.json"

    Generate report showing indicators expiring in next 30 days and export to JSON.

    .NOTES
    Requires:
    - Microsoft.Graph.Beta.Security module
    - ThreatIndicators.Read.All or ThreatIndicators.ReadWrite.OwnedBy permission
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$IncludeExpired,

        [Parameter()]
        [int]$ExpiringWithinDays = 7,

        [Parameter()]
        [string]$ExportPath,

        [Parameter()]
        [ValidateSet('JSON', 'CSV')]
        [string]$Format = 'JSON'
    )

    try {
        Write-Host "Analyzing Defender threat indicators..." -ForegroundColor Cyan

        # Query indicators
        $now = (Get-Date).ToUniversalTime()
        $expiringThreshold = $now.AddDays($ExpiringWithinDays)

        $allIndicators = Get-MgBetaSecurityTiIndicator -All -ErrorAction Stop

        # Filter to Defender ATP indicators
        $defenderIndicators = $allIndicators | Where-Object { $_.TargetProduct -eq 'Microsoft Defender ATP' }

        # Categorize indicators
        $active = $defenderIndicators | Where-Object { [datetime]$_.ExpirationDateTime -gt $now }
        $expired = $defenderIndicators | Where-Object { [datetime]$_.ExpirationDateTime -le $now }
        $expiringSoon = $active | Where-Object { [datetime]$_.ExpirationDateTime -le $expiringThreshold }

        # Build health summary
        $health = [PSCustomObject]@{
            Timestamp = $now.ToString('o')
            TotalIndicators = $defenderIndicators.Count
            ActiveIndicators = $active.Count
            ExpiredIndicators = $expired.Count
            ExpiringSoon = @{
                Count = $expiringSoon.Count
                WithinDays = $ExpiringWithinDays
            }
            ByAction = @{
                Block = ($active | Where-Object { $_.Action -eq 'block' }).Count
                Allow = ($active | Where-Object { $_.Action -eq 'allow' }).Count
                Warn = ($active | Where-Object { $_.Action -eq 'warn' }).Count
                Alert = ($active | Where-Object { $_.Action -eq 'alert' }).Count
            }
            ByThreatType = @{}
            ByIndicatorType = @{
                Url = ($active | Where-Object { $_.Url }).Count
                Domain = ($active | Where-Object { $_.DomainName }).Count
                IpAddress = ($active | Where-Object { $_.NetworkIPv4 -or $_.NetworkIPv6 }).Count
            }
            Recommendations = @()
        }

        # Threat type breakdown
        $threatTypes = $active | Group-Object -Property ThreatType
        foreach ($type in $threatTypes) {
            $health.ByThreatType[$type.Name] = $type.Count
        }

        # Generate recommendations
        if ($expired.Count -gt 0) {
            $health.Recommendations += "Clean up $($expired.Count) expired indicators using Remove-PhishIRDefenderIndicators"
        }
        if ($expiringSoon.Count -gt 0) {
            $health.Recommendations += "Review $($expiringSoon.Count) indicators expiring within $ExpiringWithinDays days for renewal"
        }
        if ($active.Count -eq 0) {
            $health.Recommendations += "No active indicators found. Verify indicator submission and propagation"
        }
        if (($active | Where-Object { $_.Action -eq 'allow' }).Count -eq 0) {
            $health.Recommendations += "Consider adding Allow indicators for trusted domains to prevent false positives"
        }

        # Display summary
        Write-Host "`n=== Defender Indicator Health Summary ===" -ForegroundColor Green
        Write-Host "Timestamp: $($health.Timestamp)" -ForegroundColor Gray
        Write-Host "`nIndicator Counts:" -ForegroundColor Cyan
        Write-Host "  Total: $($health.TotalIndicators)"
        Write-Host "  Active: $($health.ActiveIndicators)" -ForegroundColor Green
        Write-Host "  Expired: $($health.ExpiredIndicators)" -ForegroundColor $(if ($expired.Count -gt 0) { 'Yellow' } else { 'Gray' })
        Write-Host "  Expiring Soon ($ExpiringWithinDays days): $($expiringSoon.Count)" -ForegroundColor $(if ($expiringSoon.Count -gt 0) { 'Yellow' } else { 'Gray' })

        Write-Host "`nBy Action Type:" -ForegroundColor Cyan
        Write-Host "  Block: $($health.ByAction.Block)"
        Write-Host "  Allow: $($health.ByAction.Allow)"
        Write-Host "  Warn: $($health.ByAction.Warn)"
        Write-Host "  Alert/Audit: $($health.ByAction.Alert)"

        Write-Host "`nBy Indicator Type:" -ForegroundColor Cyan
        Write-Host "  URLs: $($health.ByIndicatorType.Url)"
        Write-Host "  Domains: $($health.ByIndicatorType.Domain)"
        Write-Host "  IP Addresses: $($health.ByIndicatorType.IpAddress)"

        if ($health.ByThreatType.Count -gt 0) {
            Write-Host "`nBy Threat Type:" -ForegroundColor Cyan
            $health.ByThreatType.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
                Write-Host "  $($_.Key): $($_.Value)"
            }
        }

        if ($health.Recommendations.Count -gt 0) {
            Write-Host "`nRecommendations:" -ForegroundColor Yellow
            $health.Recommendations | ForEach-Object {
                Write-Host "  • $_" -ForegroundColor Yellow
            }
        }

        # Export if requested
        if ($ExportPath) {
            if ($Format -eq 'JSON') {
                $health | ConvertTo-Json -Depth 10 | Out-File -FilePath $ExportPath -Force
            } else {
                # Flatten for CSV
                $csvData = [PSCustomObject]@{
                    Timestamp = $health.Timestamp
                    TotalIndicators = $health.TotalIndicators
                    ActiveIndicators = $health.ActiveIndicators
                    ExpiredIndicators = $health.ExpiredIndicators
                    ExpiringSoonCount = $health.ExpiringSoon.Count
                    BlockCount = $health.ByAction.Block
                    AllowCount = $health.ByAction.Allow
                    WarnCount = $health.ByAction.Warn
                    AlertCount = $health.ByAction.Alert
                    UrlCount = $health.ByIndicatorType.Url
                    DomainCount = $health.ByIndicatorType.Domain
                    IpCount = $health.ByIndicatorType.IpAddress
                }
                $csvData | Export-Csv -Path $ExportPath -NoTypeInformation -Force
            }
            Write-Host "`n✓ Health report exported to: $ExportPath" -ForegroundColor Green
        }

        return $health

    } catch {
        Write-Error "Failed to generate indicator health report: $($PSItem.Exception.Message)"
        throw
    }
}

