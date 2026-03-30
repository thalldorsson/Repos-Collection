function Write-FinOpsReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$OrchestratorObject
    )
    $o = $OrchestratorObject
    $checks = $o.Checks
    $statusEmoji = @{ True = '✅'; False = '❌' }
    $lines = @()
    $lines += "# Azure FinOps Onboarding Report"
    $lines += "Generated: $($o.GeneratedAt)"
    $lines += "Tool Version: $($o.ToolVersion)"
    $lines += ""
    $lines += "## Customer"
    $lines += "- Name: $($o.Customer.Name)"
    $lines += "- Primary Domain: $($o.Customer.PrimaryDomain)"
    $lines += "- Tenant Id: $($o.Customer.TenantId)"
    $lines += "- Application Id: $($o.Customer.ApplicationId)"
    $lines += "- Is EA: $($o.Customer.IsEA)"
    if ($o.Customer.CompanyName) { $lines += "- Company Name: $($o.Customer.CompanyName)" }
    if ($o.Customer.Country) { $lines += "- Country: $($o.Customer.Country)" }
    if ($o.Customer.TenantName) { $lines += "- Tenant Name: $($o.Customer.TenantName)" }
    $lines += ""
    $lines += "## Identifiers"
    $lines += "- Enrollment Id: $($o.Identifiers.EnrollmentId)"
    $lines += "- MCA Billing Id: $($o.Identifiers.MCABillingId)"
    $lines += "- Secret Name: $($o.Identifiers.SecretName)"
    $lines += "- Secret Expiry: $($o.Identifiers.SecretExpiry)"
    $lines += ""
    $lines += "## Check Summary"
    $lines += "| Check | Status | Metrics |"
    $lines += "|-------|--------|---------|"
    foreach ($c in $checks) {
        $metricStr = if ($c.Metrics) { ($c.Metrics.GetEnumerator() | ForEach-Object { $_.Key + ':' + $_.Value }) -join ', ' } else { '' }
        $lines += "| $($c.Name) | $($statusEmoji[[bool]$c.Success]) | $metricStr |"
    }
    $failed = $checks | Where-Object { -not $_.Success }
    if ($failed) {
        $lines += ""
        $lines += "## Failed Check Details"
        foreach ($f in $failed) {
            $lines += "### $($f.Name)"
            $lines += "Error: $($f.Error)"
            $lines += ""
        }
    }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $lines -join [Environment]::NewLine | Out-File -FilePath $Path -Encoding utf8
    Write-Verbose "Report written: $Path"
    return $Path
}
