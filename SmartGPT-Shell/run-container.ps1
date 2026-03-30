$ContainerName = "smartgpt-dev"
$ImageName = "mcr.microsoft.com/powershell:7.4-debian-11"
$LocalPath = (Get-Location).Path
$WorkDir = "/workspaces/SmartGPT-Shell"
$SshPath = "$HOME\.ssh"

Write-Host "=== SmartGPT Shell Container Manager ==="
Write-Host "Container name: $ContainerName"
Write-Host "Working directory: $WorkDir"
Write-Host "Local path: $LocalPath"

# Check if container already exists
$ExistingContainer = docker ps -a --filter "name=$ContainerName" --format "{{.Names}}"

if ($ExistingContainer -eq $ContainerName) {
    # Container exists, check if it's running
    $RunningContainer = docker ps --filter "name=$ContainerName" --format "{{.Names}}"
    
    if ($RunningContainer -eq $ContainerName) {
        Write-Host "Container is already running. Attaching to existing session..."
        docker exec -it $ContainerName bash
    } else {
        Write-Host "Container exists but is stopped. Starting and attaching..."
        docker start $ContainerName
        docker exec -it $ContainerName bash
    }
} else {
    # Container doesn't exist, create it
    Write-Host "Creating new persistent container..."
    
    # Check if SSH directory exists
    if (-not (Test-Path $SshPath)) {
        Write-Warning "SSH directory not found at $SshPath. SSH keys will not be available in the container."
        $SshMount = ""
    } else {
        $SshMount = "-v `"${SshPath}:/root/.ssh:ro`""
        Write-Host "Mounting SSH directory from $SshPath"
    }

    # Create persistent container (no --rm flag)
    $DockerCmd = "docker run -it -d --name $ContainerName -v `"${LocalPath}:${WorkDir}`" $SshMount -w `"${WorkDir}`" $ImageName"
    
    Write-Host "Creating container with command: $DockerCmd"
    Invoke-Expression $DockerCmd
    
    # Run initial setup
    Write-Host "Running initial container setup..."
    docker exec $ContainerName bash -c "if [ -f './scripts/setup-container.sh' ]; then bash ./scripts/setup-container.sh; fi"
    
    # Attach to the container
    Write-Host "Attaching to container..."
    docker exec -it $ContainerName bash
}
