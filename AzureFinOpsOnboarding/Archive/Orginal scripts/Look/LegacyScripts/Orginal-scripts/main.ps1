function Request-BearerToken{
    param(
        [Parameter(Mandatory=$true)]
        [string]$Client_id,
        
        [Parameter(Mandatory=$true)]
        [string]$Tenant_id,
        
        [Parameter(Mandatory=$true)]
        [string]$Client_secret
    )

            <#
        .SYNOPSIS
        Fetch azure token

        .DESCRIPTION
        Calls API for Azure Managemnent to fetch a auth token used in API calls

        .PARAMETER Client_id
        Client / application id of the app registration in entra

        .PARAMETER Tenant_id
        ID of the customer tenant

        .PARAMETER Client_secret
        Secret key from application used to auth to endpoint

        .INPUTS
        None. You can't pipe objects to Show-Error.

        .OUTPUTS
        String that is Bearer JWT token used in Oauth 2.0 api calls

        .EXAMPLE
        PS> Request-BearerToken -Client_id "8949a6ab-..." -Tenant_id "8c44204a-53c..." -Client_secret "supersecuresecret"
    #>

    $LoginURI = "https://login.microsoftonline.com/$Tenant_id/oauth2/v2.0/token"
    $body = @{
        'scope' = 'https://management.azure.com/.default'
        'client_id' = $Client_id
        'client_secret' = $Client_secret
        'grant_type' = 'client_credentials'
    }
    try {
        $token = Invoke-RestMethod -Uri $LoginURI -Body $body -Method Post -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
        $bearerToken = $token | select -ExpandProperty access_token
        return [string]$bearerToken
    }
    catch {
        Throw "Failed to authnticate to customer tenant please confirm that applicationid, tenantid and secret are all correct " + $_
    }

}

function Test-SubscriptionReader{
    param(
        [Parameter(Mandatory=$true)]
        [string]$bearerToken
    )

        <#
    .SYNOPSIS
    Test if the application has reader access to Azure subscriptions.

    .DESCRIPTION
    This function checks if the application has the necessary permissions to read Azure subscriptions using the provided bearer token.

    .PARAMETER bearerToken
    The OAuth 2.0 bearer token used for authentication.

    .INPUTS
    None. You can't pipe objects to Test-SubscriptionReader.

    .OUTPUTS
    Returns the list of subscriptions if the application has reader access.

    .EXAMPLE
    PS> Test-SubscriptionReader -bearerToken "eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiIsIng1dCI6I..."
    #>

    $ApiUri = "https://management.azure.com/subscriptions?api-version=2022-12-01"
    $Headers = @{
        'Content-Type'  = "application/json"
        'Authorization' = "Bearer $bearerToken"
    }
    try {
        $subscriptions = Invoke-RestMethod -Uri $ApiUri -Headers $Headers -Method Get
    }
    catch {
        Throw "Failed to authenticate to Azure services to fetch subscriptions please confirm that customer has provided reader to atleast one subscription " + $_
    }
    

    if($subscriptions.count.value -eq 0){
        Throw "Failed to authenticate to Azure services to fetch subscriptions please confirm that customer has provided reader to atleast one subscription"
    }
    return $subscriptions.value
    
}

function Test-EEAMCABillingAccounts{
    param(
        [Parameter(Mandatory=$true)]
        [string]$bearerToken
    )

        <#
    .SYNOPSIS
    Test if the application has access to billing accounts for EA (Enterprise Agreement) or MCA (Microsoft Customer Agreement).

    .DESCRIPTION
    This function checks if the application has the necessary permissions to read billing accounts using the provided bearer token.

    .PARAMETER bearerToken
    The OAuth 2.0 bearer token used for authentication.

    .INPUTS
    None. You can't pipe objects to Test-EEAMCABillingAccounts.

    .OUTPUTS
    Returns the list of billing accounts if the application has access.

    .EXAMPLE
    PS> Test-EEAMCABillingAccounts -bearerToken "eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiIsIng1dCI6I..."
    #>


    $ApiUri = "https://management.azure.com/providers/Microsoft.Billing/billingAccounts?api-version=2019-10-01-preview"
    $Headers = @{
        'Content-Type'  = "application/json"
        'Authorization' = "Bearer $bearerToken"
    }
    try {
        $billingAcccounts = Invoke-RestMethod -Uri $ApiUri -Headers $Headers -Method Get
    }
    catch {
        Throw "Failed to authenticate to Azure services to fetch billingaccounts please confirm that customer has an EA (enterprise agreement) or has provided the application permission Enrollment Reader " + $_
    }
    

    if($billingAcccounts.count.value -eq 0){
        Throw "Failed to authenticate to Azure services to fetch billingaccounts please confirm that customer has an EA (enterprise agreement) or has provided the application permission Enrollment Reader"
    }
    return $billingAcccounts.value
    
}

