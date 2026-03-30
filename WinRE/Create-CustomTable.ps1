# Create Custom Log Analytics Table for WinRE Health
param(
    [Parameter(Mandatory=$true)]
    [string]$WorkspaceResourceId
)

# Parse workspace details from resource ID
$WorkspaceResourceId -match '/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft.OperationalInsights/workspaces/([^/]+)' | Out-Null
$subscriptionId = $Matches[1]
$resourceGroupName = $Matches[2]
$workspaceName = $Matches[3]

Write-Host "`nCreating custom table in Log Analytics..." -ForegroundColor Cyan
Write-Host "Workspace: $workspaceName" -ForegroundColor Gray
Write-Host "Resource Group: $resourceGroupName" -ForegroundColor Gray

# Set subscription context
Set-AzContext -Subscription $subscriptionId | Out-Null

# Define the table schema
$tableParams = @{
    ResourceGroupName = $resourceGroupName
    WorkspaceName = $workspaceName
    TableName = "WinREHealth_CL"
    RetentionInDays = 30
    TotalRetentionInDays = 30
    Schema = @(
        @{name="TimeGenerated"; type="datetime"}
        @{name="ComputerName"; type="string"}
        @{name="Severity"; type="string"}
        @{name="WinREEnabled"; type="boolean"}
        @{name="KB5034441Vulnerable"; type="boolean"}
        @{name="ConfidenceScore"; type="int"}
        @{name="Recommendation"; type="string"}
        @{name="RecoveryPartitionSizeMB"; type="int"}
        @{name="RecoveryPartitionFreeMB"; type="int"}
        @{name="DiskType"; type="string"}
        @{name="BitLockerStatus"; type="string"}
        @{name="OSBuild"; type="string"}
        @{name="Manufacturer"; type="string"}
        @{name="Model"; type="string"}
        @{name="SerialNumber"; type="string"}
        @{name="SecureBoot"; type="boolean"}
        @{name="FirmwareType"; type="string"}
        @{name="Windows11Ready"; type="boolean"}
        @{name="ScriptExecutionTimeSeconds"; type="real"}
    )
}

# Create the custom log table using REST API
$workspaceId = (Get-AzOperationalInsightsWorkspace -ResourceGroupName $resourceGroupName -Name $workspaceName).CustomerId
$table = "WinREHealth_CL"

# Build the JSON schema
$columns = @()
$tableParams.Schema | ForEach-Object {
    $columns += @{
        name = $_.name
        type = $_.type
    }
}

$bodyobj = @{
    properties = @{
        schema = @{
            name = $table
            columns = $columns
        }
        retentionInDays = 30
        totalRetentionInDays = 30
    }
}

$body = $bodyobj | ConvertTo-Json -Depth 10

# Get access token
$token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token

# Create the table
$uri = "https://management.azure.com$WorkspaceResourceId/tables/${table}?api-version=2021-12-01-preview"

$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type" = "application/json"
}

try {
    $response = Invoke-RestMethod -Method Put -Uri $uri -Headers $headers -Body $body
    Write-Host " Custom table created successfully!" -ForegroundColor Green
    Write-Host "Table: $table" -ForegroundColor Cyan
} catch {
    if ($_.Exception.Response.StatusCode -eq 'Conflict') {
        Write-Host " Table already exists" -ForegroundColor Yellow
    } else {
        Write-Host " Error creating table: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}
