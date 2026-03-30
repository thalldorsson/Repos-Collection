function Get-PhishIRDefenderIncident {
    <#
    .SYNOPSIS
        Retrieves incident details from Microsoft 365 Defender XDR API.
    
    .DESCRIPTION
        Pulls incident context including alerts, entities, timeline, and evidence.
        Enriches purge operations with threat intelligence from Defender.
        Requires Microsoft.Graph or manual Graph API authentication.
    
    .PARAMETER IncidentId
        Defender incident ID to retrieve.
    
    .PARAMETER IncludeAlerts
        Include detailed alert information in the output.
    
    .PARAMETER IncludeEvidence
        Include evidence artifacts (files, processes, emails) in the output.
    
    .EXAMPLE
        Get-PhishIRDefenderIncident -IncidentId 12345 -IncludeAlerts -IncludeEvidence
        
        Retrieve full incident context for incident 12345.
    
    .EXAMPLE
        $incident = Get-PhishIRDefenderIncident -IncidentId 12345
        $senders = $incident.Alerts | Where-Object { $_.Category -eq 'Email' } | Select-Object -ExpandProperty SenderAddress -Unique
        
        Extract unique sender addresses from phishing incident for purge operation.
    
    .OUTPUTS
        PSCustomObject with incident details, alerts, and evidence.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$IncidentId,
        
        [switch]$IncludeAlerts,
        
        [switch]$IncludeEvidence
    )
    
    try {
        # Check for Microsoft.Graph module
        if (-not (Get-Module Microsoft.Graph.Security -ListAvailable)) {
            Write-PhishIRLog -Level Warning -Message 'Microsoft.Graph.Security module not installed. Install with: Install-Module Microsoft.Graph.Security'
            throw 'Microsoft.Graph.Security module required for Defender API integration'
        }
        
        # Import module if not already loaded
        if (-not (Get-Module Microsoft.Graph.Security)) {
            Import-Module Microsoft.Graph.Security -ErrorAction Stop
        }
        
        # Get incident
        Write-PhishIRLog -Level Info -Message "Retrieving Defender incident $IncidentId"
        $incident = Get-MgSecurityIncident -IncidentId $IncidentId -ErrorAction Stop
        
        $result = [PSCustomObject]@{
            IncidentId = $incident.Id
            IncidentName = $incident.DisplayName
            Status = $incident.Status
            Severity = $incident.Severity
            Classification = $incident.Classification
            Determination = $incident.Determination
            CreatedDateTime = $incident.CreatedDateTime
            LastUpdateDateTime = $incident.LastUpdateDateTime
            AssignedTo = $incident.AssignedTo
            Tags = $incident.Tags
            Alerts = @()
            Evidence = @()
            RecommendedActions = $incident.RecommendedActions
        }
        
        if ($IncludeAlerts) {
            Write-PhishIRLog -Level Info -Message "Retrieving alerts for incident $IncidentId"
            $alerts = Get-MgSecurityIncidentAlert -IncidentId $IncidentId -ErrorAction Stop
            $result.Alerts = $alerts | Select-Object -Property AlertId, Title, Category, Severity, DetectionSource, Status, @{N='Entities';E={$_.Entities.Count}}
        }
        
        if ($IncludeEvidence) {
            Write-PhishIRLog -Level Info -Message "Retrieving evidence for incident $IncidentId"
            # Evidence typically embedded in alerts
            $evidenceList = @()
            foreach ($alert in $incident.Alerts) {
                if ($alert.Evidence) {
                    $evidenceList += $alert.Evidence | Select-Object -Property EvidenceRole, RemediationStatus, Verdict, @{N='EvidenceType';E={$_.GetType().Name}}
                }
            }
            $result.Evidence = $evidenceList
        }
        
        Write-PhishIRLog -Level Info -Message "Retrieved incident $IncidentId" -Properties @{
            IncidentId = $IncidentId
            AlertCount = $result.Alerts.Count
            EvidenceCount = $result.Evidence.Count
        }
        
        return $result
        
    } catch {
        Write-PhishIRLog -Level Error -Message "Failed to retrieve Defender incident $IncidentId" -Exception $_.Exception
        throw
    }
}

function Add-PhishIRIncidentTag {
    <#
    .SYNOPSIS
        Tags a Defender incident with PhishIR correlation ID for tracking.
    
    .DESCRIPTION
        Adds a tag to a Defender XDR incident to link it with PhishIR purge operations.
        Enables close-loop tracking from detection to remediation.
    
    .PARAMETER IncidentId
        Defender incident ID to tag.
    
    .PARAMETER CorrelationId
        PhishIR correlation ID (GUID) from purge operation.
    
    .PARAMETER AdditionalTags
        Additional tags to add (e.g., 'Remediated', 'PurgeCompleted').
    
    .EXAMPLE
        Add-PhishIRIncidentTag -IncidentId 12345 -CorrelationId 'a1b2c3d4-...' -AdditionalTags 'Remediated'
        
        Tag incident 12345 with PhishIR correlation ID and remediation status.
    
    .OUTPUTS
        None (updates incident in Defender portal).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$IncidentId,
        
        [Parameter(Mandatory)]
        [string]$CorrelationId,
        
        [string[]]$AdditionalTags = @()
    )
    
    try {
        if (-not (Get-Module Microsoft.Graph.Security -ListAvailable)) {
            throw 'Microsoft.Graph.Security module required for Defender API integration'
        }
        
        if (-not (Get-Module Microsoft.Graph.Security)) {
            Import-Module Microsoft.Graph.Security -ErrorAction Stop
        }
        
        $tags = @("PhishIR:$CorrelationId") + $AdditionalTags
        
        if ($PSCmdlet.ShouldProcess("Incident $IncidentId", "Add tags: $($tags -join ', ')")) {
            Update-MgSecurityIncident -IncidentId $IncidentId -Tags $tags -ErrorAction Stop
            
            Write-PhishIRLog -Level Info -Message "Tagged Defender incident $IncidentId" -Properties @{
                IncidentId = $IncidentId
                CorrelationId = $CorrelationId
                Tags = ($tags -join '; ')
            }
        }
        
    } catch {
        Write-PhishIRLog -Level Error -Message "Failed to tag Defender incident $IncidentId" -Exception $_.Exception
        throw
    }
}
