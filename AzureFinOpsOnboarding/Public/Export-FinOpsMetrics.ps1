function Measure-FinOpsOperation {
    <#
    .SYNOPSIS
        Measures operation performance and collects metrics.
    
    .DESCRIPTION
        Wraps scriptblock execution with performance tracking. Collects duration,
        success/failure status, and optional tags for categorization.
        
        Metrics are stored in module scope and can be exported for analysis.
    
    .PARAMETER OperationName
        Name of the operation being measured (e.g., 'Test-AzSubscriptions', 'GetBearerToken').
    
    .PARAMETER ScriptBlock
        The scriptblock to execute and measure.
    
    .PARAMETER Tags
        Optional hashtable of tags for categorization (e.g., @{Service='Azure'; Type='API'}).
    
    .PARAMETER ThrowOnError
        If true, re-throws exceptions after logging. Default is true.
    
    .EXAMPLE
        $result = Measure-FinOpsOperation -OperationName 'GetSubscriptions' -ScriptBlock {
            Test-FinOpsAzSubscriptions -Token $token
        } -Tags @{Service='Azure'; Type='Validation'}
    
    .EXAMPLE
        # Measure without throwing errors
        $result = Measure-FinOpsOperation -OperationName 'OptionalCheck' -ScriptBlock {
            Get-SomeData
        } -ThrowOnError:$false
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OperationName,
        
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        
        [Parameter()]
        [hashtable]$Tags = @{},
        
        [Parameter()]
        [switch]$ThrowOnError = $true
    )
    
    # Initialize metrics collection if not exists
    if (-not $script:FinOpsPerformanceMetrics) {
        $script:FinOpsPerformanceMetrics = [System.Collections.ArrayList]::new()
    }
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $success = $true
    $error = $null
    $result = $null
    
    try {
        Write-FinOpsLog -Level 'Debug' -Message "Operation started" -Context @{
            Operation = $OperationName
        } -Category 'Performance'
        
        $result = & $ScriptBlock
        
        Write-FinOpsLog -Level 'Debug' -Message "Operation completed" -Context @{
            Operation = $OperationName
            Duration = $stopwatch.Elapsed.TotalSeconds
        } -Category 'Performance'
        
        return $result
    }
    catch {
        $success = $false
        $error = $_.Exception.Message
        
        Write-FinOpsLog -Level 'Error' -Message "Operation failed" -Context @{
            Operation = $OperationName
            Error = $error
            Duration = $stopwatch.Elapsed.TotalSeconds
        } -Category 'Performance' -Exception $_.Exception
        
        if ($ThrowOnError) {
            throw
        }
    }
    finally {
        $stopwatch.Stop()
        
        # Record metric
        $metric = [PSCustomObject]@{
            Timestamp = (Get-Date).ToUniversalTime()
            Operation = $OperationName
            Duration = $stopwatch.Elapsed.TotalSeconds
            DurationMs = $stopwatch.Elapsed.TotalMilliseconds
            Success = $success
            Error = $error
            Tags = $Tags
            CorrelationId = if ($script:FinOpsLogSettings) { $script:FinOpsLogSettings.CorrelationId } else { $null }
        }
        
        [void]$script:FinOpsPerformanceMetrics.Add($metric)
    }
}

