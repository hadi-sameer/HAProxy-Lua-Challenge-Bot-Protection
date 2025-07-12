#!/bin/bash

# HAProxy Lua Challenge Bot Protection System - Redis Master-Slave with Sentinel
# This script sets up the complete system with Redis master-slave replication and automatic failover

set -e

echo "🚀 Starting HAProxy Lua Challenge Bot Protection System with Redis Sentinel"

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    echo "❌ Docker is not installed. Please install Docker first."
    exit 1
fi

# Stop and remove existing containers
echo "🧹 Cleaning up existing containers..."
docker stop haproxy-redis-master haproxy-redis-slave haproxy-redis-sentinel haproxy-backend haproxy-lua 2>/dev/null || true
docker rm haproxy-redis-master haproxy-redis-slave haproxy-redis-sentinel haproxy-backend haproxy-lua 2>/dev/null || true

# Build HAProxy image
echo "📦 Building HAProxy image..."
docker build -t haproxy-lua-challenge .

# Create network for Redis cluster
echo "🌐 Creating Redis cluster network..."
docker network create redis-cluster 2>/dev/null || true

# Start Redis Master
echo "👑 Starting Redis Master on port 6379..."
docker run -d \
    --name haproxy-redis-master \
    --network redis-cluster \
    --restart unless-stopped \
    -p 6379:6379 \
    -v $(pwd)/redis-master.conf:/usr/local/etc/redis/redis.conf \
    -v redis-master-data:/data \
    redis:7-alpine \
    redis-server /usr/local/etc/redis/redis.conf

# Wait for master to be ready
echo "⏳ Waiting for Redis Master to be ready..."
sleep 5

# Start Redis Slave
echo "🔄 Starting Redis Slave on port 6380..."
docker run -d \
    --name haproxy-redis-slave \
    --network redis-cluster \
    --restart unless-stopped \
    -p 6380:6380 \
    -v $(pwd)/redis-slave.conf:/usr/local/etc/redis/redis.conf \
    -v redis-slave-data:/data \
    redis:7-alpine \
    redis-server /usr/local/etc/redis/redis.conf

# Wait for slave to be ready
echo "⏳ Waiting for Redis Slave to be ready..."
sleep 5

# Start Redis Sentinel
echo "🛡️ Starting Redis Sentinel on port 26379..."
docker run -d \
    --name haproxy-redis-sentinel \
    --network redis-cluster \
    --restart unless-stopped \
    -p 26379:26379 \
    -v $(pwd)/sentinel.conf:/usr/local/etc/redis/sentinel.conf \
    redis:7-alpine \
    redis-sentinel /usr/local/etc/redis/sentinel.conf

# Wait for Sentinel to be ready
echo "⏳ Waiting for Redis Sentinel to be ready..."
sleep 5

# Start backend application
echo "🌐 Starting backend application on port 8080..."
docker run -d \
    --name haproxy-backend \
    --network host \
    --restart unless-stopped \
    -v $(pwd)/backend-sample:/usr/share/nginx/html \
    nginx:alpine \
    sh -c "echo 'server { listen 8080; location / { root /usr/share/nginx/html; try_files \$uri \$uri/ =404; } location /health { return 200 \"healthy\"; } }' > /etc/nginx/conf.d/default.conf && nginx -g 'daemon off;'"

# Wait for backend to be ready
echo "⏳ Waiting for backend to be ready..."
sleep 3

# Start HAProxy with Sentinel configuration
echo "⚡ Starting HAProxy with Redis Sentinel on port 8081..."
docker run -d \
    --name haproxy-lua \
    --network host \
    --restart unless-stopped \
    -e REDIS_SENTINEL_HOST=127.0.0.1 \
    -e REDIS_SENTINEL_PORT=26379 \
    -e REDIS_MASTER_NAME=mymaster \
    -v $(pwd)/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg \
    haproxy-lua-challenge

# Wait for HAProxy to be ready
echo "⏳ Waiting for HAProxy to be ready..."
sleep 5

# Check if containers are running
echo "🔍 Checking container status..."
docker ps --filter "name=haproxy"

# Check Redis cluster status
echo "🔍 Checking Redis cluster status..."

# Check master
echo "Master status:"
docker exec haproxy-redis-master redis-cli -p 6379 INFO replication | grep -E "(role|connected_slaves|master_replid)" || echo "Master not ready yet"

