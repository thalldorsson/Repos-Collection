
#
# Import necessary modules
Import-Module ActiveDirectory
Import-Module ExchangeOnlineManagement # Install this module if not already installed


function Write-Log {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [string]$Message,

        [Parameter(Mandatory=$false)]
        [string]$LogFolder = "C:\Logs",

        [Parameter(Mandatory=$false)]
        [string]$ServerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [string]$UserName = $env:USERNAME
    )

    Begin {
        # Ensure log folder exists
        if (-not (Test-Path -Path $LogFolder)) {
            New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null
        }

        # Define log file name with date
        $logFileName = "merge-" + (Get-Date -Format "yyyy-MM-dd") + ".csv"

        # Full path for the log file
        $logFilePath = Join-Path -Path $LogFolder -ChildPath $logFileName
    }

    Process {
        # Format message with date, time, server name, and user name
        $formattedMessage = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " - Server: $ServerName - User: $UserName - $Message"

        # Add formatted message to the log file
        $formattedMessage | Out-File -FilePath $logFilePath -Append -Encoding UTF8
    }
}


######

function Connect-ActiveDirectory {
    param (
        [Parameter(Mandatory=$true)]
        [System.Management.Automation.PSCredential]$UserCredential,
        [Parameter(Mandatory=$true)]
        [string]$Server
    )

    try {
        $session = New-PSSession -ComputerName $Server -Credential $UserCredential
        Import-PSSession -Session $session -Module ActiveDirectory -AllowClobber | Out-Null
        Write-Log -Message "Connected to Active Directory on $Server" -ServerName $Server -UserName $UserCredential.UserName
    }
    catch {
        Write-Log -Message "Failed to connect to Active Directory. Error: $_" -ServerName $Server -UserName $UserCredential.UserName
    }
}


#######

function Connect-ActiveDirectory {
    param (
        [Parameter(Mandatory=$true)]
        [System.Management.Automation.PSCredential]$UserCredential
    )

    # Predefined list of Domain Controllers
    $dcList = @("DC01", "DC02", "DC03") # Replace with actual server names

    # Prompt user to select a Domain Controller
    $server = $host.ui.PromptForChoice("Select Domain Controller", "Choose a DC from the list:", $dcList, 0)

    try {
        $selectedDC = $dcList[$server]
        $session = New-PSSession -ComputerName $selectedDC -Credential $UserCredential
        Import-PSSession -Session $session -Module ActiveDirectory -AllowClobber | Out-Null
        Write-Log -Message "Connected to Active Directory on $selectedDC" -ServerName $selectedDC -UserName $UserCredential.UserName
    }
    catch {
        Write-Log -Message "Failed to connect to Active Directory. Error: $_" -ServerName $selectedDC -UserName $UserCredential.UserName
    }
}

#######

# Ensure the Active Directory module is loaded
Import-Module ActiveDirectory

# Get all domain controllers in the current domain
$domainControllers = Get-ADDomainController -Filter *

# Output the list of domain controllers
$domainControllers | ForEach-Object {
    Write-Output $_.Name
}


#######


# Specify the domain name
$domainName = "yourdomain.com"

# Get all domain controllers in the specified domain
$domainControllers = Get-ADDomainController -Filter * -Server $domainName

# Output the list of domain controllers
$domainControllers | ForEach-Object {
    Write-Output $_.Name
}

#######

# Get the current domain name
try {
    $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()
    Write-Output "Domain name: $($domain.Name)"
}
catch {
    Write-Error "Error: Unable to determine the domain name. The computer might not be part of a domain."
}

#######

# Ensure the Active Directory module is loaded
Import-Module ActiveDirectory

# Get all domain controllers in the current domain
$domainControllers = Get-ADDomainController -Filter *

# Check if there are any domain controllers found
if ($domainControllers.Count -eq 0) {
    Write-Error "No domain controllers found in the current domain."
    exit
}

# Output the list of domain controllers and ask user to select one
$index = 0
$domainControllers | ForEach-Object {
    Write-Host "[$index] $($_.Name)"
    $index++
}

# Prompt for user selection
$selectedIndex = Read-Host "Enter the number of the desired Domain Controller"
if ($selectedIndex -lt 0 -or $selectedIndex -ge $domainControllers.Count) {
    Write-Error "Invalid selection."
    #exit
}

# Get the selected domain controller
$selectedDC = $domainControllers[$selectedIndex]

# Output the selected DC name and domain
Write-Host "Selected Domain Controller: $($selectedDC.Name)"
Write-Host "Associated Domain: $($selectedDC.Domain)"

#######

