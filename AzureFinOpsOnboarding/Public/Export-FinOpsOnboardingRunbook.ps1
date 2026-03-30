function Export-FinOpsOnboardingRunbook {
    <#
    .SYNOPSIS
        Exports an onboarding runbook document from orchestrator results.
    
    .DESCRIPTION
        Generates a comprehensive Markdown or PDF document from Invoke-FinOpsOnboarding results.
        The runbook includes prerequisites, configuration, steps executed, validation results,
        generated outputs, operator information, and customer recommendations.
        
        Useful for audit trails, customer handoffs, and compliance documentation.
    
    .PARAMETER OnboardingResult
        Orchestrator result object from Invoke-FinOpsOnboarding.
    
    .PARAMETER OutputPath
        Directory path for saving the runbook. Defaults to mock Azure share path.
        The filename pattern is: {CustomerName}_{Date}_OnboardingRunbook.md
    
    .PARAMETER Format
        Output format: 'Markdown' or 'PDF'. Default is 'Markdown'.
        PDF conversion requires markdown-pdf module or similar converter.
    
    .PARAMETER IncludeCredentialInfo
        Include credential/authentication metadata in the runbook.
        WARNING: Does not include secrets, only metadata like ApplicationId, TenantId.
    
    .EXAMPLE
        $result = Invoke-FinOpsOnboarding -TenantId $tid -CustomerName "Contoso" ...
        Export-FinOpsOnboardingRunbook -OnboardingResult $result
    
    .EXAMPLE
        Export-FinOpsOnboardingRunbook -OnboardingResult $result `
            -OutputPath "C:\FinOps\Runbooks" `
            -Format PDF `
            -IncludeCredentialInfo
    
    .OUTPUTS
        String. Returns the full path to the generated runbook file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [PSCustomObject]$OnboardingResult,
        
        [Parameter()]
        [string]$OutputPath = '\\azure-share-mock\finops\runbooks',
        
        [Parameter()]
        [ValidateSet('Markdown', 'PDF')]
        [string]$Format = 'Markdown',
        
        [Parameter()]
        [switch]$IncludeCredentialInfo
    )
    
    try {
        Write-Verbose "=== Starting Runbook Export ==="
        
        # Validate orchestrator result structure
        if (-not $OnboardingResult.CustomerName) {
            throw "Invalid OnboardingResult: Missing CustomerName property"
        }
        
        # Ensure output directory exists
        if (-not (Test-Path $OutputPath)) {
            Write-Verbose "Creating output directory: $OutputPath"
            New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        }
        
        # Generate filename
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $sanitizedName = $OnboardingResult.CustomerName -replace '[^a-zA-Z0-9-_]', '_'
        $baseFilename = "${sanitizedName}_${timestamp}_OnboardingRunbook"
        $mdFilePath = Join-Path $OutputPath "$baseFilename.md"
        
        Write-Verbose "Generating runbook at: $mdFilePath"
        
        # Build markdown content
        $markdown = @"
# Azure FinOps Onboarding Runbook

**Customer:** $($OnboardingResult.CustomerName)  
**Generated:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  
**Operator:** $env:USERNAME @ $env:COMPUTERNAME  
**Module Version:** $(if($OnboardingResult.ModuleVersion){$OnboardingResult.ModuleVersion}else{'N/A'})

---

## Executive Summary

This runbook documents the Azure FinOps onboarding validation performed for **$($OnboardingResult.CustomerName)**.

- **Total Checks:** $($OnboardingResult.CheckResults.Count)
- **Passed:** $(($OnboardingResult.CheckResults | Where-Object { $_.Success }).Count)
- **Failed:** $(($OnboardingResult.CheckResults | Where-Object { -not $_.Success }).Count)
- **Overall Status:** $(if(($OnboardingResult.CheckResults | Where-Object { -not $_.Success }).Count -eq 0){'✅ All checks passed'}else{'⚠️ Some checks failed'})

---

## Prerequisites Met

The following prerequisites were validated before onboarding:

| Prerequisite | Status |
|-------------|--------|
| Service Principal Authentication | $(if($OnboardingResult.CheckResults | Where-Object {$_.CheckName -eq 'Authentication'} | Where-Object {$_.Success}){'✅ Passed'}else{'❌ Failed'}) |
| Subscription Access | $(if($OnboardingResult.CheckResults | Where-Object {$_.CheckName -eq 'Subscriptions'} | Where-Object {$_.Success}){'✅ Passed'}else{'❌ Failed'}) |
$(if($OnboardingResult.IsEA){"| Billing Account Access | $(if($OnboardingResult.CheckResults | Where-Object {$_.CheckName -eq 'BillingAccounts'} | Where-Object {$_.Success}){'✅ Passed'}else{'❌ Failed'}) |"})
$(if(-not $OnboardingResult.SkipReservations){"| Reservation Access | $(if($OnboardingResult.CheckResults | Where-Object {$_.CheckName -eq 'Reservations'} | Where-Object {$_.Success}){'✅ Passed'}else{'❌ Failed'}) |"})
$(if(-not $OnboardingResult.SkipCosts){"| Cost Management Access | $(if($OnboardingResult.CheckResults | Where-Object {$_.CheckName -eq 'Costs'} | Where-Object {$_.Success}){'✅ Passed'}else{'❌ Failed'}) |"})
$(if(-not $OnboardingResult.SkipEmissions){"| Emissions Data Access | $(if($OnboardingResult.CheckResults | Where-Object {$_.CheckName -eq 'Emissions'} | Where-Object {$_.Success}){'✅ Passed'}else{'❌ Failed'}) |"})

---

## Configuration Used

### Customer Information
- **Customer Name:** $($OnboardingResult.CustomerName)
- **Primary Domain:** $($OnboardingResult.PrimaryDomain)
- **Company Name:** $(if($OnboardingResult.CompanyName){$OnboardingResult.CompanyName}else{'N/A'})
- **Country:** $(if($OnboardingResult.Country){$OnboardingResult.Country}else{'N/A'})
- **Tenant Name:** $(if($OnboardingResult.TenantName){$OnboardingResult.TenantName}else{'N/A'})

$(if($IncludeCredentialInfo){@"
### Authentication Configuration
- **Tenant ID:** $($OnboardingResult.TenantId)
- **Application ID:** $($OnboardingResult.ApplicationId)
- **Authentication Method:** Service Principal (Client Secret)

"@})

### Onboarding Options
- **EA Mode:** $(if($OnboardingResult.IsEA){'Yes'}else{'No'})
- **Skip Reservations:** $(if($OnboardingResult.SkipReservations){'Yes'}else{'No'})
- **Skip Costs:** $(if($OnboardingResult.SkipCosts){'Yes'}else{'No'})
- **Skip Emissions:** $(if($OnboardingResult.SkipEmissions){'Yes'}else{'No'})
- **Report Format:** $(if($OnboardingResult.ReportFormat){$OnboardingResult.ReportFormat}else{'Both'})
- **Cost Lookback:** $(if($OnboardingResult.CostLookbackStartDays){$OnboardingResult.CostLookbackStartDays}else{'60'}) to $(if($OnboardingResult.CostLookbackEndDays){$OnboardingResult.CostLookbackEndDays}else{'30'}) days

---

## Steps Executed

The following validation steps were executed during onboarding:

"@

        # Add each check result with timestamp
        foreach ($check in $OnboardingResult.CheckResults) {
            $statusIcon = if ($check.Success) { '✅' } else { '❌' }
            $timestamp = if ($check.Timestamp) { $check.Timestamp.ToString('HH:mm:ss') } else { 'N/A' }
            
            $markdown += @"

### $statusIcon $($check.CheckName) [$timestamp]

**Status:** $(if($check.Success){'Passed'}else{'Failed'})  
**Message:** $($check.Message)

"@
            
            if ($check.Data) {
                $markdown += "**Data Summary:**`n`n"
                $dataJson = $check.Data | ConvertTo-Json -Depth 2 -Compress
                $markdown += "``````json`n$dataJson`n```````n`n"
            }
            
            if ($check.Error) {
                $markdown += "**Error Details:** ``$($check.Error)```n`n"
            }
        }
        
        # Add validation results summary
        $markdown += @"

---

## Validation Results Summary

| Check Name | Status | Duration | Details |
|-----------|--------|----------|---------|

"@
        
        foreach ($check in $OnboardingResult.CheckResults) {
            $status = if ($check.Success) { '✅ Pass' } else { '❌ Fail' }
            $duration = if ($check.Duration) { "$($check.Duration.TotalSeconds)s" } else { 'N/A' }
            $details = if ($check.Message) { $check.Message -replace '\n', ' ' } else { '' }
            $markdown += "| $($check.CheckName) | $status | $duration | $details |`n"
        }
        
        # Add generated outputs
        $markdown += @"

