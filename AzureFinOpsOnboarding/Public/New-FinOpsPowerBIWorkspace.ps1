function New-FinOpsPowerBIWorkspace {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$WorkspaceName,
        [string]$AdminPrincipalId,
        [Parameter(Mandatory)][string]$TemplateSharePointUrl,
        [string]$TemplateCachePath = "$env:TEMP\FinOpsOnboarding\PBIXCache",
        [switch]$PassThru
    )

    begin {
        if (-not (Test-Path $TemplateCachePath)) {
            New-Item -ItemType Directory -Path $TemplateCachePath -Force | Out-Null
        }
    }

    process {
        if (-not (Get-Module -ListAvailable -Name MicrosoftPowerBIMgmt)) {
            Install-Module -Name MicrosoftPowerBIMgmt -Scope CurrentUser -Force -ErrorAction Stop
        }
        Import-Module MicrosoftPowerBIMgmt -ErrorAction Stop

        $token = $null
        try {
            $token = Get-PowerBIAccessToken -AsString -ErrorAction Stop
        }
        catch { }
        
        if (-not $token) {
            Connect-PowerBIServiceAccount -ErrorAction Stop | Out-Null
        }

        Write-Host "Creating workspace '$WorkspaceName'..." -ForegroundColor Cyan
        $workspaceId = $null
        
        if ($PSCmdlet.ShouldProcess($WorkspaceName, "Create Power BI workspace")) {
            $createBody = @{ name = $WorkspaceName } | ConvertTo-Json
            $response = Invoke-PowerBIRestMethod -Url "groups" -Method Post -Body $createBody -ContentType 'application/json' -ErrorAction Stop
            $workspace = $response | ConvertFrom-Json
            $workspaceId = $workspace.id
            Write-Host "Workspace created: $workspaceId" -ForegroundColor Green
        }

        $adminAssigned = $false
        if ($AdminPrincipalId) {
            try {
                $addUserBody = @{ identifier = $AdminPrincipalId; groupUserAccessRight = 'Admin'; principalType = 'User' } | ConvertTo-Json
                Invoke-PowerBIRestMethod -Url "groups/$workspaceId/users" -Method Post -Body $addUserBody -ContentType 'application/json' -ErrorAction Stop | Out-Null
                $adminAssigned = $true
                Write-Host "Admin assigned" -ForegroundColor Green
            }
            catch {
                Write-Warning "Failed to assign admin: $_"
            }
        }

        $templateFileName = [System.IO.Path]::GetFileName($TemplateSharePointUrl)
        $cachedFilePath = Join-Path $TemplateCachePath $templateFileName
        try {
            Invoke-WebRequest -Uri $TemplateSharePointUrl -OutFile $cachedFilePath -UseDefaultCredentials -ErrorAction Stop
            Write-Host "Template downloaded: $cachedFilePath" -ForegroundColor Green
        }
        catch {
            throw "Failed to download PBIX: $_"
        }

        $templatePublished = $false
        $reportId = $null
        $reportName = $null
        
        try {
            $result = [PSCustomObject]@{
                WorkspaceId        = $workspaceId
                WorkspaceName      = $WorkspaceName
                ReportId           = $reportId
                ReportName         = $reportName
                AdminAssigned      = $adminAssigned
                TemplatePublished  = $templatePublished
                CachedTemplatePath = $cachedFilePath
                CreatedAt          = Get-Date
            }
        }
        catch {
            Write-Warning "Error: $_"
        }

        if ($PassThru) {
            return $result
        }
        $result
    }
}
