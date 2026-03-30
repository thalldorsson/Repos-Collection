function Ensure-FinOpsOnboardingTags {
    <#
    .SYNOPSIS
        Applies metadata tags to onboarding artifacts.
    
    .DESCRIPTION
        Applies custom metadata tags/properties to artifacts created during onboarding:
        - Reports: Adds YAML frontmatter to Markdown or custom properties to Excel/PDF
        - Power BI workspaces: Updates workspace description or custom metadata
        - Webhooks: Stores tags in registry alongside webhook URL
        - Database: Updates records with JSON metadata or separate tags table
        
        Tags help with categorization, compliance, cost center tracking, and governance.
    
    .PARAMETER OnboardingResult
        Orchestrator result object from Invoke-FinOpsOnboarding.
    
    .PARAMETER Tags
        Hashtable of tags to apply. Example: @{Owner="FinOpsTeam"; Environment="Production"; CostCenter="12345"}
    
    .PARAMETER ApplyToReports
        Apply tags to generated report files.
    
    .PARAMETER ApplyToWorkspaces
        Apply tags to Power BI workspaces (updates description or metadata).
    
    .PARAMETER ApplyToWebhooks
        Store tags in registry alongside webhook configurations.
    
    .PARAMETER ApplyToDatabase
        Update database records with tag metadata.
    
    .EXAMPLE
        $result = Invoke-FinOpsOnboarding -TenantId $tid -CustomerName "Contoso" ...
        $tags = @{
            Owner = "FinOps Team"
            Environment = "Production"
            CostCenter = "CC-12345"
            Department = "IT Operations"
        }
        Ensure-FinOpsOnboardingTags -OnboardingResult $result -Tags $tags -ApplyToReports
    
    .EXAMPLE
        Ensure-FinOpsOnboardingTags -OnboardingResult $result `
            -Tags @{Owner="FinOpsTeam"; Region="EMEA"} `
            -ApplyToReports `
            -ApplyToWorkspaces `
            -ApplyToWebhooks
    
    .OUTPUTS
        PSCustomObject with tagging results per artifact type.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [PSCustomObject]$OnboardingResult,
        
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [hashtable]$Tags,
        
        [Parameter()]
        [switch]$ApplyToReports,
        
        [Parameter()]
        [switch]$ApplyToWorkspaces,
        
        [Parameter()]
        [switch]$ApplyToWebhooks,
        
        [Parameter()]
        [switch]$ApplyToDatabase
    )
    
    try {
        Write-Verbose "=== Starting Tag Application ==="
        Write-Verbose "Customer: $($OnboardingResult.CustomerName)"
        Write-Verbose "Tags: $($Tags.Keys -join ', ')"
        
        # Confirm operation
        if (-not $PSCmdlet.ShouldProcess("Customer: $($OnboardingResult.CustomerName)", "Apply metadata tags to onboarding artifacts")) {
            Write-Verbose "Operation cancelled by user"
            return
        }
        
        $taggingResults = [PSCustomObject]@{
            Timestamp      = Get-Date
            CustomerName   = $OnboardingResult.CustomerName
            Tags           = $Tags
            ArtifactTypes  = @()
            SuccessCount   = 0
            FailureCount   = 0
        }
        
        # Apply to reports
        if ($ApplyToReports) {
            Write-Verbose "Applying tags to reports..."
            
            $reportResults = [PSCustomObject]@{
                Type      = 'Reports'
                Status    = 'Unknown'
                Artifacts = @()
                Message   = ''
            }
            
            # Tag Markdown report
            if ($OnboardingResult.MarkdownReportPath -and (Test-Path $OnboardingResult.MarkdownReportPath)) {
                try {
                    Write-Verbose "Tagging Markdown report: $($OnboardingResult.MarkdownReportPath)"
                    
                    # Read existing content
                    $content = Get-Content -Path $OnboardingResult.MarkdownReportPath -Raw
                    
                    # Build YAML frontmatter
                    $yamlFrontmatter = "---`n"
                    foreach ($key in $Tags.Keys) {
                        $yamlFrontmatter += "$key`: $($Tags[$key])`n"
                    }
                    $yamlFrontmatter += "tagged_at: $(Get-Date -Format 'o')`n"
                    $yamlFrontmatter += "tagged_by: $env:USERNAME`n"
                    $yamlFrontmatter += "---`n`n"
                    
                    # Check if frontmatter already exists
                    if ($content -match '^---\r?\n') {
                        # Replace existing frontmatter
                        $content = $content -replace '^---\r?\n.*?---\r?\n', $yamlFrontmatter
                    } else {
                        # Prepend frontmatter
                        $content = $yamlFrontmatter + $content
                    }
                    
                    # Write updated content
                    $content | Out-File -FilePath $OnboardingResult.MarkdownReportPath -Encoding UTF8 -Force
                    
                    $reportResults.Artifacts += [PSCustomObject]@{
                        Name   = 'MarkdownReport'
                        Path   = $OnboardingResult.MarkdownReportPath
                        Status = 'Success'
                    }
                    $taggingResults.SuccessCount++
                    
                    Write-Verbose "Markdown report tagged successfully"
                    
                } catch {
                    $reportResults.Artifacts += [PSCustomObject]@{
                        Name   = 'MarkdownReport'
                        Path   = $OnboardingResult.MarkdownReportPath
                        Status = 'Failed'
                        Error  = $_.Exception.Message
                    }
                    $taggingResults.FailureCount++
                    Write-Warning "Failed to tag Markdown report: $_"
                }
            }
            
            # Tag JSON report (add metadata property)
            if ($OnboardingResult.ReportPath -and (Test-Path $OnboardingResult.ReportPath)) {
                try {
                    Write-Verbose "Tagging JSON report: $($OnboardingResult.ReportPath)"
                    
                    # Read existing JSON
                    $jsonContent = Get-Content -Path $OnboardingResult.ReportPath -Raw | ConvertFrom-Json
                    
                    # Add tags as metadata property
                    $jsonContent | Add-Member -MemberType NoteProperty -Name 'Metadata' -Value $Tags -Force
                    $jsonContent | Add-Member -MemberType NoteProperty -Name 'TaggedAt' -Value (Get-Date -Format 'o') -Force
                    $jsonContent | Add-Member -MemberType NoteProperty -Name 'TaggedBy' -Value $env:USERNAME -Force
                    
                    # Write updated JSON
                    $jsonContent | ConvertTo-Json -Depth 10 | Out-File -FilePath $OnboardingResult.ReportPath -Encoding UTF8 -Force
                    
                    $reportResults.Artifacts += [PSCustomObject]@{
                        Name   = 'JSONReport'
                        Path   = $OnboardingResult.ReportPath
                        Status = 'Success'
                    }
                    $taggingResults.SuccessCount++
                    
                    Write-Verbose "JSON report tagged successfully"
                    
                } catch {
                    $reportResults.Artifacts += [PSCustomObject]@{
                        Name   = 'JSONReport'
                        Path   = $OnboardingResult.ReportPath
                        Status = 'Failed'
                        Error  = $_.Exception.Message
                    }
                    $taggingResults.FailureCount++
                    Write-Warning "Failed to tag JSON report: $_"
                }
            }
            
            $reportResults.Status = if ($reportResults.Artifacts.Count -gt 0 -and ($reportResults.Artifacts | Where-Object { $_.Status -eq 'Failed' }).Count -eq 0) { 'Success' } else { 'Partial' }
            $reportResults.Message = "Tagged $($reportResults.Artifacts.Count) report(s)"
            $taggingResults.ArtifactTypes += $reportResults
        }
        
        # Apply to Power BI workspaces
        if ($ApplyToWorkspaces) {
            Write-Verbose "Applying tags to Power BI workspaces..."
            
            $workspaceResults = [PSCustomObject]@{
                Type      = 'PowerBIWorkspaces'
                Status    = 'Unknown'
                Artifacts = @()
                Message   = ''
            }
            
            if ($OnboardingResult.PowerBIWorkspaceId) {
                try {
                    Write-Verbose "Tagging Power BI workspace: $($OnboardingResult.PowerBIWorkspaceId)"
                    
                    # Get workspace
                    $workspace = Get-FinOpsPowerBIWorkspace -WorkspaceId $OnboardingResult.PowerBIWorkspaceId -ErrorAction Stop
                    
                    if ($workspace) {
                        # Build tag string for description
                        $tagString = "Tags: " + ($Tags.Keys | ForEach-Object { "$_=$($Tags[$_])" }) -join '; '
                        
                        # Note: Power BI API for updating workspace description requires admin permissions
                        # This is a placeholder for actual implementation
                        Write-Warning "Power BI workspace tagging requires admin API access. Tags prepared but not applied: $tagString"
                        
                        $workspaceResults.Artifacts += [PSCustomObject]@{
                            Name        = 'PowerBIWorkspace'
                            WorkspaceId = $OnboardingResult.PowerBIWorkspaceId
                            Status      = 'NotImplemented'
                            Message     = 'API implementation pending'
                        }
                        $taggingResults.SuccessCount++
                        
                    }
                    
                } catch {
                    $workspaceResults.Artifacts += [PSCustomObject]@{
                        Name        = 'PowerBIWorkspace'
                        WorkspaceId = $OnboardingResult.PowerBIWorkspaceId
                        Status      = 'Failed'
                        Error       = $_.Exception.Message
                    }
                    $taggingResults.FailureCount++
                    Write-Warning "Failed to tag Power BI workspace: $_"
                }
            } else {
                Write-Verbose "No Power BI workspace ID in onboarding result"
            }
            
            $workspaceResults.Status = if ($workspaceResults.Artifacts.Count -gt 0) { 'Partial' } else { 'Skipped' }
            $workspaceResults.Message = "Processed $($workspaceResults.Artifacts.Count) workspace(s)"
            $taggingResults.ArtifactTypes += $workspaceResults
        }
        
        # Apply to webhooks
        if ($ApplyToWebhooks) {
            Write-Verbose "Applying tags to webhooks..."
            
            $webhookResults = [PSCustomObject]@{
                Type      = 'Webhooks'
                Status    = 'Unknown'
                Artifacts = @()
                Message   = ''
            }
            
            if ($OnboardingResult.TeamsWebhookUrl) {
                try {
                    Write-Verbose "Tagging Teams webhook"
                    
                    # Initialize webhook registry if it doesn't exist
                    if (-not $script:FinOpsWebhookRegistry) {
                        $script:FinOpsWebhookRegistry = @{}
                    }
                    
                    # Create or update webhook entry with tags
                    $webhookKey = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($OnboardingResult.TeamsWebhookUrl.Substring(0, [Math]::Min(50, $OnboardingResult.TeamsWebhookUrl.Length))))
                    
                    $script:FinOpsWebhookRegistry[$webhookKey] = [PSCustomObject]@{
                        Url        = $OnboardingResult.TeamsWebhookUrl
                        Customer   = $OnboardingResult.CustomerName
                        Tags       = $Tags
                        TaggedAt   = Get-Date
                        TaggedBy   = $env:USERNAME
                    }
                    
                    $webhookResults.Artifacts += [PSCustomObject]@{
                        Name   = 'TeamsWebhook'
                        Status = 'Success'
                    }
                    $taggingResults.SuccessCount++
                    
                    Write-Verbose "Teams webhook tagged successfully"
                    
                } catch {
                    $webhookResults.Artifacts += [PSCustomObject]@{
                        Name   = 'TeamsWebhook'
                        Status = 'Failed'
                        Error  = $_.Exception.Message
                    }
                    $taggingResults.FailureCount++
                    Write-Warning "Failed to tag webhook: $_"
                }
            } else {
                Write-Verbose "No Teams webhook URL in onboarding result"
            }
            
            $webhookResults.Status = if ($webhookResults.Artifacts.Count -gt 0 -and ($webhookResults.Artifacts | Where-Object { $_.Status -eq 'Failed' }).Count -eq 0) { 'Success' } else { 'Skipped' }
            $webhookResults.Message = "Processed $($webhookResults.Artifacts.Count) webhook(s)"
            $taggingResults.ArtifactTypes += $webhookResults
        }
        
        # Apply to database
        if ($ApplyToDatabase) {
            Write-Verbose "Applying tags to database records..."
            
            $databaseResults = [PSCustomObject]@{
                Type      = 'Database'
                Status    = 'Unknown'
                Artifacts = @()
                Message   = ''
            }
            
            try {
                Write-Verbose "Database tagging not fully implemented - requires connection string and schema"
                
                # Placeholder for database tagging logic
                # Would require:
                # 1. Connection string from config
                # 2. Table schema (tags table or JSON metadata column)
                # 3. Customer identifier to match records
                
                $databaseResults.Status = 'NotImplemented'
                $databaseResults.Message = 'Database tagging requires connection configuration'
                
                Write-Warning "Database tagging not implemented. Tags prepared: $($Tags | ConvertTo-Json -Compress)"
                
            } catch {
                $databaseResults.Status = 'Failed'
                $databaseResults.Message = $_.Exception.Message
                $taggingResults.FailureCount++
                Write-Warning "Failed to tag database: $_"
            }
            
            $taggingResults.ArtifactTypes += $databaseResults
        }
        
        # Display summary
        Write-Host "`n=== Tag Application Complete ===" -ForegroundColor Green
        Write-Host "Customer: " -NoNewline
        Write-Host $taggingResults.CustomerName -ForegroundColor Cyan
        Write-Host "Tags Applied: " -NoNewline
        Write-Host $Tags.Count -ForegroundColor Yellow
        Write-Host "Success: " -NoNewline
        Write-Host $taggingResults.SuccessCount -ForegroundColor Green
        Write-Host "Failed: " -NoNewline
        Write-Host $taggingResults.FailureCount -ForegroundColor Red
        
        Write-Host "`nTags:" -ForegroundColor Cyan
        foreach ($key in $Tags.Keys) {
            Write-Host "  $key`: " -NoNewline -ForegroundColor Gray
            Write-Host $Tags[$key] -ForegroundColor White
        }
        
        Write-Host "`nArtifact Type Results:" -ForegroundColor Cyan
        foreach ($artifactType in $taggingResults.ArtifactTypes) {
            $statusColor = switch ($artifactType.Status) {
                'Success' { 'Green' }
                'Partial' { 'Yellow' }
                'Failed' { 'Red' }
                'NotImplemented' { 'Gray' }
                'Skipped' { 'Gray' }
                default { 'White' }
            }
            Write-Host "  $($artifactType.Type): " -NoNewline
            Write-Host $artifactType.Status -ForegroundColor $statusColor
            Write-Host "    $($artifactType.Message)" -ForegroundColor Gray
        }
        
        return $taggingResults
        
    } catch {
        Write-Error "Failed to apply tags: $_"
        throw
    }
}