function Get-FinOpsPerformanceMetrics {
    <#
    .SYNOPSIS
        Retrieves collected performance metrics.
    
    .DESCRIPTION
        Returns all or filtered performance metrics collected during the session.
    
    .PARAMETER OperationName
        Filter by specific operation name.
    
    .PARAMETER Tags
        Filter by tags (hashtable). Metrics must have ALL specified tags.
    
    .PARAMETER MinDuration
        Filter metrics with duration >= this value (seconds).
    
    .PARAMETER MaxDuration
        Filter metrics with duration <= this value (seconds).
    
    .PARAMETER FailedOnly
        Return only failed operations.
    
    .PARAMETER Last
        Return only the last N metrics.
    
    .EXAMPLE
        Get-FinOpsPerformanceMetrics
    
    .EXAMPLE
        Get-FinOpsPerformanceMetrics -OperationName 'GetSubscriptions'
    
    .EXAMPLE
        Get-FinOpsPerformanceMetrics -Tags @{Service='Azure'} -MinDuration 5
    
    .EXAMPLE
        Get-FinOpsPerformanceMetrics -FailedOnly -Last 10
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$OperationName,
        
        [Parameter()]
        [hashtable]$Tags,
        
        [Parameter()]
        [double]$MinDuration,
        
        [Parameter()]
        [double]$MaxDuration,
        
        [Parameter()]
        [switch]$FailedOnly,
        
        [Parameter()]
        [int]$Last
    )
    
    if (-not $script:FinOpsPerformanceMetrics) {
        return @()
    }
    
    $metrics = $script:FinOpsPerformanceMetrics
    
    # Filter by operation name
    if ($OperationName) {
        $metrics = $metrics | Where-Object { $_.Operation -eq $OperationName }
    }
    
    # Filter by tags
    if ($Tags) {
        $metrics = $metrics | Where-Object {
            $metricTags = $_.Tags
            $match = $true
            foreach ($key in $Tags.Keys) {
                if (-not $metricTags.ContainsKey($key) -or $metricTags[$key] -ne $Tags[$key]) {
                    $match = $false
                    break
                }
            }
            $match
        }
    }
    
    # Filter by duration
    if ($PSBoundParameters.ContainsKey('MinDuration')) {
        $metrics = $metrics | Where-Object { $_.Duration -ge $MinDuration }
    }
    
    if ($PSBoundParameters.ContainsKey('MaxDuration')) {
        $metrics = $metrics | Where-Object { $_.Duration -le $MaxDuration }
    }
    
    # Filter failed only
    if ($FailedOnly) {
        $metrics = $metrics | Where-Object { -not $_.Success }
    }
    
    # Return last N
    if ($Last) {
        $metrics = $metrics | Select-Object -Last $Last
    }
    
    return $metrics
}

function Export-FinOpsMetrics {
    <#
    .SYNOPSIS
        Exports performance metrics to file.
    
    .DESCRIPTION
        Exports collected metrics to JSON or CSV format for analysis.
    
    .PARAMETER Path
        Output file path.
    
    .PARAMETER Format
        Output format: JSON or CSV. Default is JSON.
    
    .PARAMETER IncludeStatistics
        Include summary statistics in JSON export.
    
    .EXAMPLE
        Export-FinOpsMetrics -Path 'C:\Logs\metrics.json'
    
    .EXAMPLE
        Export-FinOpsMetrics -Path 'C:\Logs\metrics.csv' -Format CSV
    
    .EXAMPLE
        Export-FinOpsMetrics -Path 'C:\Logs\metrics.json' -IncludeStatistics
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        
        [Parameter()]
        [ValidateSet('JSON', 'CSV')]
        [string]$Format = 'JSON',
        
        [Parameter()]
        [switch]$IncludeStatistics
    )
    
    if (-not $script:FinOpsPerformanceMetrics -or $script:FinOpsPerformanceMetrics.Count -eq 0) {
        Write-Warning "No performance metrics to export"
        return
    }
    
    # Ensure directory exists
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }
    
    switch ($Format) {
        'JSON' {
            if ($IncludeStatistics) {
                $stats = Get-FinOpsMetricsStatistics
                $export = @{
                    ExportTime = (Get-Date).ToUniversalTime().ToString('o')
                    TotalMetrics = $script:FinOpsPerformanceMetrics.Count
                    Statistics = $stats
                    Metrics = $script:FinOpsPerformanceMetrics
                }
                $export | ConvertTo-Json -Depth 10 | Set-Content -Path $Path
            }
            else {
                $script:FinOpsPerformanceMetrics | ConvertTo-Json -Depth 10 | Set-Content -Path $Path
            }
        }
        'CSV' {
            # Flatten tags for CSV export
            $flattened = $script:FinOpsPerformanceMetrics | ForEach-Object {
                $tagString = if ($_.Tags.Count -gt 0) {
                    ($_.Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';'
                } else { '' }
                
                [PSCustomObject]@{
                    Timestamp = $_.Timestamp.ToString('o')
                    Operation = $_.Operation
                    Duration = $_.Duration
                    DurationMs = $_.DurationMs
                    Success = $_.Success
                    Error = $_.Error
                    Tags = $tagString
                    CorrelationId = $_.CorrelationId
                }
            }
            
            $flattened | Export-Csv -Path $Path -NoTypeInformation
        }
    }
    
    Write-FinOpsLog -Level 'Info' -Message "Metrics exported" -Context @{
        Path = $Path
        Format = $Format
        Count = $script:FinOpsPerformanceMetrics.Count
    } -Category 'Performance'
}

