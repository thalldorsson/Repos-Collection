#Requires -Version 5.1

<#
.SYNOPSIS
    Helper functions for compliance search operations
#>

function Test-MailboxesForPurge {
    <#
    .SYNOPSIS
        Validate mailboxes and collect hold information

    .DESCRIPTION
        Validates each mailbox exists and collects litigation hold, in-place hold,
        and retention settings for safety checks

    .OUTPUTS
        Returns hashtable with ValidMailboxes, InvalidMailboxes, and MailboxDetails arrays
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Mailboxes
    )

    $valid = @()
    $invalid = @()
    $mailboxDetails = @()

    foreach ($mbx in $Mailboxes) {
        try {
            $m = Get-EXOMailbox -Identity $mbx -ErrorAction Stop
            if ($m) {
                $primary = $m.PrimarySmtpAddress.ToString()
                $valid += $primary

                # Collect hold and retention info
                $litHold = $null
                $sir = $null
                $retDays = $null
                $inPlace = $null

                if ($m.PSObject.Properties.Match('LitigationHoldEnabled').Count) {
                    $litHold = $m.LitigationHoldEnabled
                }
                if ($m.PSObject.Properties.Match('SingleItemRecoveryEnabled').Count) {
                    $sir = $m.SingleItemRecoveryEnabled
                }
                if ($m.PSObject.Properties.Match('RetainDeletedItemsFor').Count -and $m.RetainDeletedItemsFor) {
                    $retDays = [int]$m.RetainDeletedItemsFor.TotalDays
                }
                $inPlace = if ($m.PSObject.Properties.Match('InPlaceHolds').Count) {
                    ($m.InPlaceHolds | Measure-Object).Count
                } else {
                    $null
                }

                $mailboxDetails += [PSCustomObject]@{
                    PrimarySmtpAddress = $primary
                    LitigationHoldEnabled = $litHold
                    InPlaceHoldsCount = $inPlace
                    SingleItemRecoveryEnabled = $sir
                    RetainDeletedItemsForDays = $retDays
                }
            }
        }
        catch {
            $invalid += $mbx
            Write-PhishIRLog -Level Warning -Message "Mailbox not found: $mbx" -Properties @{
                Mailbox = $mbx
                Error = $_.Exception.Message
            }
        }
    }

    if ($invalid.Count -gt 0) {
        Write-Warn ("These addresses were not found and will be skipped: {0}" -f ($invalid -join ', '))
    }

    if (-not $valid -or $valid.Count -eq 0) {
        throw 'No valid mailboxes to process.'
    }

    return @{
        ValidMailboxes = ($valid | Sort-Object -Unique)
        InvalidMailboxes = $invalid
        MailboxDetails = $mailboxDetails
    }
}

function Test-HardDeleteSafety {
    <#
    .SYNOPSIS
        Check if HardDelete is safe on mailboxes with holds

    .DESCRIPTION
        Prevents HardDelete operations on mailboxes with litigation hold or in-place holds
        unless explicitly forced

    .OUTPUTS
        Throws exception if unsafe, returns $true if safe
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$MailboxDetails,

        [Parameter(Mandatory)]
        [string]$PurgeType,

        [switch]$ForceHoldBypass
    )

    if ($PurgeType -ne 'HardDelete') {
        return $true
    }

    $held = $MailboxDetails | Where-Object {
        $_.LitigationHoldEnabled -or ($_.InPlaceHoldsCount -as [int]) -gt 0
    }

    if ($held.Count -gt 0 -and -not $ForceHoldBypass) {
        $heldStr = ($held.PrimarySmtpAddress -join ', ')
        Write-PhishIRLog -Level Error -Message "HardDelete blocked on held mailboxes" -Properties @{
            HeldMailboxes = $heldStr
            PurgeType = $PurgeType
        }
        throw "HardDelete blocked due to holds: $heldStr. Use -ForceHoldBypass to override (ensure legal approval)."
    }

    if ($held.Count -gt 0 -and $ForceHoldBypass) {
        $heldStr = ($held.PrimarySmtpAddress -join ', ')
        Write-PhishIRLog -Level Warning -Message "HOLD BYPASS: HardDelete on held mailboxes" -Properties @{
            HeldMailboxes = $heldStr
            ForceHoldBypass = $true
        }
    }

    return $true
}

