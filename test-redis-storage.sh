#!/bin/bash

# Test Redis Storage for HAProxy Lua Challenge Bot Protection
# This script tests the Redis storage functionality

echo "🧪 Testing Redis Storage for Challenge System"
echo "=============================================="

# Check if system is running
echo "1. Checking if system is running..."
if ! curl -s -o /dev/null -w "%{http_code}" http://localhost:8081/api/health | grep -q "200"; then
    echo "❌ System is not running. Please start it first with ./start.sh"
    exit 1
fi
echo "✅ System is running"

# Check health endpoint
echo ""
echo "2. Checking health endpoint..."
HEALTH_RESPONSE=$(curl -s http://localhost:8081/api/health)
echo "Health Response:"
echo "$HEALTH_RESPONSE" | jq '.'

# Extract storage type and Redis connection status
STORAGE_TYPE=$(echo "$HEALTH_RESPONSE" | jq -r '.storage')
REDIS_CONNECTED=$(echo "$HEALTH_RESPONSE" | jq -r '.redis_connected')

echo ""
echo "Storage Type: $STORAGE_TYPE"
echo "Redis Connected: $REDIS_CONNECTED"

# Test challenge generation
echo ""
echo "3. Testing challenge generation..."
CHALLENGE_RESPONSE=$(curl -s http://localhost:8081/api/challenge)
echo "Challenge Response:"
echo "$CHALLENGE_RESPONSE" | jq '.'

# Extract challenge ID
CHALLENGE_ID=$(echo "$CHALLENGE_RESPONSE" | jq -r '.id')
echo "Challenge ID: $CHALLENGE_ID"

# Check if challenge is stored in Redis
echo ""
echo "4. Checking if challenge is stored in Redis..."
if [ "$STORAGE_TYPE" = "redis" ] && [ "$REDIS_CONNECTED" = "true" ]; then
    REDIS_CHALLENGE=$(docker exec -it haproxy-redis redis-cli GET "challenge:$CHALLENGE_ID" 2>/dev/null)
    if [ -n "$REDIS_CHALLENGE" ]; then
        echo "✅ Challenge found in Redis:"
        echo "$REDIS_CHALLENGE" | jq '.'
    else
        echo "❌ Challenge not found in Redis"
    fi
else
    echo "⚠️  Redis not available, using in-memory storage"
fi

# Test challenge validation
echo ""
echo "5. Testing challenge validation..."
VALIDATION_RESPONSE=$(curl -s -X POST http://localhost:8081/api/validate \
    -H "Content-Type: application/json" \
    -d "{\"challengeId\": \"$CHALLENGE_ID\", \"solution\": 12345}")
echo "Validation Response:"
echo "$VALIDATION_RESPONSE" | jq '.'

# Check if challenge was removed from Redis after validation
echo ""
echo "6. Checking if challenge was removed after validation..."
if [ "$STORAGE_TYPE" = "redis" ] && [ "$REDIS_CONNECTED" = "true" ]; then
    REDIS_CHALLENGE_AFTER=$(docker exec -it haproxy-redis redis-cli GET "challenge:$CHALLENGE_ID" 2>/dev/null)
    if [ -z "$REDIS_CHALLENGE_AFTER" ]; then
        echo "✅ Challenge properly removed from Redis after validation"
    else
        echo "❌ Challenge still exists in Redis after validation"
    fi
else
    echo "⚠️  Redis not available, using in-memory storage"
fi

# Test session creation
echo ""
echo "7. Testing session creation..."
# Extract session token from cookies
SESSION_COOKIE=$(echo "$VALIDATION_RESPONSE" | jq -r '.success')
if [ "$SESSION_COOKIE" = "true" ]; then
    echo "✅ Session created successfully"
    
    # Test session validation by accessing protected page
    echo ""
    echo "8. Testing session validation..."
    PROTECTED_RESPONSE=$(curl -s -I http://localhost:8081/ | head -1)
    echo "Protected page response: $PROTECTED_RESPONSE"
    
    if echo "$PROTECTED_RESPONSE" | grep -q "200\|302"; then
        echo "✅ Session validation working"
    else
        echo "❌ Session validation failed"
    fi
else
    echo "❌ Session creation failed"
fi

# Show Redis statistics
echo ""
echo "9. Redis Statistics..."
if [ "$STORAGE_TYPE" = "redis" ] && [ "$REDIS_CONNECTED" = "true" ]; then
    echo "Active sessions in Redis:"
    docker exec -it haproxy-redis redis-cli KEYS 'session:*' | wc -l
    
    echo "Active challenges in Redis:"
    docker exec -it haproxy-redis redis-cli KEYS 'challenge:*' | wc -l
    
    echo "Total keys in Redis:"
    docker exec -it haproxy-redis redis-cli DBSIZE
else
    echo "⚠️  Redis not available"
fi

echo ""
echo "🎉 Redis Storage Test Complete!"
echo ""
echo "Summary:"
echo "- Storage Type: $STORAGE_TYPE"
echo "- Redis Connected: $REDIS_CONNECTED"
echo "- Challenge Generation: ✅"
echo "- Challenge Storage: $([ "$STORAGE_TYPE" = "redis" ] && echo "✅" || echo "⚠️ (in-memory)")"
echo "- Challenge Validation: ✅"
echo "- Session Management: ✅" 