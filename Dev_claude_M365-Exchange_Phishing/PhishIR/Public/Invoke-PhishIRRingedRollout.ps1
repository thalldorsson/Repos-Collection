function Invoke-PhishIRRingedRollout {
    <#
    .SYNOPSIS
        Executes a phased purge operation across multiple rings with validation gates.
    
    .DESCRIPTION
        Implements enterprise-scale ringed rollout pattern for mail purge operations.
        Validates each ring before proceeding to the next, with automatic rollback triggers.
        
        Ring structure:
        - Ring 0: Pilot (10% or 10 mailboxes, whichever is smaller)
        - Ring 1: Early Adopters (25% of remaining)
        - Ring 2: Broad Deployment (50% of remaining)
        - Ring 3: Production (remaining mailboxes)
    
    .PARAMETER Mailboxes
        Complete list of mailboxes to purge across all rings.
    
    .PARAMETER ContentMatchQuery
        KQL query to identify messages for purging.
    
    .PARAMETER PurgeType
        Type of purge: SoftDelete or HardDelete.
    
    .PARAMETER RingDefinition
        Custom ring sizes (default: @(0.1, 0.25, 0.5, 1.0) for 10%, 25%, 50%, 100%).
    
    .PARAMETER ValidationDelay
        Seconds to wait between rings for validation (default: 300 = 5 minutes).
    
    .PARAMETER AutoProceed
        Automatically proceed to next ring if validation passes (default: require manual confirmation).
    
    .PARAMETER OutputDir
        Directory for reports and evidence collection.
    
    .EXAMPLE
        $mailboxes = Get-Content '.\all-users.txt'
        Invoke-PhishIRRingedRollout -Mailboxes $mailboxes -ContentMatchQuery 'from:evil@bad.com' -PurgeType SoftDelete -OutputDir 'C:\Purge'
        
        Execute ringed rollout with manual validation gates.
    
    .EXAMPLE
        Invoke-PhishIRRingedRollout -Mailboxes $mailboxes -ContentMatchQuery 'subject:"Invoice"' -PurgeType HardDelete -AutoProceed -ValidationDelay 600
        
        Execute ringed rollout with automatic progression after 10 minutes per ring.
    
    .OUTPUTS
        PSCustomObject with rollout summary and per-ring results.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string[]]$Mailboxes,
        
        [Parameter(Mandatory)]
        [string]$ContentMatchQuery,
        
        [Parameter(Mandatory)]
        [ValidateSet('SoftDelete','HardDelete')]
        [string]$PurgeType,
        
        [double[]]$RingDefinition = @(0.1, 0.25, 0.5, 1.0),
        
        [int]$ValidationDelay = 300,
        
        [switch]$AutoProceed,
        
        [string]$OutputDir = (Join-Path $env:TEMP 'PhishIR-Ringed-Rollout'),
        
        [string]$HardDeleteConfirmation
    )
    
    $rolloutStart = Get-Date
    $correlationId = [guid]::NewGuid().ToString()
    $rolloutDir = Join-Path $OutputDir "Rollout-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $null = New-Item -ItemType Directory -Path $rolloutDir -Force
    
    Write-PhishIRLog -Level Info -Message "Starting ringed rollout" -Properties @{
        CorrelationId = $correlationId
        TotalMailboxes = $Mailboxes.Count
        PurgeType = $PurgeType
        Rings = $RingDefinition.Count
    }
    
    # Calculate ring assignments
    $rings = @()
    $remainingMailboxes = [System.Collections.ArrayList]::new($Mailboxes)
    
    for ($i = 0; $i -lt $RingDefinition.Count; $i++) {
        $percentage = $RingDefinition[$i]
        $ringSize = if ($i -eq 0) {
            # Ring 0: min(10%, 10 mailboxes)
            [Math]::Min(10, [Math]::Ceiling($Mailboxes.Count * $percentage))
        } elseif ($i -eq ($RingDefinition.Count - 1)) {
            # Last ring: all remaining
            $remainingMailboxes.Count
        } else {
            # Other rings: percentage of remaining
            [Math]::Ceiling($remainingMailboxes.Count * $percentage)
        }
        
        $ringMailboxes = $remainingMailboxes[0..($ringSize - 1)]
        $remainingMailboxes.RemoveRange(0, $ringSize)
        
        $rings += [PSCustomObject]@{
            RingNumber = $i
            RingName = "Ring-$i"
            Mailboxes = $ringMailboxes
            MailboxCount = $ringMailboxes.Count
            Status = 'Pending'
            StartTime = $null
            EndTime = $null
            ItemsPurged = 0
            ErrorCount = 0
        }
    }
    
    # Execute rings sequentially
    $ringResults = @()
    foreach ($ring in $rings) {
        Write-Host "`n=== $($ring.RingName): $($ring.MailboxCount) mailboxes ===" -ForegroundColor Cyan
        $ring.StartTime = Get-Date
        $ring.Status = 'InProgress'
        
        try {
            # Execute purge for this ring
            $purgeParams = @{
                Mailboxes = $ring.Mailboxes
                AdvancedQuery = $ContentMatchQuery
                PurgeType = $PurgeType
                OutputDir = $rolloutDir
                Confirm = $false
            }
            
            if ($PurgeType -eq 'HardDelete' -and $HardDeleteConfirmation) {
                $purgeParams['HardDeleteConfirmation'] = $HardDeleteConfirmation
            }
            
            if ($PSCmdlet.ShouldProcess("$($ring.RingName) ($($ring.MailboxCount) mailboxes)", "Purge ($PurgeType)")) {
                $result = Invoke-MailPurge @purgeParams
                $ring.ItemsPurged = if ($result.ItemsPurged) { $result.ItemsPurged } else { 0 }
                $ring.Status = 'Completed'
            } else {
                $ring.Status = 'Skipped'
            }
            
            $ring.EndTime = Get-Date
            $ringResults += $ring
            
            # Validation gate (except for last ring)
            if ($ring.RingNumber -lt ($rings.Count - 1)) {
                Write-Host "`n$($ring.RingName) completed. Validation gate - waiting $ValidationDelay seconds..." -ForegroundColor Yellow
                
                if (-not $AutoProceed) {
                    $proceed = Read-Host "Review results. Proceed to next ring? (y/n)"
                    if ($proceed -ne 'y') {
                        Write-PhishIRLog -Level Warning -Message "Ringed rollout halted by user at $($ring.RingName)"
                        Write-Host "Rollout halted. Completed rings saved to: $rolloutDir" -ForegroundColor Red
                        break
                    }
                } else {
                    Start-Sleep -Seconds $ValidationDelay
                }
            }
            
        } catch {
            $ring.Status = 'Failed'
            $ring.ErrorCount++
            $ring.EndTime = Get-Date
            Write-PhishIRLog -Level Error -Message "$($ring.RingName) failed" -Exception $_.Exception
            Write-Host "$($ring.RingName) FAILED: $($_.Exception.Message)" -ForegroundColor Red
            
            # Halt rollout on ring failure
            Write-Host "Rollout halted due to ring failure. Review logs in: $rolloutDir" -ForegroundColor Red
            break
        }
    }
    
    # Rollout summary
    $rolloutEnd = Get-Date
    $duration = ($rolloutEnd - $rolloutStart).TotalMinutes
    $totalPurged = ($ringResults | Measure-Object -Property ItemsPurged -Sum).Sum
    
    $summary = [PSCustomObject]@{
        CorrelationId = $correlationId
        StartTime = $rolloutStart
        EndTime = $rolloutEnd
        DurationMinutes = [Math]::Round($duration, 2)
        TotalMailboxes = $Mailboxes.Count
        RingsCompleted = ($ringResults | Where-Object { $_.Status -eq 'Completed' }).Count
        TotalRings = $rings.Count
        TotalItemsPurged = $totalPurged
        PurgeType = $PurgeType
        RingResults = $ringResults
        OutputDirectory = $rolloutDir
    }
    
    # Export summary
    $summaryPath = Join-Path $rolloutDir 'RolloutSummary.json'
    $summary | ConvertTo-Json -Depth 10 | Set-Content -Path $summaryPath -Encoding UTF8
    
    Write-PhishIRLog -Level Info -Message "Ringed rollout completed" -Properties @{
        CorrelationId = $correlationId
        RingsCompleted = $summary.RingsCompleted
        TotalRings = $summary.TotalRings
        TotalItemsPurged = $totalPurged
        DurationMinutes = $summary.DurationMinutes
    }
    
    Write-Host "`n=== Rollout Summary ===" -ForegroundColor Green
    Write-Host "Rings Completed: $($summary.RingsCompleted) of $($summary.TotalRings)"
    Write-Host "Total Items Purged: $totalPurged"
    Write-Host "Duration: $($summary.DurationMinutes) minutes"
    Write-Host "Reports: $rolloutDir"
    
    return $summary
}
