#!/bin/bash

# HAProxy Lua Challenge Bot Protection - Single Instance with Host Networking
# This script starts the complete system with Redis session storage using docker run

set -e

echo "🚀 Starting HAProxy Lua Challenge Bot Protection System (Single Instance)"

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    echo "❌ Docker is not installed. Please install Docker first."
    exit 1
fi

# Stop and remove existing containers
echo "🧹 Cleaning up existing containers..."
docker stop haproxy-redis haproxy-backend haproxy-lua 2>/dev/null || true
docker rm haproxy-redis haproxy-backend haproxy-lua 2>/dev/null || true

# Build HAProxy image
echo "📦 Building HAProxy image..."
docker build -t haproxy-lua-challenge .

# Start Redis with host networking
echo "🔴 Starting Redis..."
docker run -d \
    --name haproxy-redis \
    --network host \
    --restart unless-stopped \
    redis:7-alpine \
    redis-server --appendonly yes --maxmemory 256mb --maxmemory-policy allkeys-lru

# Wait for Redis to be ready
echo "⏳ Waiting for Redis to be ready..."
sleep 5

# Start backend application with host networking on port 8080
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

# Start HAProxy with host networking on port 8081
echo "⚡ Starting HAProxy on port 8081..."
docker run -d \
    --name haproxy-lua \
    --network host \
    --restart unless-stopped \
    -e REDIS_HOST=127.0.0.1 \
    -e REDIS_PORT=6379 \
    haproxy-lua-challenge

# Wait for HAProxy to be ready
echo "⏳ Waiting for HAProxy to be ready..."
sleep 5

# Check if containers are running
echo "🔍 Checking container status..."
docker ps --filter "name=haproxy"

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
echo "🔧 Management Commands:"
echo "   View logs: docker logs -f haproxy-lua"
echo "   Stop system: ./stop.sh"
echo "   Restart: ./restart.sh"
echo "   Check Redis: docker exec -it haproxy-redis redis-cli"
echo ""
echo "📊 Redis Commands:"
echo "   Connect to Redis: docker exec -it haproxy-redis redis-cli"
echo "   View sessions: docker exec -it haproxy-redis redis-cli KEYS 'session:*'"
echo "   View challenges: docker exec -it haproxy-redis redis-cli KEYS 'challenge:*'"
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

echo ""
echo "🎉 System is running successfully!"
echo ""
echo "💡 To test the challenge:"
echo "   1. Open http://localhost:8081 in your browser"
echo "   2. You should be redirected to the challenge page"
echo "   3. The challenge will solve automatically"
echo "   4. You'll be redirected back to the main page" 