function Test-FetchCosts {
    param(
        [Parameter(Mandatory=$true)]
        [string]$bearerToken,

        [Parameter(Mandatory=$true)]
        [string]$subscriptionID,

        [Parameter(Mandatory=$true)]
        [string]$startdate,

        [Parameter(Mandatory=$true)]
        [string]$enddate
    )

        <#
    .SYNOPSIS
    Fetch cost data for a specific subscription within a given date range.

    .DESCRIPTION
    This function retrieves cost data for a specified Azure subscription within a given date range using the provided bearer token.

    .PARAMETER bearerToken
    The OAuth 2.0 bearer token used for authentication.

    .PARAMETER subscriptionID
    The ID of the Azure subscription for which to fetch cost data.

    .PARAMETER startdate
    The start date for the cost data retrieval in 'yyyy-MM-dd' format.

    .PARAMETER enddate
    The end date for the cost data retrieval in 'yyyy-MM-dd' format.

    .INPUTS
    None. You can't pipe objects to Test-FetchCosts.

    .OUTPUTS
    Returns the cost data for the specified subscription and date range.

    .EXAMPLE
    PS> Test-FetchCosts -bearerToken "eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiIsIng1dCI6I..." -subscriptionID "12345678-1234-1234-1234-123456789012" -startdate "2023-01-01" -enddate "2023-01-31"
    #>

    $ApiUri = "https://management.azure.com/subscriptions/$subscriptionID/providers/Microsoft.Consumption/usageDetails?"+'$filter'+"=properties/usageStart ge '"+$startdate+" and properties/usageEnd le '$enddate'&api-version=2024-08-01&"+'$top=5'

    $Headers = @{
        'Content-Type'  = "application/json"
        'Authorization' = "Bearer $bearerToken"
    }
    try {
        $billingData = Invoke-RestMethod -Uri $ApiUri -Headers $Headers -Method Get
    }
    catch {
        Throw "Failed to authenticate to Azure services to fetch billing data please confirm application has permission Billing Reader" + $_
    }
    

    if($billingData.count.value -eq 0){
        Throw "Failed to authenticate to Azure services to fetch billing data please confirm application has permission Billing Reader"
    }
}

function Test-ReservationReader {
    param(
        [Parameter(Mandatory=$true)]
        [string]$bearerToken
    )

    $ApiUri = 'https://management.azure.com/providers/Microsoft.Capacity/reservations?api-version=2022-11-01&$take=1'
    $Headers = @{
        'Content-Type'  = "application/json"
        'Authorization' = "Bearer $bearerToken"
    }

    try {
        $billingData = Invoke-RestMethod -Uri $ApiUri -Headers $Headers -Method Get
    }
    catch {
        Throw "Failed to authenticate to Azure services to fetch reservation data please confirm application has permission Reservation Reader " + $_
    }

    if($billingData.Value.count -eq 0){
        throw "Failed to Fetch Rservation from Azure please confirm application has permission Reservation Reader "
    }
}

function Test-EmissionsReader {
    param(
        [Parameter(Mandatory=$true)]
        [string]$bearerToken,
        [Parameter(Mandatory=$true)]
        [string]$subscriptionId
    )

    $ApiUri = "https://management.azure.com/providers/Microsoft.Carbon/carbonEmissionReports?api-version=2023-04-01-preview"
    
    $Headers = @{
        'Content-Type'  = "application/json"
        'Authorization' = "Bearer $bearerToken"
    }

    $startDate = (get-date).AddDays(-90).ToString("yyyy-MM-01")
    $endDate = (get-date).AddDays(-60).ToString("yyyy-MM-01")
    
    $body = @{
        "reportType" = "OverallSummaryReport"
        "subscriptionList" = @("$subscriptionId")
        "carbonScopeList" = @("Scope1")
        "dateRange" = @{
            	"start" = $startDate
		        "end" =  $endDate
        }
    }


    try {
        $data = Invoke-RestMethod -Uri $ApiUri -Headers $Headers -Method Post -Body ($body | ConvertTo-Json)
        return
    }
    catch {
        Throw "Failed to fetch to Azure emissions data from API endpoint. Please confirm that user has Carbon Optimization Reader permission" + $_
    }
}

