function Initialize-FinOpsCorrelationId {
    <#
    .SYNOPSIS
        Initializes or retrieves the current correlation ID for distributed tracing.
    
    .DESCRIPTION
        Creates a new correlation ID (GUID) if one doesn't exist, or returns the current one.
        Correlation IDs are used to trace requests across multiple function calls and API requests.
    
    .PARAMETER Force
        Force creation of a new correlation ID even if one exists.
    
    .EXAMPLE
        $correlationId = Initialize-FinOpsCorrelationId
    
    .EXAMPLE
        # Force new correlation ID for new operation
        $correlationId = Initialize-FinOpsCorrelationId -Force
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$Force
    )
    
    if (-not $script:FinOpsLogSettings) {
        $script:FinOpsLogSettings = @{
            LogToConsole = $true
            LogToFile = $false
            LogToEventLog = $false
            MinimumLevel = 'Info'
            CorrelationId = $null
            LogFilePath = $null
        }
    }
    
    if ($Force -or -not $script:FinOpsLogSettings.CorrelationId) {
        $newCorrelationId = [guid]::NewGuid().ToString()
        $script:FinOpsLogSettings.CorrelationId = $newCorrelationId
        
        Write-FinOpsLog -Level 'Debug' -Message "Correlation ID initialized" -Context @{
            CorrelationId = $newCorrelationId
            Force = $Force.IsPresent
        } -Category 'Tracing'
        
        return $newCorrelationId
    }
    
    return $script:FinOpsLogSettings.CorrelationId
}

function Get-FinOpsCorrelationId {
    <#
    .SYNOPSIS
        Retrieves the current correlation ID.
    
    .DESCRIPTION
        Returns the current correlation ID used for distributed tracing.
        Returns null if no correlation ID has been initialized.
    
    .EXAMPLE
        $correlationId = Get-FinOpsCorrelationId
        if ($correlationId) {
            Write-Host "Current correlation ID: $correlationId"
        }
    #>
    [CmdletBinding()]
    param()
    
    if ($script:FinOpsLogSettings) {
        return $script:FinOpsLogSettings.CorrelationId
    }
    
    return $null
}

function Set-FinOpsCorrelationId {
    <#
    .SYNOPSIS
        Sets a specific correlation ID for distributed tracing.
    
    .DESCRIPTION
        Allows setting a custom correlation ID, useful for continuing traces
        from external systems or parent operations.
    
    .PARAMETER CorrelationId
        The correlation ID to set. Must be a valid GUID string.
    
    .EXAMPLE
        Set-FinOpsCorrelationId -CorrelationId 'a1b2c3d4-e5f6-4g7h-8i9j-0k1l2m3n4o5p'
    
    .EXAMPLE
        # Use correlation ID from external system
        $externalId = $request.Headers['X-Correlation-ID']
        Set-FinOpsCorrelationId -CorrelationId $externalId
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({
            if ($_ -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
                $true
            } else {
                throw "CorrelationId must be a valid GUID format"
            }
        })]
        [string]$CorrelationId
    )
    
    if (-not $script:FinOpsLogSettings) {
        $script:FinOpsLogSettings = @{
            LogToConsole = $true
            LogToFile = $false
            LogToEventLog = $false
            MinimumLevel = 'Info'
            CorrelationId = $null
            LogFilePath = $null
        }
    }
    
    $oldCorrelationId = $script:FinOpsLogSettings.CorrelationId
    $script:FinOpsLogSettings.CorrelationId = $CorrelationId
    
    Write-FinOpsLog -Level 'Debug' -Message "Correlation ID set" -Context @{
        OldCorrelationId = $oldCorrelationId
        NewCorrelationId = $CorrelationId
    } -Category 'Tracing'
}

function Clear-FinOpsCorrelationId {
    <#
    .SYNOPSIS
        Clears the current correlation ID.
    
    .DESCRIPTION
        Removes the current correlation ID, useful when starting a completely new operation context.
    
    .EXAMPLE
        Clear-FinOpsCorrelationId
    #>
    [CmdletBinding()]
    param()
    
    if ($script:FinOpsLogSettings -and $script:FinOpsLogSettings.CorrelationId) {
        $oldCorrelationId = $script:FinOpsLogSettings.CorrelationId
        $script:FinOpsLogSettings.CorrelationId = $null
        
        Write-FinOpsLog -Level 'Debug' -Message "Correlation ID cleared" -Context @{
            PreviousCorrelationId = $oldCorrelationId
        } -Category 'Tracing'
    }
}