---

## Generated Outputs

The following artifacts were generated during onboarding:

"@
        
        if ($OnboardingResult.ReportPath) {
            $markdown += "- **JSON Report:** ``$($OnboardingResult.ReportPath)```n"
        }
        if ($OnboardingResult.MarkdownReportPath) {
            $markdown += "- **Markdown Report:** ``$($OnboardingResult.MarkdownReportPath)```n"
        }
        if ($OnboardingResult.JiraComment) {
            $markdown += "- **Jira Comment:** Published to issue $($OnboardingResult.JiraIssueKey)`n"
        }
        if ($OnboardingResult.TeamsNotification) {
            $markdown += "- **Teams Notification:** Sent successfully`n"
        }
        
        # Add operator information
        $markdown += @"

---

## Operator Information

- **Username:** $env:USERNAME
- **Computer:** $env:COMPUTERNAME
- **Domain:** $(if($env:USERDOMAIN){$env:USERDOMAIN}else{'N/A'})
- **Execution Time:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
- **PowerShell Version:** $($PSVersionTable.PSVersion)

---

## Recommendations for Customer

Based on the validation results, the following recommendations apply:

"@
        
        # Generate recommendations based on results
        $failedChecks = $OnboardingResult.CheckResults | Where-Object { -not $_.Success }
        
        if ($failedChecks.Count -eq 0) {
            $markdown += @"
### ✅ All Checks Passed

The Azure FinOps onboarding validation completed successfully. The service principal has all required permissions and access to:

- Subscription resources
$(if($OnboardingResult.IsEA){"- Billing accounts (EA/MCA)"})
$(if(-not $OnboardingResult.SkipReservations){"- Azure Reservations"})
$(if(-not $OnboardingResult.SkipCosts){"- Cost Management data"})
$(if(-not $OnboardingResult.SkipEmissions){"- Emissions data"})

**Next Steps:**
1. Review the generated reports in the Output directory
2. Configure Power BI workspace access for customer users
3. Set up scheduled data refresh for FinOps dashboards
4. Establish monitoring and alerting thresholds
5. Schedule regular cost optimization reviews

"@
        } else {
            $markdown += "### ⚠️ Action Required`n`n"
            $markdown += "The following checks failed and require attention:`n`n"
            
            foreach ($failedCheck in $failedChecks) {
                $markdown += @"
#### $($failedCheck.CheckName)

**Issue:** $($failedCheck.Message)

"@
                
                # Add specific recommendations based on check type
                switch ($failedCheck.CheckName) {
                    'Subscriptions' {
                        $markdown += "**Recommendation:** Grant the service principal 'Reader' role at subscription or management group scope.`n`n"
                    }
                    'BillingAccounts' {
                        $markdown += "**Recommendation:** Grant 'EnrollmentReader' (EA) or 'Billing Account Reader' (MCA) role.`n`n"
                    }
                    'Reservations' {
                        $markdown += "**Recommendation:** Grant 'Reservation Reader' role or include in reservation order.`n`n"
                    }
                    'Costs' {
                        $markdown += "**Recommendation:** Grant 'Cost Management Reader' role at subscription scope.`n`n"
                    }
                    'Emissions' {
                        $markdown += "**Recommendation:** Verify Carbon Optimization is enabled and service principal has access.`n`n"
                    }
                    default {
                        $markdown += "**Recommendation:** Review error details and Azure RBAC assignments.`n`n"
                    }
                }
            }
        }
        
        $markdown += @"