function Get-FinOpsMetricsStatistics {
    <#
    .SYNOPSIS
        Calculates statistics from collected metrics.
    
    .DESCRIPTION
        Provides summary statistics including count, success rate, duration statistics.
    
    .EXAMPLE
        Get-FinOpsMetricsStatistics | Format-List
    #>
    [CmdletBinding()]
    param()
    
    if (-not $script:FinOpsPerformanceMetrics -or $script:FinOpsPerformanceMetrics.Count -eq 0) {
        return $null
    }
    
    $metrics = $script:FinOpsPerformanceMetrics
    $durations = $metrics | Select-Object -ExpandProperty Duration
    
    $stats = [PSCustomObject]@{
        TotalOperations = $metrics.Count
        SuccessfulOperations = ($metrics | Where-Object { $_.Success }).Count
        FailedOperations = ($metrics | Where-Object { -not $_.Success }).Count
        SuccessRate = [Math]::Round((($metrics | Where-Object { $_.Success }).Count / $metrics.Count) * 100, 2)
        TotalDuration = [Math]::Round(($durations | Measure-Object -Sum).Sum, 3)
        AverageDuration = [Math]::Round(($durations | Measure-Object -Average).Average, 3)
        MinDuration = [Math]::Round(($durations | Measure-Object -Minimum).Minimum, 3)
        MaxDuration = [Math]::Round(($durations | Measure-Object -Maximum).Maximum, 3)
        UniqueOperations = ($metrics | Select-Object -ExpandProperty Operation -Unique).Count
        FirstMetric = $metrics[0].Timestamp
        LastMetric = $metrics[-1].Timestamp
    }
    
    # Top operations by count
    $stats | Add-Member -NotePropertyName 'TopOperations' -NotePropertyValue (
        $metrics | Group-Object -Property Operation | 
        Sort-Object -Property Count -Descending | 
        Select-Object -First 5 -Property @{N='Operation';E={$_.Name}}, Count
    )
    
    # Slowest operations
    $stats | Add-Member -NotePropertyName 'SlowestOperations' -NotePropertyValue (
        $metrics | Sort-Object -Property Duration -Descending | 
        Select-Object -First 5 -Property Operation, Duration, Timestamp
    )
    
    return $stats
}

function Clear-FinOpsMetrics {
    <#
    .SYNOPSIS
        Clears collected performance metrics.
    
    .DESCRIPTION
        Removes all collected performance metrics from memory.
    
    .EXAMPLE
        Clear-FinOpsMetrics
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param()
    
    if ($PSCmdlet.ShouldProcess("Performance metrics ($($script:FinOpsPerformanceMetrics.Count) entries)", "Clear all metrics")) {
        if ($script:FinOpsPerformanceMetrics) {
            $count = $script:FinOpsPerformanceMetrics.Count
            $script:FinOpsPerformanceMetrics.Clear()
            Write-FinOpsLog -Level 'Info' -Message "Performance metrics cleared" -Context @{
                Count = $count
            } -Category 'Performance'
        }
    }
}
