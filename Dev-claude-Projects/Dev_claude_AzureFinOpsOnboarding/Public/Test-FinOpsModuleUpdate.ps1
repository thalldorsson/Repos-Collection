function Test-FinOpsModuleUpdate {
    <#
    .SYNOPSIS
        Checks if a newer version of the AzureFinOpsOnboarding module is available.
    
    .DESCRIPTION
        Compares the currently loaded module version with the latest version available
        in the PowerShell Gallery (if published) or a specified repository.
        Returns an object indicating if an update is available.
    
    .PARAMETER Repository
        The PowerShell repository to check for updates. Defaults to 'PSGallery'.
    
    .PARAMETER Quiet
        If specified, only returns $true/$false instead of detailed information.
    
    .EXAMPLE
        Test-FinOpsModuleUpdate
        Checks for module updates and displays detailed information.
    
    .EXAMPLE
        if (Test-FinOpsModuleUpdate -Quiet) {
            Write-Host "Update available! Run: Update-Module AzureFinOpsOnboarding"
        }
    
    .OUTPUTS
        PSCustomObject with properties: UpdateAvailable, CurrentVersion, LatestVersion, Repository
        Or Boolean if -Quiet is specified
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Repository = 'PSGallery',
        
        [Parameter(Mandatory = $false)]
        [switch]$Quiet
    )
    
    try {
        # Get current module version
        $currentModule = Get-Module -Name AzureFinOpsOnboarding
        if (-not $currentModule) {
            Write-Warning "AzureFinOpsOnboarding module is not currently loaded."
            return $null
        }
        
        $currentVersion = $currentModule.Version
        Write-Verbose "Current module version: $currentVersion"
        
        # Try to find the latest version in the repository
        Write-Verbose "Checking repository '$Repository' for updates..."
        
        $latestModule = Find-Module -Name AzureFinOpsOnboarding -Repository $Repository -ErrorAction SilentlyContinue
        
        if (-not $latestModule) {
            Write-Verbose "Module not found in repository '$Repository'. This may be a local/dev installation."
            
            if ($Quiet) {
                return $false
            }
            
            return [PSCustomObject]@{
                UpdateAvailable = $false
                CurrentVersion = $currentVersion.ToString()
                LatestVersion = 'N/A'
                Repository = $Repository
                Message = "Module not published to $Repository (local/development installation)"
            }
        }
        
        $latestVersion = $latestModule.Version
        Write-Verbose "Latest available version: $latestVersion"
        
        # Compare versions
        $updateAvailable = $latestVersion -gt $currentVersion
        
        if ($Quiet) {
            return $updateAvailable
        }
        
        $result = [PSCustomObject]@{
            UpdateAvailable = $updateAvailable
            CurrentVersion = $currentVersion.ToString()
            LatestVersion = $latestVersion.ToString()
            Repository = $Repository
        }
        
        if ($updateAvailable) {
            $result | Add-Member -NotePropertyName 'Message' -NotePropertyValue "Update available! Run: Update-Module -Name AzureFinOpsOnboarding"
            Write-Warning "Module update available: $currentVersion → $latestVersion"
            Write-Warning "To update, run: Update-Module -Name AzureFinOpsOnboarding"
        } else {
            $result | Add-Member -NotePropertyName 'Message' -NotePropertyValue "Module is up to date"
            Write-Verbose "Module is up to date"
        }
        
        return $result
        
    } catch {
        Write-Error "Failed to check for module updates: $_"
        
        if ($Quiet) {
            return $false
        }
        
        return $null
    }
}
