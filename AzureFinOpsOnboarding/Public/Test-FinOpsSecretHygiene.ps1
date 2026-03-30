function Test-FinOpsSecretHygiene {
    <#
    .SYNOPSIS
        Tests secret hygiene and expiration status across Azure resources.
    
    .DESCRIPTION
        Validates secret and credential expiration for:
        - Azure Key Vault secrets
        - Service principal client secrets (via Microsoft Graph API)
        - SQL connection string passwords (heuristic checks)
        
        Returns structured results with expiration status, days until expiry,
        and actionable recommendations. Emits warnings for secrets expiring
        within WarnThresholdDays and errors for secrets expiring within FailThresholdDays.
    
    .PARAMETER TenantId
        Azure AD tenant ID (GUID).
    
    .PARAMETER ApplicationId
        Service principal application (client) ID to check for secret expiration.
    
    .PARAMETER ClientSecret
        Service principal client secret (for authentication when checking Graph API).
    
    .PARAMETER KeyVaultName
        Azure Key Vault name to check for secret expiration.
    
    .PARAMETER ConnectionString
        SQL connection string to analyze for password-based authentication.
    
    .PARAMETER WarnThresholdDays
        Number of days until expiry to trigger a warning. Default: 30 days.
    
    .PARAMETER FailThresholdDays
        Number of days until expiry to trigger an error. Default: 7 days.
    
    .EXAMPLE
        $secret = ConvertTo-SecureString 'mySecret' -AsPlainText -Force
        Test-FinOpsSecretHygiene -TenantId $tid -ApplicationId $appId -ClientSecret $secret
    
    .EXAMPLE
        Test-FinOpsSecretHygiene -KeyVaultName "finops-kv-prod" `
            -WarnThresholdDays 45 `
            -FailThresholdDays 14
    
    .EXAMPLE
        $connStr = "Server=tcp:myserver.database.windows.net;Database=mydb;User ID=user;Password=pass;"
        Test-FinOpsSecretHygiene -ConnectionString $connStr
    
    .OUTPUTS
        PSCustomObject with secret hygiene results including status, days until expiry, and recommendations.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$TenantId,
        
        [Parameter()]
        [string]$ApplicationId,
        
        [Parameter()]
        [SecureString]$ClientSecret,
        
        [Parameter()]
        [string]$KeyVaultName,
        
        [Parameter()]
        [string]$ConnectionString,
        
        [Parameter()]
        [int]$WarnThresholdDays = 30,
        
        [Parameter()]
        [int]$FailThresholdDays = 7
    )
    
    try {
        Write-Verbose "=== Starting Secret Hygiene Check ==="
        
        $results = [PSCustomObject]@{
            Timestamp         = Get-Date
            OverallStatus     = 'Unknown'
            Secrets           = @()
            Warnings          = @()
            Errors            = @()
            Recommendations   = @()
        }
        
        # Check Key Vault secrets if KeyVaultName provided
        if ($KeyVaultName) {
            Write-Verbose "Checking Key Vault: $KeyVaultName"
            
            try {
                # Ensure Az.KeyVault module is available
                if (-not (Get-Module -ListAvailable -Name Az.KeyVault)) {
                    Write-Warning "Az.KeyVault module not found. Installing..."
                    Install-Module -Name Az.KeyVault -Scope CurrentUser -Force -AllowClobber
                }
                Import-Module Az.KeyVault -ErrorAction Stop
                
                # Get secrets from Key Vault
                $kvSecrets = Get-AzKeyVaultSecret -VaultName $KeyVaultName -ErrorAction Stop
                
                foreach ($kvSecret in $kvSecrets) {
                    $secretDetail = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $kvSecret.Name -ErrorAction Stop
                    
                    $daysUntilExpiry = $null
                    $status = 'Unknown'
                    
                    if ($secretDetail.Expires) {
                        $daysUntilExpiry = ($secretDetail.Expires - (Get-Date)).Days
                        
                        if ($daysUntilExpiry -le $FailThresholdDays) {
                            $status = 'Critical'
                            $results.Errors += "Key Vault secret '$($kvSecret.Name)' expires in $daysUntilExpiry days (Critical threshold: $FailThresholdDays days)"
                        } elseif ($daysUntilExpiry -le $WarnThresholdDays) {
                            $status = 'Warning'
                            $results.Warnings += "Key Vault secret '$($kvSecret.Name)' expires in $daysUntilExpiry days (Warning threshold: $WarnThresholdDays days)"
                        } else {
                            $status = 'OK'
                        }
                    } else {
                        $status = 'NoExpiration'
                        $daysUntilExpiry = [int]::MaxValue
                    }
                    
                    $results.Secrets += [PSCustomObject]@{
                        Type             = 'KeyVaultSecret'
                        Name             = $kvSecret.Name
                        Location         = $KeyVaultName
                        Status           = $status
                        Expires          = $secretDetail.Expires
                        DaysUntilExpiry  = $daysUntilExpiry
                        LastRotated      = $secretDetail.Updated
                        Enabled          = $secretDetail.Enabled
                    }
                }
                
                Write-Verbose "Checked $($kvSecrets.Count) Key Vault secret(s)"
                
            } catch {
                $errorMsg = "Failed to check Key Vault secrets: $_"
                Write-Warning $errorMsg
                $results.Errors += $errorMsg
            }
        }
        
        # Check service principal secret expiration if ApplicationId provided
        if ($ApplicationId -and $TenantId -and $ClientSecret) {
            Write-Verbose "Checking service principal: $ApplicationId"
            
            try {
                # Get access token for Microsoft Graph
                $body = @{
                    client_id     = $ApplicationId
                    client_secret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ClientSecret))
                    scope         = 'https://graph.microsoft.com/.default'
                    grant_type    = 'client_credentials'
                }
                
                $tokenResponse = Invoke-RestMethod -Method Post `
                    -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
                    -Body $body `
                    -ContentType 'application/x-www-form-urlencoded' `
                    -ErrorAction Stop
                
                # Get application details from Microsoft Graph
                $headers = @{
                    Authorization = "Bearer $($tokenResponse.access_token)"
                }
                
                $appDetails = Invoke-RestMethod -Method Get `
                    -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=appId eq '$ApplicationId'" `
                    -Headers $headers `
                    -ErrorAction Stop
                
                if ($appDetails.value -and $appDetails.value.Count -gt 0) {
                    $app = $appDetails.value[0]
                    
                    # Check password credentials (client secrets)
                    foreach ($credential in $app.passwordCredentials) {
                        $daysUntilExpiry = $null
                        $status = 'Unknown'
                        
                        if ($credential.endDateTime) {
                            $expiryDate = [DateTime]::Parse($credential.endDateTime)
                            $daysUntilExpiry = ($expiryDate - (Get-Date)).Days
                            
                            if ($daysUntilExpiry -le $FailThresholdDays) {
                                $status = 'Critical'
                                $results.Errors += "Service principal secret '$($credential.displayName)' expires in $daysUntilExpiry days (Critical threshold: $FailThresholdDays days)"
                            } elseif ($daysUntilExpiry -le $WarnThresholdDays) {
                                $status = 'Warning'
                                $results.Warnings += "Service principal secret '$($credential.displayName)' expires in $daysUntilExpiry days (Warning threshold: $WarnThresholdDays days)"
                            } else {
                                $status = 'OK'
                            }
                        }
                        
                        $results.Secrets += [PSCustomObject]@{
                            Type            = 'ServicePrincipalSecret'
                            Name            = if ($credential.displayName) { $credential.displayName } else { 'Unnamed' }
                            Location        = $ApplicationId
                            Status          = $status
                            Expires         = if ($credential.endDateTime) { [DateTime]::Parse($credential.endDateTime) } else { $null }
                            DaysUntilExpiry = $daysUntilExpiry
                            LastRotated     = if ($credential.startDateTime) { [DateTime]::Parse($credential.startDateTime) } else { $null }
                            KeyId           = $credential.keyId
                        }
                    }
                    
                    Write-Verbose "Checked $($app.passwordCredentials.Count) service principal secret(s)"
                }
                
            } catch {
                $errorMsg = "Failed to check service principal secrets: $_"
                Write-Warning $errorMsg
                $results.Errors += $errorMsg
            }
        }
        
        # Check SQL connection string if provided
        if ($ConnectionString) {
            Write-Verbose "Analyzing SQL connection string for password-based authentication"
            
            try {
                # Check if connection string uses password authentication
                if ($ConnectionString -match 'Password\s*=') {
                    $results.Warnings += "SQL connection string uses password-based authentication. Consider migrating to Managed Identity or Azure AD authentication."
                    
                    $results.Secrets += [PSCustomObject]@{
                        Type            = 'SQLConnectionString'
                        Name            = 'SQL Password'
                        Location        = 'Connection String'
                        Status          = 'Warning'
                        Expires         = $null
                        DaysUntilExpiry = $null
                        LastRotated     = $null
                        Notes           = 'Password-based authentication detected. Rotation date unknown.'
                    }
                } else {
                    Write-Verbose "SQL connection string does not use password authentication"
                }
                
            } catch {
                $errorMsg = "Failed to analyze SQL connection string: $_"
                Write-Warning $errorMsg
                $results.Errors += $errorMsg
            }
        }
        
        # Determine overall status
        if ($results.Errors.Count -gt 0) {
            $results.OverallStatus = 'Critical'
        } elseif ($results.Warnings.Count -gt 0) {
            $results.OverallStatus = 'Warning'
        } elseif ($results.Secrets.Count -gt 0) {
            $results.OverallStatus = 'OK'
        } else {
            $results.OverallStatus = 'NoSecretsChecked'
        }
        
        # Generate recommendations
        $criticalSecrets = $results.Secrets | Where-Object { $_.Status -eq 'Critical' }
        $warningSecrets = $results.Secrets | Where-Object { $_.Status -eq 'Warning' }
        
        if ($criticalSecrets.Count -gt 0) {
            $results.Recommendations += "URGENT: Rotate $($criticalSecrets.Count) secret(s) immediately (expiring within $FailThresholdDays days)"
        }
        
        if ($warningSecrets.Count -gt 0) {
            $results.Recommendations += "Plan rotation for $($warningSecrets.Count) secret(s) soon (expiring within $WarnThresholdDays days)"
        }
        
        $noExpirationSecrets = $results.Secrets | Where-Object { $_.Status -eq 'NoExpiration' }
        if ($noExpirationSecrets.Count -gt 0) {
            $results.Recommendations += "Set expiration dates for $($noExpirationSecrets.Count) secret(s) without expiry"
        }
        
        $passwordAuthSecrets = $results.Secrets | Where-Object { $_.Type -eq 'SQLConnectionString' }
        if ($passwordAuthSecrets.Count -gt 0) {
            $results.Recommendations += "Migrate SQL authentication from passwords to Managed Identity or Azure AD"
        }
        
        # Emit warnings and errors to console
        foreach ($warning in $results.Warnings) {
            Write-Warning $warning
        }
        
        foreach ($error in $results.Errors) {
            Write-Error $error -ErrorAction Continue
        }
        
        # Display summary
        Write-Host "`n=== Secret Hygiene Check Complete ===" -ForegroundColor $(if($results.OverallStatus -eq 'Critical'){'Red'}elseif($results.OverallStatus -eq 'Warning'){'Yellow'}else{'Green'})
        Write-Host "Overall Status: " -NoNewline
        Write-Host $results.OverallStatus -ForegroundColor $(if($results.OverallStatus -eq 'Critical'){'Red'}elseif($results.OverallStatus -eq 'Warning'){'Yellow'}else{'Green'})
        Write-Host "Secrets Checked: " -NoNewline
        Write-Host $results.Secrets.Count -ForegroundColor Cyan
        Write-Host "Critical: " -NoNewline
        Write-Host ($results.Secrets | Where-Object { $_.Status -eq 'Critical' }).Count -ForegroundColor Red
        Write-Host "Warning: " -NoNewline
        Write-Host ($results.Secrets | Where-Object { $_.Status -eq 'Warning' }).Count -ForegroundColor Yellow
        Write-Host "OK: " -NoNewline
        Write-Host ($results.Secrets | Where-Object { $_.Status -eq 'OK' }).Count -ForegroundColor Green
        
        if ($results.Recommendations.Count -gt 0) {
            Write-Host "`nRecommendations:" -ForegroundColor Cyan
            foreach ($recommendation in $results.Recommendations) {
                Write-Host "  - $recommendation" -ForegroundColor Gray
            }
        }
        
        return $results
        
    } catch {
        Write-Error "Failed to check secret hygiene: $_"
        throw
    }
}
