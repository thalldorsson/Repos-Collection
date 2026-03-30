#!/usr/bin/env pwsh
# Setup script for Redis Cluster initialization
#
# This script:
# 1. Starts the Redis cluster containers
# 2. Waits for nodes to be ready
# 3. Initializes the cluster with 3 masters + 3 replicas
# 4. Verifies cluster health

Write-Host "🚀 Starting Redis Cluster Setup..." -ForegroundColor Green

# Check if Docker is running
try {
    docker ps | Out-Null
} catch {
    Write-Host "❌ Error: Docker is not running. Please start Docker Desktop." -ForegroundColor Red
    exit 1
}

# Start Redis cluster containers
Write-Host "`n📦 Starting Redis cluster containers..." -ForegroundColor Yellow
docker-compose -f docker-compose-redis-cluster.yml up -d

if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Failed to start containers" -ForegroundColor Red
    exit 1
}

# Wait for containers to be ready
Write-Host "`n⏳ Waiting for Redis nodes to be ready..." -ForegroundColor Yellow
Start-Sleep -Seconds 10

# Check node status
Write-Host "`n🔍 Checking node status..." -ForegroundColor Yellow
$nodes = @(7000, 7001, 7002, 7003, 7004, 7005)
$allReady = $true

foreach ($port in $nodes) {
    try {
        $result = docker exec redis-node-1 redis-cli -p $port ping 2>$null
        if ($result -eq "PONG") {
            Write-Host "  ✓ Node on port $port is ready" -ForegroundColor Green
        } else {
            Write-Host "  ✗ Node on port $port is not responding" -ForegroundColor Red
            $allReady = $false
        }
    } catch {
        Write-Host "  ✗ Node on port $port is not reachable" -ForegroundColor Red
        $allReady = $false
    }
}

if (-not $allReady) {
    Write-Host "`n❌ Some nodes are not ready. Please check Docker logs." -ForegroundColor Red
    exit 1
}

# Initialize cluster
Write-Host "`n🔗 Initializing Redis cluster (3 masters + 3 replicas)..." -ForegroundColor Yellow
Write-Host "   This will configure:" -ForegroundColor Cyan
Write-Host "   - Masters: localhost:7000, localhost:7001, localhost:7002" -ForegroundColor Cyan
Write-Host "   - Replicas: localhost:7003, localhost:7004, localhost:7005" -ForegroundColor Cyan

# Create cluster
$clusterCmd = "redis-cli --cluster create " +
    "127.0.0.1:7000 127.0.0.1:7001 127.0.0.1:7002 " +
    "127.0.0.1:7003 127.0.0.1:7004 127.0.0.1:7005 " +
    "--cluster-replicas 1 --cluster-yes"

docker exec -it redis-node-1 sh -c $clusterCmd

if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Failed to initialize cluster" -ForegroundColor Red
    exit 1
}

# Verify cluster
Write-Host "`n✅ Verifying cluster health..." -ForegroundColor Yellow
$clusterInfo = docker exec redis-node-1 redis-cli --cluster check 127.0.0.1:7000

Write-Host $clusterInfo

# Get cluster info
Write-Host "`n📊 Cluster Information:" -ForegroundColor Yellow
$info = docker exec redis-node-1 redis-cli -p 7000 cluster info
Write-Host $info

# Display summary
Write-Host "`n✅ Redis Cluster Setup Complete!" -ForegroundColor Green
Write-Host "`n📋 Cluster Details:" -ForegroundColor Cyan
Write-Host "   Master Nodes: localhost:7000, localhost:7001, localhost:7002" -ForegroundColor White
Write-Host "   Replica Nodes: localhost:7003, localhost:7004, localhost:7005" -ForegroundColor White
Write-Host "   Web UI: http://localhost:8081 (Redis Commander)" -ForegroundColor White

Write-Host "`n🔧 Useful Commands:" -ForegroundColor Cyan
Write-Host "   Check cluster status: docker exec redis-node-1 redis-cli -p 7000 cluster info" -ForegroundColor White
Write-Host "   View cluster nodes: docker exec redis-node-1 redis-cli -p 7000 cluster nodes" -ForegroundColor White
Write-Host "   Connect to node: docker exec -it redis-node-1 redis-cli -p 7000" -ForegroundColor White
Write-Host "   View logs: docker-compose -f docker-compose-redis-cluster.yml logs redis-node-1" -ForegroundColor White
Write-Host "   Stop cluster: docker-compose -f docker-compose-redis-cluster.yml down" -ForegroundColor White

Write-Host "`n💡 Tip: Update your .env file to use cluster mode:" -ForegroundColor Yellow
Write-Host "   REDIS_URL=redis://localhost:7000" -ForegroundColor White
Write-Host "   REDIS_CLUSTER=true" -ForegroundColor White

Write-Host "`n🎉 Ready to use Redis Cluster with M365 Security MCP!" -ForegroundColor Green
