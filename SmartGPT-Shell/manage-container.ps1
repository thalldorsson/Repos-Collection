param(
    [Parameter(Position=0)]
    [ValidateSet("status", "start", "stop", "restart", "connect", "remove", "logs", "help")]
    [string]$Command = "status"
)

$ContainerName = "smartgpt-dev"

Write-Host "=== SmartGPT Shell Container Management ===" -ForegroundColor Cyan
Write-Host ""

function Show-Status {
    Write-Host "Container Status:" -ForegroundColor Yellow
    $containers = docker ps -a --filter "name=$ContainerName" --format "{{.Names}}`t{{.Status}}`t{{.Ports}}"
    if ($containers) {
        Write-Host "Name`t`tStatus`t`t`tPorts" -ForegroundColor Green
        Write-Host "----`t`t------`t`t`t-----" -ForegroundColor Green
        Write-Host $containers
    } else {
        Write-Host "  Container '$ContainerName' does not exist" -ForegroundColor Red
    }
    Write-Host ""
}

function Start-Container {
    $running = docker ps --filter "name=$ContainerName" --format "{{.Names}}"
    $exists = docker ps -a --filter "name=$ContainerName" --format "{{.Names}}"
    
    if ($running -eq $ContainerName) {
        Write-Host "Container is already running" -ForegroundColor Green
    } elseif ($exists -eq $ContainerName) {
        Write-Host "Starting stopped container..." -ForegroundColor Yellow
        docker start $ContainerName
        Write-Host "Container started successfully" -ForegroundColor Green
    } else {
        Write-Host "Container does not exist. Use '.\run-container.ps1' to create it." -ForegroundColor Red
    }
}

function Stop-Container {
    $running = docker ps --filter "name=$ContainerName" --format "{{.Names}}"
    
    if ($running -eq $ContainerName) {
        Write-Host "Stopping container..." -ForegroundColor Yellow
        docker stop $ContainerName
        Write-Host "Container stopped successfully" -ForegroundColor Green
    } else {
        Write-Host "Container is not running" -ForegroundColor Yellow
    }
}

function Remove-Container {
    $exists = docker ps -a --filter "name=$ContainerName" --format "{{.Names}}"
    
    if ($exists -eq $ContainerName) {
        # Stop first if running
        $running = docker ps --filter "name=$ContainerName" --format "{{.Names}}"
        if ($running -eq $ContainerName) {
            Write-Host "Stopping running container..." -ForegroundColor Yellow
            docker stop $ContainerName
        }
        Write-Host "Removing container..." -ForegroundColor Yellow
        docker rm $ContainerName
        Write-Host "Container removed successfully" -ForegroundColor Green
    } else {
        Write-Host "Container does not exist" -ForegroundColor Red
    }
}

function Connect-Container {
    $running = docker ps --filter "name=$ContainerName" --format "{{.Names}}"
    $exists = docker ps -a --filter "name=$ContainerName" --format "{{.Names}}"
    
    if ($running -eq $ContainerName) {
        Write-Host "Connecting to container..." -ForegroundColor Green
        docker exec -it $ContainerName bash
    } elseif ($exists -eq $ContainerName) {
        Write-Host "Container exists but is stopped. Starting..." -ForegroundColor Yellow
        docker start $ContainerName
        Write-Host "Connecting to container..." -ForegroundColor Green
        docker exec -it $ContainerName bash
    } else {
        Write-Host "Container does not exist. Use '.\run-container.ps1' to create it." -ForegroundColor Red
    }
}

function Show-Logs {
    $exists = docker ps -a --filter "name=$ContainerName" --format "{{.Names}}"
    
    if ($exists -eq $ContainerName) {
        Write-Host "Container logs (last 50 lines):" -ForegroundColor Yellow
        docker logs --tail 50 $ContainerName
    } else {
        Write-Host "Container does not exist" -ForegroundColor Red
    }
}

function Show-Help {
    Write-Host "Usage: .\manage-container.ps1 [COMMAND]" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Commands:" -ForegroundColor Yellow
    Write-Host "  status     Show container status" -ForegroundColor White
    Write-Host "  start      Start the container" -ForegroundColor White
    Write-Host "  stop       Stop the container" -ForegroundColor White
    Write-Host "  restart    Restart the container" -ForegroundColor White
    Write-Host "  connect    Connect to the container (start if needed)" -ForegroundColor White
    Write-Host "  remove     Remove the container completely" -ForegroundColor White
    Write-Host "  logs       Show container logs" -ForegroundColor White
    Write-Host "  help       Show this help message" -ForegroundColor White
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Yellow
    Write-Host "  .\manage-container.ps1" -ForegroundColor Gray
    Write-Host "  .\manage-container.ps1 connect" -ForegroundColor Gray
    Write-Host "  .\manage-container.ps1 stop" -ForegroundColor Gray
}

# Main logic
switch ($Command) {
    "status" {
        Show-Status
    }
    "start" {
        Start-Container
        Show-Status
    }
    "stop" {
        Stop-Container
        Show-Status
    }
    "restart" {
        Stop-Container
        Start-Sleep -Seconds 2
        Start-Container
        Show-Status
    }
    "connect" {
        Connect-Container
    }
    "remove" {
        Remove-Container
    }
    "logs" {
        Show-Logs
    }
    "help" {
        Show-Help
    }
    default {
        Show-Status
        $running = docker ps --filter "name=$ContainerName" --format "{{.Names}}"
        if ($running -eq $ContainerName) {
            $response = Read-Host "Container is running. Connect? (y/n)"
            if ($response -match "^[Yy]") {
                Connect-Container
            }
        }
    }
}
