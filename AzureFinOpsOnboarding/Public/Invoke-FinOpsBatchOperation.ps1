function Invoke-FinOpsBatchOperation {
    <#
    .SYNOPSIS
        Executes operations in batches with configurable delays and error handling.
    
    .DESCRIPTION
        Processes a collection of items in batches to prevent overwhelming APIs or systems.
        Provides progress tracking, inter-batch delays, and flexible error handling.
        
        Useful for bulk operations like:
        - Processing multiple subscriptions
        - Bulk exports
        - Mass configuration changes
        - Rate-limited API calls
    
    .PARAMETER Items
        Array of items to process.
    
    .PARAMETER ScriptBlock
        Scriptblock to execute for each item. Receives item as $_ or $PSItem.
    
    .PARAMETER BatchSize
        Number of items to process in each batch. Default is 10.
    
    .PARAMETER DelayBetweenBatches
        Milliseconds to wait between batches. Default is 500ms.
    
    .PARAMETER DelayBetweenItems
        Milliseconds to wait between items within a batch. Default is 0 (no delay).
    
    .PARAMETER ErrorAction
        How to handle errors: ContinueOnError (default) or StopOnError.
    
    .PARAMETER ShowProgress
        Display progress bar during processing.
    
    .PARAMETER ProgressActivity
        Custom activity text for progress bar. Default is "Processing batch operation".
    
    .EXAMPLE
        # Process subscriptions in batches of 5 with 1 second delay
        $results = Invoke-FinOpsBatchOperation -Items $subscriptions -BatchSize 5 -DelayBetweenBatches 1000 -ScriptBlock {
            Invoke-FinOpsOnboarding -SubscriptionId $_.Id -TenantId $tenantId
        }
    
    .EXAMPLE
        # Export multiple reports with progress and item delays
        $exports = Invoke-FinOpsBatchOperation -Items $reportIds -BatchSize 3 -DelayBetweenItems 200 -ShowProgress -ScriptBlock {
            Export-FinOpsReport -ReportId $_
        }
    
    .EXAMPLE
        # Stop processing on first error
        $results = Invoke-FinOpsBatchOperation -Items $items -ErrorAction StopOnError -ScriptBlock {
            Test-SomeOperation -Item $_
        }
    
    .OUTPUTS
        Array of results from each operation. Failed operations return error objects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Items,
        
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        
        [Parameter()]
        [ValidateRange(1, 1000)]
        [int]$BatchSize = 10,
        
        [Parameter()]
        [ValidateRange(0, 60000)]
        [int]$DelayBetweenBatches = 500,
        
        [Parameter()]
        [ValidateRange(0, 10000)]
        [int]$DelayBetweenItems = 0,
        
        [Parameter()]
        [ValidateSet('ContinueOnError', 'StopOnError')]
        [string]$ErrorHandling = 'ContinueOnError',
        
        [Parameter()]
        [switch]$ShowProgress,
        
        [Parameter()]
        [string]$ProgressActivity = "Processing batch operation"
    )
    
    if ($Items.Count -eq 0) {
        Write-FinOpsLog -Level 'Warning' -Message "No items to process" -Category 'Batch'
        return @()
    }
    
    $results = [System.Collections.ArrayList]::new()
    $totalItems = $Items.Count
    $totalBatches = [Math]::Ceiling($totalItems / $BatchSize)
    $currentItemIndex = 0
    $successCount = 0
    $failureCount = 0
    
    Write-FinOpsLog -Level 'Info' -Message "Starting batch operation" -Context @{
        TotalItems = $totalItems
        BatchSize = $BatchSize
        TotalBatches = $totalBatches
        DelayBetweenBatches = $DelayBetweenBatches
        DelayBetweenItems = $DelayBetweenItems
        ErrorHandling = $ErrorHandling
    } -Category 'Batch'
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    
    for ($batchIndex = 0; $batchIndex -lt $totalBatches; $batchIndex++) {
        $batchNumber = $batchIndex + 1
        $startIndex = $batchIndex * $BatchSize
        $endIndex = [Math]::Min($startIndex + $BatchSize - 1, $totalItems - 1)
        $batchItems = $Items[$startIndex..$endIndex]
        
        Write-FinOpsLog -Level 'Debug' -Message "Processing batch" -Context @{
            Batch = $batchNumber
            TotalBatches = $totalBatches
            Items = $batchItems.Count
            StartIndex = $startIndex
            EndIndex = $endIndex
        } -Category 'Batch'
        
        foreach ($item in $batchItems) {
            $currentItemIndex++
            
            if ($ShowProgress) {
                $percentComplete = [Math]::Round(($currentItemIndex / $totalItems) * 100, 2)
                Write-Progress -Activity $ProgressActivity -Status "Batch $batchNumber/$totalBatches - Item $currentItemIndex/$totalItems" -PercentComplete $percentComplete
            }
            
            try {
                $result = & $ScriptBlock -Item $item
                [void]$results.Add([PSCustomObject]@{
                    Item = $item
                    Result = $result
                    Success = $true
                    Error = $null
                    Index = $currentItemIndex - 1
                    Batch = $batchNumber
                })
                $successCount++
                
                Write-FinOpsLog -Level 'Debug' -Message "Item processed successfully" -Context @{
                    ItemIndex = $currentItemIndex
                    Batch = $batchNumber
                } -Category 'Batch'
            }
            catch {
                $failureCount++
                $errorMessage = $_.Exception.Message
                
                Write-FinOpsLog -Level 'Error' -Message "Item processing failed" -Context @{
                    ItemIndex = $currentItemIndex
                    Batch = $batchNumber
                    Error = $errorMessage
                } -Category 'Batch' -Exception $_.Exception
                
                [void]$results.Add([PSCustomObject]@{
                    Item = $item
                    Result = $null
                    Success = $false
                    Error = $errorMessage
                    Exception = $_.Exception
                    Index = $currentItemIndex - 1
                    Batch = $batchNumber
                })
                
                if ($ErrorHandling -eq 'StopOnError') {
                    if ($ShowProgress) {
                        Write-Progress -Activity $ProgressActivity -Completed
                    }
                    
                    Write-FinOpsLog -Level 'Error' -Message "Batch operation stopped due to error" -Context @{
                        ProcessedItems = $currentItemIndex
                        TotalItems = $totalItems
                        SuccessCount = $successCount
                        FailureCount = $failureCount
                        ErrorHandling = $ErrorHandling
                    } -Category 'Batch'
                    
                    throw
                }
            }
            
            # Delay between items if configured
            if ($DelayBetweenItems -gt 0 -and $currentItemIndex -lt $totalItems) {
                Start-Sleep -Milliseconds $DelayBetweenItems
            }
        }
        
        # Delay between batches if not the last batch
        if ($batchNumber -lt $totalBatches -and $DelayBetweenBatches -gt 0) {
            Write-FinOpsLog -Level 'Debug' -Message "Delaying between batches" -Context @{
                Batch = $batchNumber
                Delay = $DelayBetweenBatches
            } -Category 'Batch'
            Start-Sleep -Milliseconds $DelayBetweenBatches
        }
    }
    
    $stopwatch.Stop()
    
    if ($ShowProgress) {
        Write-Progress -Activity $ProgressActivity -Completed
    }
    
    Write-FinOpsLog -Level 'Info' -Message "Batch operation completed" -Context @{
        TotalItems = $totalItems
        ProcessedItems = $currentItemIndex
        SuccessCount = $successCount
        FailureCount = $failureCount
        SuccessRate = [Math]::Round(($successCount / $totalItems) * 100, 2)
        Duration = $stopwatch.Elapsed.TotalSeconds
        TotalBatches = $totalBatches
    } -Category 'Batch'
    
    return $results.ToArray()
}