function Start-FinOpsTraceSpan {
    <#
    .SYNOPSIS
        Starts a trace span for detailed operation tracking.
    
    .DESCRIPTION
        Creates a trace span with start time and operation details.
        Use with Stop-FinOpsTraceSpan to measure operation duration.
        
        Spans are nested and form a trace hierarchy for complex operations.
    
    .PARAMETER OperationName
        Name of the operation being traced (e.g., 'ValidateSubscription', 'GetBearerToken').
    
    .PARAMETER Tags
        Optional hashtable of tags for the span (e.g., @{SubscriptionId='abc'; TenantId='xyz'}).
    
    .EXAMPLE
        $spanId = Start-FinOpsTraceSpan -OperationName 'OnboardSubscription' -Tags @{
            SubscriptionId = $subscriptionId
            TenantId = $tenantId
        }
        try {
            # ... operation logic ...
        } finally {
            Stop-FinOpsTraceSpan -SpanId $spanId
        }
    
    .EXAMPLE
        # Nested spans
        $parentSpan = Start-FinOpsTraceSpan -OperationName 'ProcessMultipleSubscriptions'
        foreach ($sub in $subscriptions) {
            $childSpan = Start-FinOpsTraceSpan -OperationName 'ProcessSingleSubscription' -Tags @{SubscriptionId=$sub}
            # ... process ...
            Stop-FinOpsTraceSpan -SpanId $childSpan
        }
        Stop-FinOpsTraceSpan -SpanId $parentSpan
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OperationName,
        
        [Parameter()]
        [hashtable]$Tags = @{}
    )
    
    # Initialize trace storage
    if (-not $script:FinOpsTraceSpans) {
        $script:FinOpsTraceSpans = [System.Collections.ArrayList]::new()
    }
    
    # Ensure correlation ID exists
    $correlationId = Initialize-FinOpsCorrelationId
    
    $spanId = [guid]::NewGuid().ToString()
    $span = [PSCustomObject]@{
        SpanId = $spanId
        CorrelationId = $correlationId
        OperationName = $OperationName
        StartTime = (Get-Date).ToUniversalTime()
        EndTime = $null
        Duration = $null
        Tags = $Tags
        Success = $null
        Error = $null
        ParentSpanId = $script:CurrentSpanId
    }
    
    [void]$script:FinOpsTraceSpans.Add($span)
    
    # Set as current span for nesting
    $script:CurrentSpanId = $spanId
    
    Write-FinOpsLog -Level 'Debug' -Message "Trace span started" -Context @{
        SpanId = $spanId
        OperationName = $OperationName
        ParentSpanId = $span.ParentSpanId
        Tags = $Tags
    } -Category 'Tracing'
    
    return $spanId
}

function Stop-FinOpsTraceSpan {
    <#
    .SYNOPSIS
        Stops a trace span and records duration.
    
    .DESCRIPTION
        Completes a trace span, calculating duration and recording success/failure status.
    
    .PARAMETER SpanId
        The span ID returned from Start-FinOpsTraceSpan.
    
    .PARAMETER Success
        Whether the operation succeeded. Default is $true.
    
    .PARAMETER Error
        Optional error message if operation failed.
    
    .EXAMPLE
        Stop-FinOpsTraceSpan -SpanId $spanId -Success $true
    
    .EXAMPLE
        Stop-FinOpsTraceSpan -SpanId $spanId -Success $false -Error "Validation failed"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SpanId,
        
        [Parameter()]
        [bool]$Success = $true,
        
        [Parameter()]
        [string]$Error
    )
    
    if (-not $script:FinOpsTraceSpans) {
        Write-Warning "No trace spans found"
        return
    }
    
    $span = $script:FinOpsTraceSpans | Where-Object { $_.SpanId -eq $SpanId } | Select-Object -First 1
    
    if (-not $span) {
        Write-Warning "Span $SpanId not found"
        return
    }
    
    $span.EndTime = (Get-Date).ToUniversalTime()
    $span.Duration = ($span.EndTime - $span.StartTime).TotalSeconds
    $span.Success = $Success
    $span.Error = $Error
    
    # Restore parent span as current
    $script:CurrentSpanId = $span.ParentSpanId
    
    Write-FinOpsLog -Level 'Debug' -Message "Trace span stopped" -Context @{
        SpanId = $SpanId
        OperationName = $span.OperationName
        Duration = [Math]::Round($span.Duration, 3)
        Success = $Success
        Error = $Error
    } -Category 'Tracing'
}

