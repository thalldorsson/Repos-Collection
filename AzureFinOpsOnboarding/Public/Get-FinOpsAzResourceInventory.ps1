function Get-FinOpsAzResourceInventory {
    <#
    .SYNOPSIS
        Query Azure Resource Graph for resource inventory across subscriptions.
    
    .DESCRIPTION
        Uses Azure Resource Graph to query resources across multiple subscriptions,
        providing a comprehensive inventory of Azure resources for FinOps analysis.
        Requires the Az.ResourceGraph module to be installed.
    
    .PARAMETER SubscriptionIds
        Array of subscription IDs to query. If not specified, queries all accessible subscriptions.
    
    .PARAMETER Token
        Bearer token for Azure API authentication.
    
    .PARAMETER Query
        Custom KQL (Kusto Query Language) query. If not specified, uses a default inventory query.
    
    .PARAMETER Top
        Maximum number of results to return. Default is 1000.
    
    .EXAMPLE
        $token = Get-FinOpsBearerToken -TenantId $tid -ApplicationId $aid -ClientSecret $secret
        $inventory = Get-FinOpsAzResourceInventory -SubscriptionIds @('sub1', 'sub2') -Token $token
    
    .EXAMPLE
        # Custom query for specific resource types
        $query = "Resources | where type in~ ('microsoft.compute/virtualmachines', 'microsoft.storage/storageaccounts') | project name, type, location, resourceGroup"
        Get-FinOpsAzResourceInventory -Token $token -Query $query
    
    .OUTPUTS
        PSCustomObject with query results
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$SubscriptionIds,
        
        [Parameter(Mandatory)]
        [string]$Token,
        
        [Parameter(Mandatory = $false)]
        [string]$Query,
        
        [Parameter(Mandatory = $false)]
        [int]$Top = 1000
    )
    
    Write-Verbose "Querying Azure Resource Graph for resource inventory"
    
    # Default query if none provided
    if (-not $Query) {
        $Query = @"
Resources
| summarize count() by type, location
| order by count_ desc
| project ResourceType = type, Location = location, Count = count_
"@
        Write-Verbose "Using default inventory query"
    }
    
    Write-Verbose "Query: $Query"
    
    try {
        # Build the Resource Graph API request
        $apiVersion = '2021-03-01'
        $uri = "https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=$apiVersion"
        
        $body = @{
            query = $Query
            options = @{
                '$top' = $Top
            }
        }
        
        # Add subscriptions if specified
        if ($SubscriptionIds -and $SubscriptionIds.Count -gt 0) {
            $body['subscriptions'] = $SubscriptionIds
            Write-Verbose "Querying $($SubscriptionIds.Count) subscription(s)"
        } else {
            Write-Verbose "Querying all accessible subscriptions"
        }
        
        $bodyJson = $body | ConvertTo-Json -Depth 10
        
        $headers = @{
            'Authorization' = "Bearer $Token"
            'Content-Type' = 'application/json'
        }
        
        Write-Verbose "Executing Resource Graph query..."
        
        $response = Invoke-FinOpsRestMethodWithRetry -Uri $uri -Method Post -Headers $headers -Body $bodyJson -ErrorAction Stop
        
        Write-Verbose "Query successful: $($response.count) result(s) returned"
        
        return [PSCustomObject]@{
            Success = $true
            Count = $response.count
            TotalRecords = $response.totalRecords
            Data = $response.data
            Query = $Query
            Timestamp = (Get-Date).ToUniversalTime().ToString('o')
        }
        
    } catch {
        $errorMessage = $_.Exception.Message
        Write-Error "Failed to query Resource Graph: $errorMessage"
        
        # Provide helpful guidance
        if ($errorMessage -like '*Az.ResourceGraph*') {
            Write-Warning "Consider installing Az.ResourceGraph module for enhanced functionality: Install-Module -Name Az.ResourceGraph"
        }
        
        return [PSCustomObject]@{
            Success = $false
            Error = $errorMessage
            Query = $Query
            Timestamp = (Get-Date).ToUniversalTime().ToString('o')
        }
    }
}
