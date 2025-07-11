#!/bin/bash

# Stop HAProxy Lua Challenge Bot Protection System

echo "🛑 Stopping HAProxy Lua Challenge Bot Protection System"

# Stop containers
echo "Stopping containers..."
docker stop haproxy-lua haproxy-backend haproxy-redis 2>/dev/null || true

# Remove containers
echo "Removing containers..."
docker rm haproxy-lua haproxy-backend haproxy-redis 2>/dev/null || true

echo "✅ System stopped successfully" 