function Start-Fetch{
    param(
        [Parameter(Mandatory=$true)]
        [string]$Client_id,

        [Parameter(Mandatory=$true)]
        [string]$customerName,

        [Parameter(Mandatory=$true)]
        [string]$Tenant_id,
        
        [Parameter(Mandatory=$true)]
        [string]$PrimaryDomain,

        [Parameter(Mandatory=$true)]
        [string]$Client_secret,

        [switch]$IsEA,

        [switch]$HasNoReservations
    )
    
        <#
    .SYNOPSIS
    Fetch and confirm all necessary data for a customer.

    .DESCRIPTION
    This function fetches and confirms all necessary data for a customer, including subscriptions, billing accounts, and cost data.

    .PARAMETER Client_id
    The client ID of the application registration in Azure AD.

    .PARAMETER customerName
    The name of the customer.

    .PARAMETER Tenant_id
    The ID of the customer tenant.

    .PARAMETER PrimaryDomain
    The primary domain of the customer.

    .PARAMETER IsEA
    A boolean indicating if the customer has an Enterprise Agreement (EA).

    .PARAMETER Client_secret
    The client secret of the application registration in Azure AD.

    .INPUTS
    None. You can't pipe objects to Start-Fetch.

    .OUTPUTS
    None. This function generates a JSON file with the fetched data.

    .EXAMPLE
    PS> Start-Fetch -Client_id "8949a6ab-..." -customerName "Contoso" -Tenant_id "8c44204a-53c..." -PrimaryDomain "contoso.com" -IsEA $true -Client_secret "supersecuresecret"
    #>

    try {
        $token = Request-BearerToken -Client_id $Client_id -Tenant_id $Tenant_id -Client_secret $Client_secret
        $CustomerNameNoWhiteSpace = ($customerName -replace "\W" )
        $subs = Test-SubscriptionReader -bearerToken $token
        $IsEAINT = 0
        
        $startDate = (get-date).AddDays(-60).ToString("yyyy-MM-01")
        $endDate = (get-date).AddDays(-30).ToString("yyyy-MM-01")
        #Test-FetchCosts -bearerToken $token -subscriptionID $subs[0].subscriptionId -enddate $endDate -startdate $startDate
        if(-not ($HasNoReservations)){Test-ReservationReader -bearerToken $token}
        #Test-EmissionsReader -bearerToken $token -subscriptionId $subs[0].subscriptionId
        $enrollmentID = "0"
        $mcabillingid = "0"
        if($IsEA){
            $IsEAINT = 1        
            $eaid = Test-EEAMCABillingAccounts -bearerToken $token | select -ExpandProperty name
            if(-not $eaid){
                Write-Host "Unable to fetch billing account id, please make sure that you have permission to manage the EA/MCA Billing accounts"
                Read-Host "Press enter to exit:"
                exit
            }
            if($eaid -like "*:*"){$mcabillingid = $eaid} else {$enrollmentID = $eaid}
        }     
            $JSONPayload = @{
                "CustomerName" = $customerName
                "PrimaryDomain"= $PrimaryDomain
                "IsEA" = $IsEAINT
                "TenantID" = $Tenant_id
                "ApplicationId" = $Client_id
                "EnrollementId" = $enrollmentID
                "MCABillingId" = $mcabillingid
                "HasSameEnrollmentIdAsParent" = $false
                "SecretName" = $CustomerNameNoWhiteSpace+"ACCSecret"
                "SecretExpiryDateKey" = (([int](get-date).ToString('yyyyMMdd'))+20000)
            }
        $JSONPayload = "["+($JSONPayload | ConvertTo-Json)+"]"
        $JSONPayload | Out-File ".\$CustomerNameNoWhiteSpace.json"
        return
    }
    catch {
        Write-Host $_
        Read-Host "Press Enter to exit"
        return
    }

}

Show-command Start-Fetch -PassThru | Invoke-Expression