function New-ComplianceSearchJob {
    <#
    .SYNOPSIS
        Create and start a compliance search

    .DESCRIPTION
        Creates a compliance search with generated name, starts it, and waits for completion

    .OUTPUTS
        Returns the completed ComplianceSearch object
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Mailboxes,

        [Parameter(Mandatory)]
        [string]$ContentMatchQuery,

        [string]$SearchNamePrefix = 'IR'
    )

    $config = Import-PowerShellDataFile -Path "$PSScriptRoot/../Config.psd1"
    $pollInterval = $config.ComplianceSearchPollIntervalSeconds

    $searchName = ("{0}-{1}Mbx-{2}" -f $SearchNamePrefix, $Mailboxes.Count, (Get-Date -Format $config.ReportDateFormat))

    Write-PhishIRLog -Level Info -Message "Creating compliance search" -Properties @{
        SearchName = $searchName
        ContentMatchQuery = $ContentMatchQuery
        MailboxCount = $Mailboxes.Count
    }

    try {
        New-ComplianceSearch -Name $searchName -ExchangeLocation $Mailboxes -ContentMatchQuery $ContentMatchQuery -ErrorAction Stop | Out-Null
    }
    catch {
        Write-PhishIRLog -Level Error -Message "Compliance search creation failed" -Properties @{
            SearchName = $searchName
            Error = $_.Exception.Message
        } -Exception $_.Exception
        throw "Compliance search creation failed: $($_.Exception.Message)"
    }

    Start-ComplianceSearch -Identity $searchName | Out-Null

    # Poll for completion
    do {
        Start-Sleep -Seconds $pollInterval
        $cs = Get-ComplianceSearch -Identity $searchName
        $itemsForStatus = if ($null -ne $cs.Items) { $cs.Items } elseif ($null -ne $cs.ItemsCount) { $cs.ItemsCount } else { 'n/a' }
        Write-Info ("Search Status: {0} Items: {1}" -f $cs.Status, $itemsForStatus)
    } while ($cs.Status -ne 'Completed')

    Write-PhishIRLog -Level Info -Message "Compliance search completed" -Properties @{
        SearchName = $searchName
        Status = $cs.Status
        ItemsFound = $itemsForStatus
    }

    return $cs
}

function Export-SearchResults {
    <#
    .SYNOPSIS
        Export compliance search results to CSV and JSON

    .DESCRIPTION
        Parses search results and generates preview reports

    .OUTPUTS
        Returns hashtable with report paths and parsed results
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$ComplianceSearch,

        [Parameter(Mandatory)]
        [string]$OutputDir,

        [Parameter(Mandatory)]
        [string]$ContentMatchQuery,

        [Parameter(Mandatory)]
        [datetime]$StartUtc,

        [Parameter(Mandatory)]
        [datetime]$EndUtc,

        [Parameter(Mandatory)]
        [string[]]$Mailboxes
    )

    $config = Import-PowerShellDataFile -Path "$PSScriptRoot/../Config.psd1"

    # Parse per-mailbox results
    $successRaw = @($ComplianceSearch.SuccessResults)
    $failedRaw = @($ComplianceSearch.FailedResults)
    $perMailbox = @()

    foreach ($line in $successRaw) {
        if (-not $line) { continue }
        $mailbox = $null
        $count = $null

        if ($line -match '^(?<mbx>[^:]+):\s*(?<cnt>\d+)\s*$') {
            $mailbox = $Matches['mbx'].Trim()
            $count = [int]$Matches['cnt']
        }
        elseif ($line -match '(?i)Location\s*:\s*(?<mbx>[^,]+).*?(Items|Item Count)\s*:\s*(?<cnt>\d+)') {
            $mailbox = $Matches['mbx'].Trim()
            $count = [int]$Matches['cnt']
        }

        $perMailbox += [PSCustomObject]@{
            Mailbox = $mailbox
            ItemCount = $count
            Raw = $line
        }
    }

    $ts = Get-Date -Format $config.ReportDateFormat
    $previewCsv = Join-Path $OutputDir ("ContentPreview-$ts.csv")
    $previewJson = Join-Path $OutputDir ("ContentPreview-$ts.json")

    $perMailbox | Export-Csv -Path $previewCsv -NoTypeInformation -Encoding UTF8

    $itemsFoundPreview = if ($null -ne $ComplianceSearch.Items) {
        $ComplianceSearch.Items
    } elseif ($null -ne $ComplianceSearch.ItemsCount) {
        $ComplianceSearch.ItemsCount
    } else {
        0
    }

    $reportData = [PSCustomObject]@{
        TimestampUTC = (Get-Date).ToUniversalTime()
        SearchName = $ComplianceSearch.Name
        ContentMatchQuery = $ContentMatchQuery
        StartUtc = $StartUtc
        EndUtc = $EndUtc
        Mailboxes = ($Mailboxes -join '; ')
        ItemsFound = $itemsFoundPreview
        SearchStatus = $ComplianceSearch.Status
        PerMailboxSummary = $perMailbox
        SuccessResultsRaw = $successRaw
        FailedResultsRaw = $failedRaw
    }

    $reportData | ConvertTo-Json -Depth $config.ReportJsonDepth | Set-Content -Path $previewJson -Encoding UTF8

    Write-Info ("Preview saved to: `nCSV: $previewCsv`nJSON: $previewJson")

    Write-PhishIRLog -Level Info -Message "Search results exported" -Properties @{
        PreviewCsv = $previewCsv
        PreviewJson = $previewJson
        ItemsFound = $itemsFoundPreview
    }

    return @{
        PreviewCsv = $previewCsv
        PreviewJson = $previewJson
        PerMailboxResults = $perMailbox
        ItemsFound = $itemsFoundPreview
        ReportData = $reportData
    }
}

