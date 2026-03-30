
param ( `
[Parameter(Mandatory=$true)][bool]$skipSubscriptions, `
[Parameter(Mandatory=$true)][string]$jira, `
[Parameter(Mandatory=$true)][guid]$tenantid, `
[Parameter(Mandatory=$true)][guid]$clientid, `
[Parameter(Mandatory=$true)][string]$clientsecret
)

$logFile = "C:\Users\thohalld\OneDrive - Crayon Group\Vinnuskjöl\Crayon\FinOps\AzureCC-Onboarding-script\{2:yyyyMMdd.HHmmss}.log" -f $env:USERPROFILE, $jira, (Get-Date)

########### GET BEARER TOKEN

# Define the API endpoint
# Define the request body as a hashtable
$body = @{
    grant_type    = "client_credentials"
    client_id     = $clientid
    client_secret = $clientsecret
    scope         = "https://management.azure.com/.default"
}

# Convert the body to a URL-encoded string
$bodyEncoded = ($body.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "&"

# Set headers
$headers = @{
    "Content-Type" = "application/x-www-form-urlencoded"
}

# Set uri
$uri = "https://login.microsoftonline.com/{0}/oauth2/v2.0/token" -f $tenantid

# Send the POST request
$response = Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $bodyEncoded

if( $? )
{
    ########### GET SUBSCRIPTIONS

    #--- Gather all EA subscriptions
    $eaSubscriptionValues = @()

    $body = @{
        token_type    = "Bearer"
        expires_in     = 3599
        ext_expires_in = 3599
    }
    # Convert the body to a URL-encoded string
    $bodyEncoded = ($body.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "&"

    $auth = "Bearer {0}" -f $response.access_token
    $headers = @{
        "Authorization" = $auth
        "Content-Type"  = "application/json"
    }

    $uriSubscriptions = "https://management.azure.com/subscriptions?api-version=2022-12-01"

    # Send the GET request
    $subscriptions = Invoke-RestMethod -Uri $uriSubscriptions -Method GET -Headers $headers

    $isEnterprise = $false
    $startDate = (Get-Date).AddDays(-60).ToString("yyyy-MM-01")
    $endDate = (Get-Date).AddDays(-30).ToString("yyyy-MM-01")

    if( $skipSubscriptions -ne $false )
    {
        foreach( $subscriptionValues in $subscriptions.value )
        {
            # Check each subscription
            foreach( $subscriptionValuePolicy in , $subscriptionValues.subscriptionpolicies)
            {
                $billingAccess ="Not checked"

                switch -Wildcard ( $subscriptionValues.subscriptionpolicies )
                {
                    "*Enterprise*" { $typeSubscription = "EA" }
                    "*CSP*" { $typeSubscription = "CSP" }
                    "*Account*" { $typeSubscription = "MCA" }
                    default { $typeSubscription = "" }
                }

                ### Check access to last month subscription cost 
                $ApiUri = "https://management.azure.com/subscriptions/{0}/providers/Microsoft.Consumption/usageDetails?'`$filter'=properties/usageStart ge '{1}' and properties/usageEnd le '{2}'&api-version=2024-08-01&'`$top=5'" -f $subscriptionValues.subscriptionID, $startdate, $enddate
                try {
                    $billingData = Invoke-RestMethod -Uri $ApiUri -Headers $Headers -Method GET
                    if( -not $? -or $null -eq $billingData ) {
                        $billingAccess ="Data error"
                    }
                    else {
                        if( $null -eq $billingData.value.count )
                        {
                            $billingAccess ="Data empty"
                        }
                        elseif( $billingData.value.count -eq 0 )
                        {
                            $billingAccess ="No data records"
                        }
                        else {
                            $billingAccess ="Data detected"
                        }
                    }
                } catch {
                    $billingAccess ="Data error"
                    if ($_ -like "*429*") {
                        "{0:yyyy-MM-dd HH:mm:ss} Sleeping for 30 seconds to resolve throttling ..." -f (Get-Date)
                        Start-Sleep -Seconds 30
                        Retry
                    }
                }
                "{0, 5} - Subscription: {1}  QuotaID: {2}  Billing (30-60d): {3}" -f $typeSubscription, $subscriptionValues.displayName, $subscriptionValuePolicy.quotaId, $billingAccess
                "{0, 5} - Subscription: {1}  QuotaID: {2}  Billing (30-60d): {3}" -f $typeSubscription, $subscriptionValues.displayName, $subscriptionValuePolicy.quotaId, $billingAccess | Out-File -Append -FilePath $logFile -Width 500

                #--- Merkja við hvort þetta sé Enterprise subscription eða ekki
                if( -not $isEnterprise -and $typeSubscription -eq "EA" )
                {
                    $isEnterprise = $true
                    $eaSubscriptionValues += $subscriptionValues
                }
    #            Start-Sleep -Seconds 30 #--- Sleep for 30 seconds to avoid throttling
            }
        }
    }    
    ########### CHECK BILLING ACCOUNTS FOR ENTERPRISE AGREEMENTS

#    if( $isEnterprise ) 
#    {
        $uriBillingAccounts = "https://management.azure.com/providers/Microsoft.Billing/billingAccounts?api-version=2019-10-01-preview"

        $billingAccounts = Invoke-RestMethod -Uri $uriBillingAccounts -Method GET -Headers $headers
        if( -not $? -or $null -eq $billingAccounts )
        {
            "No Enterprise billing account found!"
            "No Enterprise billing account found!" | Out-File -Append -FilePath $logFile -Width 500
        }    
        else 
        {
            $eaBillingAccount = $null
            foreach( $billingAccount in $billingAccounts.value )
            {
                if( ($billingAccount.properties.accountStatus -eq "Active" -or $billingAccount.properties.accountStatus -eq "Extended") -and $billingAccount.properties.accountType -eq "Enterprise" ) 
                {
                    if( $null -eq $eaBillingAccount ) {
                        $eaBillingAccount = $billingAccount
                    }
                    else {
                        "Cannot have more than one Enterprise billing account!"
                        "Cannot have more than one Enterprise billing account!" | Out-File -Append -FilePath $logFile -Width 500
                    }
                    $billMsg = "Billing Account: {0, -20}" -f $eaBillingAccount.properties.accountType
                    $billMsg += "Status: {0}  " -f $eaBillingAccount.properties.accountStatus
                    $billMsg += "Name: {0, -10}  " -f $eaBillingAccount.Name
                    $billMsg += "Agreement: {0, -20}  " -f $eaBillingAccount.properties.agreementType
                    $billMsg += "Name: {0, -30}  " -f $eaBillingAccount.properties.displayName
                    $billmsg += "Company: {0, -30}  "-f $eaBillingAccount.properties.address.companyName
                    $billmsg += "Country: {0}" -f $eaBillingAccount.properties.address.country
                    $billmsg 
                    $billmsg | Out-File -Append -FilePath $logFile -Width 500
                }
            }
        }
#    }

    ### - Check access to reservation subscription cost
    $ApiUri = 'https://management.azure.com/providers/Microsoft.Capacity/reservations?api-version=2022-11-01&$take=1'
    $billingReservationData = Invoke-RestMethod -Uri $ApiUri -Headers $Headers -Method GET
    if( -not $? -or $null -eq $billingReservationData ){
        $reservations ="No data"
    }
    else {
        if( $billingReservationData.value.count -eq 0 ) {
            $reservations ="No records"
        }
        else {
            $reservations ="{0} reservations found" -f $billingReservationData.value.count
        }
    }
    "Reservations: {0}" -f $reservations
    "Reservations: {0}" -f $reservations | Out-File -Append -FilePath $logFile -Width 500

    ### - Check access to emission subscription cost
    $ApiUri = "https://management.azure.com/providers/Microsoft.Carbon/carbonEmissionReports?api-version=2023-04-01-preview"
    $startDate = (get-date).AddDays(-90).ToString("yyyy-MM-01")
    $endDate = (get-date).AddDays(-60).ToString("yyyy-MM-01")
    $body = @{
        "reportType" = "OverallSummaryReport"
        "subscriptionList" = @($subscriptions.value.subscriptionid)
        "carbonScopeList" = @("Scope1")
        "dateRange" = @{
                "start" = $startDate
                "end" =  $endDate
        }
    }
    $emissionsData = Invoke-RestMethod -Uri $ApiUri -Headers $Headers -Method POST -Body ($body | ConvertTo-Json)
    if( -not $? -or $null -eq $emissionsData)
    {
        $emissions = "No emissions data"
    } else {
        $emissions = "Total emissions (60-90d): {0}" -f $emissionsData.value.totalcarbonemission
    }
    "{0}" -f $emissions
    "{0}" -f $emissions | Out-File -Append -FilePath $logFile -Width 500
}