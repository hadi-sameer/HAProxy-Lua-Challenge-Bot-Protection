#!/bin/bash

# HAProxy Lua Challenge Bot Protection System - Restart Script

echo "🔄 Restarting HAProxy Lua Challenge Bot Protection System"

# Stop the system
./stop.sh

# Wait a moment
sleep 2

# Start the system
./start.sh

echo "✅ System restarted successfully!" 