---

## Appendix

### Support Contact

For questions or issues with Azure FinOps onboarding:

- **Email:** finops-support@company.com
- **Teams Channel:** Azure FinOps Operations
- **Jira Project:** FINOPS

### Reference Documentation

- [Azure FinOps Onboarding Guide](https://docs.company.com/finops/onboarding)
- [Service Principal Setup](https://docs.company.com/finops/service-principal)
- [Cost Management API Reference](https://learn.microsoft.com/azure/cost-management-billing/costs/)

---

*Generated by Azure FinOps Onboarding Module v1.8.x*

"@
        
        # Write markdown file
        $markdown | Out-File -FilePath $mdFilePath -Encoding UTF8 -Force
        Write-Verbose "Markdown runbook created: $mdFilePath"
        
        $finalPath = $mdFilePath
        
        # Convert to PDF if requested
        if ($Format -eq 'PDF') {
            Write-Verbose "Converting to PDF format..."
            
            try {
                # Check for markdown-pdf or similar converter
                $pdfPath = [System.IO.Path]::ChangeExtension($mdFilePath, '.pdf')
                
                # Try using pandoc if available
                $pandocPath = Get-Command pandoc -ErrorAction SilentlyContinue
                if ($pandocPath) {
                    Write-Verbose "Using Pandoc for PDF conversion"
                    & pandoc $mdFilePath -o $pdfPath --pdf-engine=xelatex -V geometry:margin=1in
                    
                    if (Test-Path $pdfPath) {
                        $finalPath = $pdfPath
                        Write-Verbose "PDF created: $pdfPath"
                    } else {
                        Write-Warning "PDF conversion failed. Returning markdown file."
                    }
                } else {
                    Write-Warning "PDF conversion requires Pandoc. Install from https://pandoc.org"
                    Write-Warning "Returning markdown file instead."
                }
            } catch {
                Write-Warning "PDF conversion failed: $_"
                Write-Warning "Returning markdown file."
            }
        }
        
        # Display summary
        Write-Host "`n=== Runbook Export Complete ===" -ForegroundColor Green
        Write-Host "Customer: " -NoNewline
        Write-Host $OnboardingResult.CustomerName -ForegroundColor Cyan
        Write-Host "File: " -NoNewline
        Write-Host $finalPath -ForegroundColor Yellow
        Write-Host "Format: " -NoNewline
        Write-Host $Format -ForegroundColor Cyan
        Write-Host "Checks: " -NoNewline
        $passCount = ($OnboardingResult.CheckResults | Where-Object { $_.Success }).Count
        $totalCount = $OnboardingResult.CheckResults.Count
        Write-Host "$passCount/$totalCount passed" -ForegroundColor $(if($passCount -eq $totalCount){'Green'}else{'Yellow'})
        
        return $finalPath
        
    } catch {
        Write-Error "Failed to export onboarding runbook: $_"
        throw
    }
}