function Get-FinOpsTraceSpans {
    <#
    .SYNOPSIS
        Retrieves trace spans for analysis.
    
    .DESCRIPTION
        Returns all or filtered trace spans collected during the session.
    
    .PARAMETER CorrelationId
        Filter by correlation ID.
    
    .PARAMETER OperationName
        Filter by operation name.
    
    .PARAMETER FailedOnly
        Return only failed spans.
    
    .EXAMPLE
        Get-FinOpsTraceSpans
    
    .EXAMPLE
        Get-FinOpsTraceSpans -CorrelationId $correlationId
    
    .EXAMPLE
        Get-FinOpsTraceSpans -FailedOnly | Format-Table OperationName, Duration, Error
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$CorrelationId,
        
        [Parameter()]
        [string]$OperationName,
        
        [Parameter()]
        [switch]$FailedOnly
    )
    
    if (-not $script:FinOpsTraceSpans) {
        return @()
    }
    
    $spans = $script:FinOpsTraceSpans
    
    if ($CorrelationId) {
        $spans = $spans | Where-Object { $_.CorrelationId -eq $CorrelationId }
    }
    
    if ($OperationName) {
        $spans = $spans | Where-Object { $_.OperationName -eq $OperationName }
    }
    
    if ($FailedOnly) {
        $spans = $spans | Where-Object { $_.Success -eq $false }
    }
    
    return $spans
}

function Export-FinOpsTrace {
    <#
    .SYNOPSIS
        Exports trace spans to file.
    
    .DESCRIPTION
        Exports collected trace spans to JSON format for analysis.
    
    .PARAMETER Path
        Output file path.
    
    .PARAMETER CorrelationId
        Optional correlation ID to export specific trace.
    
    .EXAMPLE
        Export-FinOpsTrace -Path 'C:\Logs\trace.json'
    
    .EXAMPLE
        Export-FinOpsTrace -Path 'C:\Logs\trace.json' -CorrelationId $correlationId
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        
        [Parameter()]
        [string]$CorrelationId
    )
    
    $spans = if ($CorrelationId) {
        Get-FinOpsTraceSpans -CorrelationId $CorrelationId
    } else {
        Get-FinOpsTraceSpans
    }
    
    if ($spans.Count -eq 0) {
        Write-Warning "No trace spans to export"
        return
    }
    
    # Ensure directory exists
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }
    
    $export = @{
        ExportTime = (Get-Date).ToUniversalTime().ToString('o')
        TotalSpans = $spans.Count
        Traces = $spans
    }
    
    $export | ConvertTo-Json -Depth 10 | Set-Content -Path $Path
    
    Write-FinOpsLog -Level 'Info' -Message "Trace spans exported" -Context @{
        Path = $Path
        Count = $spans.Count
        CorrelationId = $CorrelationId
    } -Category 'Tracing'
}

function Clear-FinOpsTraceSpans {
    <#
    .SYNOPSIS
        Clears all trace spans from memory.
    
    .DESCRIPTION
        Removes all collected trace spans.
    
    .EXAMPLE
        Clear-FinOpsTraceSpans
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param()
    
    if ($PSCmdlet.ShouldProcess("All trace spans ($($script:FinOpsTraceSpans.Count) spans)", "Clear all spans")) {
        if ($script:FinOpsTraceSpans) {
            $count = $script:FinOpsTraceSpans.Count
            $script:FinOpsTraceSpans.Clear()
            $script:CurrentSpanId = $null
            Write-FinOpsLog -Level 'Info' -Message "Trace spans cleared" -Context @{
                Count = $count
            } -Category 'Tracing'
        }
    }
}