function Start-PurgeAction {
    <#
    .SYNOPSIS
        Execute purge action and wait for completion

    .DESCRIPTION
        Starts a compliance search purge action and polls until completion

    .OUTPUTS
        Returns the completed ComplianceSearchAction object
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SearchName,

        [Parameter(Mandatory)]
        [ValidateSet('SoftDelete', 'HardDelete')]
        [string]$PurgeType
    )

    $config = Import-PowerShellDataFile -Path "$PSScriptRoot/../Config.psd1"
    $pollInterval = $config.PurgeActionPollIntervalSeconds
    $appearTimeout = [TimeSpan]::FromMinutes($config.ActionAppearanceTimeoutMinutes)
    $pollTimeout = [TimeSpan]::FromMinutes($config.PurgeCompletionTimeoutMinutes)

    Write-PhishIRLog -Level Info -Message "Starting purge action" -Properties @{
        SearchName = $SearchName
        PurgeType = $PurgeType
    }

    Write-PhishIRAuditLog -Action 'PurgeStarted' -Details @{
        SearchName = $SearchName
        PurgeType = $PurgeType
    }

    New-ComplianceSearchAction -SearchName $SearchName -Purge -PurgeType $PurgeType -Confirm:$false | Out-Null

    $actionName = "${SearchName}_Purge"

    # Wait for action to appear
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $act = $null
    do {
        Start-Sleep $pollInterval
        $act = Get-ComplianceSearchAction -Identity $actionName -ErrorAction SilentlyContinue
        if (-not $act) {
            $act = Get-ComplianceSearchAction | Where-Object { $_.Name -eq $actionName } | Select-Object -First 1
        }
    } while (-not $act -and $sw.Elapsed -lt $appearTimeout)

    if (-not $act) {
        Write-PhishIRLog -Level Error -Message "Purge action not found" -Properties @{
            ActionName = $actionName
            TimeoutMinutes = $config.ActionAppearanceTimeoutMinutes
        }
        throw "Purge action '$actionName' not found after waiting $($config.ActionAppearanceTimeoutMinutes) minutes."
    }

    # Poll for completion
    $sw.Restart()
    do {
        Start-Sleep $pollInterval
        $act = Get-ComplianceSearchAction -Identity $actionName -ErrorAction SilentlyContinue
        if (-not $act) {
            $act = Get-ComplianceSearchAction | Where-Object { $_.Name -eq $actionName } | Select-Object -First 1
        }

        $itemsPurged = if ($act.PSObject.Properties.Match('ItemsPurged').Count -gt 0) {
            $act.ItemsPurged
        } else {
            $null
        }
        $itemsPurgedDisp = if ($null -ne $itemsPurged) { $itemsPurged } else { 'n/a' }

        Write-Info ("Purge Status: {0} ItemsPurged: {1} Progress: {2}" -f $act.Status, $itemsPurgedDisp, $act.Progress)
    } while ($act -and $act.Status -notin @('Completed', 'Failed') -and $sw.Elapsed -lt $pollTimeout)

    if (-not $act) {
        Write-PhishIRLog -Level Error -Message "Purge action disappeared" -Properties @{
            ActionName = $actionName
        }
        throw "Purge action '$actionName' disappeared while polling."
    }

    if ($act.Status -ne 'Completed') {
        Write-PhishIRLog -Level Error -Message "Purge action failed" -Properties @{
            ActionName = $actionName
            Status = $act.Status
        }
        throw "Purge did not complete successfully. Status: $($act.Status)"
    }

    $finalItemsPurged = if ($act.PSObject.Properties.Match('ItemsPurged').Count -gt 0) {
        $act.ItemsPurged
    } else {
        0
    }

    Write-PhishIRAuditLog -Action 'PurgeCompleted' -Details @{
        SearchName = $SearchName
        PurgeType = $PurgeType
        ItemsPurged = $finalItemsPurged
        Status = $act.Status
    }

    Write-PhishIRLog -Level Info -Message "Purge completed successfully" -Properties @{
        ActionName = $actionName
        ItemsPurged = $finalItemsPurged
        Status = $act.Status
    }

    return $act
}