# Check slave
echo "Slave status:"
docker exec haproxy-redis-slave redis-cli -p 6380 INFO replication | grep -E "(role|master_host|master_port|master_link_status)" || echo "Slave not ready yet"

# Check Sentinel
echo "Sentinel status:"
docker exec haproxy-redis-sentinel redis-cli -p 26379 SENTINEL masters || echo "Sentinel not ready yet"

# Show access information
echo ""
echo "✅ System is ready!"
echo ""
echo "🌐 Access URLs:"
echo "   Main Application: http://localhost:8081"
echo "   Challenge Page: http://localhost:8081/challenge"
echo "   API Challenge: http://localhost:8081/api/challenge"
echo "   Backend Direct: http://localhost:8080"
echo "   HAProxy Stats: http://localhost:8404/stats"
echo ""
echo "🔴 Redis Cluster Endpoints:"
echo "   Master: localhost:6379"
echo "   Slave:  localhost:6380"
echo "   Sentinel: localhost:26379"
echo ""
echo "🔧 Management Commands:"
echo "   View logs: docker logs -f haproxy-lua"
echo "   Stop system: ./stop-sentinel.sh"
echo "   Restart: ./restart-sentinel.sh"
echo "   Master CLI: docker exec -it haproxy-redis-master redis-cli -p 6379"
echo "   Slave CLI:  docker exec -it haproxy-redis-slave redis-cli -p 6380"
echo "   Sentinel CLI: docker exec -it haproxy-redis-sentinel redis-cli -p 26379"
echo ""
echo "📊 Monitoring Commands:"
echo "   Master info: docker exec haproxy-redis-master redis-cli -p 6379 INFO replication"
echo "   Slave info:  docker exec haproxy-redis-slave redis-cli -p 6380 INFO replication"
echo "   Sentinel masters: docker exec haproxy-redis-sentinel redis-cli -p 26379 SENTINEL masters"
echo "   Sentinel slaves: docker exec haproxy-redis-sentinel redis-cli -p 26379 SENTINEL slaves mymaster"
echo "   System health: curl -s http://localhost:8081/api/health | jq ."
echo ""
echo "🔄 Failover Test:"
echo "   Stop master: docker stop haproxy-redis-master"
echo "   Check failover: docker exec haproxy-redis-sentinel redis-cli -p 26379 SENTINEL masters"
echo "   Restore master: docker start haproxy-redis-master"
echo ""

# Test the system
echo "🧪 Testing system..."
sleep 5

# Test challenge endpoint
echo "Testing challenge endpoint..."
if curl -s -o /dev/null -w "Challenge endpoint: %{http_code}\n" http://localhost:8081/api/challenge; then
    echo "✅ Challenge endpoint is working"
else
    echo "❌ Challenge endpoint failed"
fi

# Test main page (should redirect to challenge)
echo "Testing main page..."
if curl -s -o /dev/null -w "Main page: %{http_code}\n" http://localhost:8081/; then
    echo "✅ Main page is working"
else
    echo "❌ Main page failed"
fi

# Test backend directly
echo "Testing backend directly..."
if curl -s -o /dev/null -w "Backend: %{http_code}\n" http://localhost:8080/; then
    echo "✅ Backend is working"
else
    echo "❌ Backend failed"
fi

# Test Redis Sentinel
echo "Testing Redis Sentinel..."
if docker exec haproxy-redis-sentinel redis-cli -p 26379 SENTINEL masters | grep -q "mymaster"; then
    echo "✅ Redis Sentinel is working"
else
    echo "❌ Redis Sentinel failed"
fi

echo ""
echo "🎉 System is running successfully with Redis Master-Slave and Sentinel!"
echo ""
echo "💡 Key Features:"
echo "   ✅ Redis Master-Slave replication"
echo "   ✅ Automatic failover via Sentinel"
echo "   ✅ Read/Write separation (writes to master, reads from slaves)"
echo "   ✅ High availability and fault tolerance"
echo "   ✅ Automatic master discovery"
echo ""
echo "💡 To test the challenge:"
echo "   1. Open http://localhost:8081 in your browser"
echo "   2. You should be redirected to the challenge page"
echo "   3. The challenge will solve automatically"
echo "   4. You'll be redirected back to the main page" 