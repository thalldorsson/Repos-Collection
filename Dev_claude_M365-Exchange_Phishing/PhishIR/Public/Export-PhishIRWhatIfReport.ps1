function Export-PhishIRWhatIfReport {
    <#
    .SYNOPSIS
        Generates a local WhatIf report for planned purge operations without making remote calls.
    
    .DESCRIPTION
        Creates a change plan with impact analysis, pilot ring suggestions, and confirmation requirements.
        Outputs CSV and JSON reports for review before executing actual purge operations.
        This is a safe, read-only operation that helps plan and validate purge actions.
    
    .PARAMETER Mailboxes
        Array of mailbox addresses to target for the purge operation.
    
    .PARAMETER ContentMatchQuery
        The KQL query string that will be used to identify messages for purging.
    
    .PARAMETER PurgeType
        Type of purge operation: SoftDelete (recoverable) or HardDelete (permanent).
    
    .PARAMETER OutputDir
        Directory where the WhatIf report files will be saved.
    
    .EXAMPLE
        Export-PhishIRWhatIfReport -Mailboxes 'user@contoso.com' -ContentMatchQuery 'from:evil@bad.com' -PurgeType SoftDelete -OutputDir 'C:\Reports'
        
        Generates a WhatIf report for a SoftDelete operation targeting one mailbox.
    
    .EXAMPLE
        $mailboxes = Get-Content '.\pilot-ring0.txt'
        Export-PhishIRWhatIfReport -Mailboxes $mailboxes -ContentMatchQuery 'subject:"Urgent Invoice"' -PurgeType HardDelete -OutputDir '.\WhatIf'
        
        Generates a HardDelete WhatIf report with confirmation requirements for multiple mailboxes.
    
    .OUTPUTS
        PSCustomObject with properties: Csv, Json, CorrelationId
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Mailboxes,
        
        [Parameter(Mandatory)]
        [string]$ContentMatchQuery,
        
        [Parameter(Mandatory)]
        [ValidateSet('SoftDelete','HardDelete')]
        [string]$PurgeType,
        
        [Parameter(Mandatory)]
        [string]$OutputDir
    )
    
    $correlationId = [guid]::NewGuid().ToString()
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $csvPath = Join-Path $OutputDir "WhatIf-$timestamp.csv"
    $jsonPath = Join-Path $OutputDir "WhatIf-$timestamp.json"
    
    # Ensure output directory exists
    $null = New-Item -ItemType Directory -Path $OutputDir -Force -ErrorAction SilentlyContinue
    
    # Calculate ring-0 pilot suggestions (10% or max 10)
    $pilotCount = [Math]::Min(10, [Math]::Max(1, [Math]::Ceiling($Mailboxes.Count * 0.1)))
    $pilotMailboxes = $Mailboxes | Select-Object -First $pilotCount
    
    # Check health prerequisites
    $healthStatus = 'Unknown'
    try {
        if (Get-Command Get-PhishIRHealth -ErrorAction SilentlyContinue) {
            $health = Get-PhishIRHealth
            $healthStatus = $health.Status
        }
    } catch {
        $healthStatus = 'Degraded'
    }
    
    # Build WhatIf report object
    $report = [PSCustomObject]@{
        CorrelationId = $correlationId
        Timestamp = (Get-Date).ToString('o')
        MailboxCount = $Mailboxes.Count
        ContentMatchQuery = $ContentMatchQuery
        PurgeType = $PurgeType
        HardDeleteConfirmationRequired = ($PurgeType -eq 'HardDelete')
        HardDeleteConfirmationPhrase = if ($PurgeType -eq 'HardDelete') { 'CONFIRM: I have legal approval for permanent deletion' } else { $null }
        PrereqStatus = $healthStatus
        SampleRing0 = ($pilotMailboxes -join '; ')
        Ring0Count = $pilotCount
        EstimatedImpact = @{
            TotalMailboxes = $Mailboxes.Count
            PilotRing = "$pilotCount mailboxes (10%)"
            PurgeType = $PurgeType
            Recoverable = ($PurgeType -eq 'SoftDelete')
        }
        NextSteps = @(
            if ($PurgeType -eq 'HardDelete') { 'Obtain legal/compliance approval for permanent deletion' }
            'Review pilot ring-0 mailboxes'
            'Execute pilot purge with -PreviewOnly first'
            'Validate results and expand to remaining mailboxes'
            'Document correlation ID for audit trail'
        )
        RollbackPlan = if ($PurgeType -eq 'SoftDelete') { 
            'Items recoverable from Recoverable Items folder for 30 days' 
        } else { 
            'HardDelete is permanent - no rollback possible. Ensure backups exist.' 
        }
    }
    
    # Export CSV (flattened view)
    $csvData = [PSCustomObject]@{
        CorrelationId = $report.CorrelationId
        Timestamp = $report.Timestamp
        MailboxCount = $report.MailboxCount
        ContentMatchQuery = $report.ContentMatchQuery
        PurgeType = $report.PurgeType
        HardDeleteConfirmationRequired = $report.HardDeleteConfirmationRequired
        HardDeleteConfirmationPhrase = $report.HardDeleteConfirmationPhrase
        PrereqStatus = $report.PrereqStatus
        SampleRing0 = $report.SampleRing0
        Ring0Count = $report.Ring0Count
        Recoverable = $report.EstimatedImpact.Recoverable
        RollbackPlan = $report.RollbackPlan
    }
    $csvData | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    
    # Export JSON (full structured view)
    $report | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Encoding UTF8
    
    Write-PhishIRLog -Level Info -Message 'WhatIf report generated' -Properties @{
        CorrelationId = $correlationId
        MailboxCount = $Mailboxes.Count
        PurgeType = $PurgeType
        CsvPath = $csvPath
        JsonPath = $jsonPath
    }
    
    return [PSCustomObject]@{
        Csv = $csvPath
        Json = $jsonPath
        CorrelationId = $correlationId
    }
}