function Get-FinOpsBatchStatistics {
    <#
    .SYNOPSIS
        Analyzes batch operation results and provides statistics.
    
    .DESCRIPTION
        Takes output from Invoke-FinOpsBatchOperation and calculates summary statistics.
    
    .PARAMETER Results
        Array of results from Invoke-FinOpsBatchOperation.
    
    .EXAMPLE
        $results = Invoke-FinOpsBatchOperation -Items $items -ScriptBlock { Process-Item $_ }
        $stats = Get-FinOpsBatchStatistics -Results $results
        $stats | Format-List
    
    .EXAMPLE
        # Get statistics and check success rate
        $stats = Get-FinOpsBatchStatistics -Results $batchResults
        if ($stats.SuccessRate -lt 95) {
            Write-Warning "Batch success rate below threshold: $($stats.SuccessRate)%"
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Results
    )
    
    if ($Results.Count -eq 0) {
        return $null
    }
    
    $successful = $Results | Where-Object { $_.Success }
    $failed = $Results | Where-Object { -not $_.Success }
    $batchCount = ($Results | Select-Object -ExpandProperty Batch -Unique).Count
    
    $stats = [PSCustomObject]@{
        TotalItems = $Results.Count
        SuccessfulItems = $successful.Count
        FailedItems = $failed.Count
        SuccessRate = [Math]::Round(($successful.Count / $Results.Count) * 100, 2)
        FailureRate = [Math]::Round(($failed.Count / $Results.Count) * 100, 2)
        TotalBatches = $batchCount
        AverageItemsPerBatch = [Math]::Round($Results.Count / $batchCount, 2)
    }
    
    # Group failures by batch
    if ($failed.Count -gt 0) {
        $failuresByBatch = $failed | Group-Object -Property Batch | 
            Select-Object @{N='Batch';E={$_.Name}}, Count |
            Sort-Object -Property Batch
        
        $stats | Add-Member -NotePropertyName 'FailuresByBatch' -NotePropertyValue $failuresByBatch
        
        # Most common errors
        $errorGroups = $failed | Group-Object -Property Error | 
            Sort-Object -Property Count -Descending |
            Select-Object -First 5 @{N='Error';E={$_.Name}}, Count
        
        $stats | Add-Member -NotePropertyName 'TopErrors' -NotePropertyValue $errorGroups
    }
    
    return $stats
}