function Export-PurgeResults {
    <#
    .SYNOPSIS
        Export purge action results to CSV and JSON

    .DESCRIPTION
        Generates final reports for completed purge operations

    .OUTPUTS
        Returns hashtable with report paths
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$PurgeAction,

        [Parameter(Mandatory)]
        [object]$ComplianceSearch,

        [Parameter(Mandatory)]
        [string]$OutputDir,

        [Parameter(Mandatory)]
        [string]$ContentMatchQuery,

        [Parameter(Mandatory)]
        [datetime]$StartUtc,

        [Parameter(Mandatory)]
        [datetime]$EndUtc,

        [Parameter(Mandatory)]
        [string[]]$Mailboxes,

        [Parameter(Mandatory)]
        [string]$PurgeType,

        [Parameter(Mandatory)]
        [object[]]$PerMailboxResults,

        [Parameter(Mandatory)]
        [datetime]$ScriptStart
    )

    $config = Import-PowerShellDataFile -Path "$PSScriptRoot/../Config.psd1"
    $scriptEnd = Get-Date

    $ts = Get-Date -Format $config.ReportDateFormat
    $reportCsv = Join-Path $OutputDir ("ContentPurge-$ts.csv")
    $reportJson = Join-Path $OutputDir ("ContentPurge-$ts.json")

    $finalItemsPurged = if ($PurgeAction.PSObject.Properties.Match('ItemsPurged').Count -gt 0) {
        $PurgeAction.ItemsPurged
    } else {
        0
    }

    $foundCount = if ($null -ne $ComplianceSearch.Items) {
        $ComplianceSearch.Items
    } elseif ($null -ne $ComplianceSearch.ItemsCount) {
        $ComplianceSearch.ItemsCount
    } else {
        0
    }

    # Build per-mailbox counts string
    $perCounts = $null
    if ($PerMailboxResults -and $PerMailboxResults.Count -gt 0) {
        $pairs = foreach ($p in $PerMailboxResults) {
            if ($p.Mailbox) {
                "{0}={1}" -f $p.Mailbox, (if ($null -ne $p.ItemCount) { $p.ItemCount } else { 0 })
            }
        }
        if ($pairs) {
            $perCounts = ($pairs -join '; ')
        }
    }

    $actionId = if ($PurgeAction.PSObject.Properties.Match('Identity').Count -gt 0 -and $PurgeAction.Identity) {
        $PurgeAction.Identity
    } elseif ($PurgeAction.PSObject.Properties.Match('Id').Count -gt 0) {
        $PurgeAction.Id
    } else {
        $null
    }

    $obj = [PSCustomObject]@{
        TimestampUTC = $scriptEnd.ToUniversalTime()
        SearchName = $ComplianceSearch.Name
        ContentMatchQuery = $ContentMatchQuery
        StartUtc = $StartUtc
        EndUtc = $EndUtc
        Mailboxes = ($Mailboxes -join '; ')
        ItemsFound = $foundCount
        SearchStatus = $ComplianceSearch.Status
        PurgeStatus = $PurgeAction.Status
        ItemsPurged = $finalItemsPurged
        Progress = $PurgeAction.Progress
        RequestedPurgeType = $PurgeType
        ActionId = $actionId
        PerMailboxCounts = $perCounts
        PerMailboxSummary = $PerMailboxResults
        DurationSeconds = [int]($scriptEnd - $ScriptStart).TotalSeconds
    }

    $obj | Export-Csv -Path $reportCsv -NoTypeInformation -Encoding UTF8
    $obj | ConvertTo-Json -Depth $config.ReportJsonDepth | Set-Content -Path $reportJson -Encoding UTF8

    Write-Success ("Purge ($PurgeType) completed. ItemsPurged: $finalItemsPurged")
    Write-Success ("Report saved to: `nCSV: $reportCsv`nJSON: $reportJson")

    Write-PhishIRLog -Level Info -Message "Purge results exported" -Properties @{
        ReportCsv = $reportCsv
        ReportJson = $reportJson
        ItemsPurged = $finalItemsPurged
        DurationSeconds = [int]($scriptEnd - $ScriptStart).TotalSeconds
    }

    return @{
        ReportCsv = $reportCsv
        ReportJson = $reportJson
        ItemsPurged = $finalItemsPurged
    }
}
