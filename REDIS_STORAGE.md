# Redis Storage for HAProxy Lua Challenge Bot Protection

This document explains the Redis storage functionality implemented in the challenge system.

## Overview

The HAProxy Lua Challenge Bot Protection system now uses Redis as the primary storage backend for challenges and sessions, with automatic fallback to in-memory storage when Redis is unavailable.

## Architecture

### Storage Layers

1. **Primary Storage**: Redis (distributed, persistent)
2. **Fallback Storage**: In-memory (local HAProxy instance)
3. **Automatic Failover**: Seamless transition between storage types

### Data Flow

```
Client Request → HAProxy → Lua Script → Redis (Primary)
                                    ↓
                              In-Memory (Fallback)
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `REDIS_HOST` | 127.0.0.1 | Redis server hostname |
| `REDIS_PORT` | 6379 | Redis server port |
| `USE_REDIS` | true | Enable Redis storage |
| `REDIS_TIMEOUT` | 5000 | Redis connection timeout (ms) |

### Lua Configuration

```lua
local CONFIG = {
    USE_REDIS = true,                    -- Enable Redis storage
    REDIS_HOST = "127.0.0.1",           -- Redis host
    REDIS_PORT = 6379,                  -- Redis port
    REDIS_TIMEOUT = 5000,               -- Connection timeout
    REDIS_KEY_PREFIX = "challenge:",    -- Challenge key prefix
    SESSION_KEY_PREFIX = "session:"     -- Session key prefix
}
```

## Redis Data Structure

### Challenge Storage

**Key Format**: `challenge:{challenge_id}`

**Value Structure**:
```json
{
    "id": "uuid-string",
    "timestamp": 1234567890,
    "nonce": "random-string",
    "difficulty": 4,
    "expires": 1234567890
}
```

**TTL**: 300 seconds (5 minutes)

### Session Storage

**Key Format**: `session:{session_token}`

**Value Structure**:
```json
{
    "token": "uuid-string",
    "created": 1234567890,
    "expires": 1234567890
}
```

**TTL**: 3600 seconds (1 hour)

## Implementation Details

### Connection Management

```lua
local function connect_redis()
    if not CONFIG.USE_REDIS then
        return nil
    end
    
    local socket = core.tcp()
    socket:settimeout(CONFIG.REDIS_TIMEOUT)
    
    local success, err = socket:connect(CONFIG.REDIS_HOST, CONFIG.REDIS_PORT)
    if not success then
        core.log(core.warning, "Failed to connect to Redis: " .. err)
        return nil
    end
    
    return socket
end
```

### Challenge Operations

#### Generate Challenge
```lua
local function generate_challenge()
    local challenge = {
        id = generate_uuid(),
        timestamp = os.time(),
        nonce = generate_random_string(32),
        difficulty = CONFIG.DIFFICULTY,
        expires = os.time() + CONFIG.CHALLENGE_EXPIRY
    }
    
    -- Try Redis first
    if CONFIG.USE_REDIS then
        local redis_key = CONFIG.REDIS_KEY_PREFIX .. challenge.id
        local success = redis_set(redis_key, challenge, CONFIG.CHALLENGE_EXPIRY)
        if success then
            core.log(core.info, "Challenge stored in Redis: " .. challenge.id)
        else
            -- Fallback to in-memory
            challenges[challenge.id] = challenge
        end
    else
        challenges[challenge.id] = challenge
    end
    
    return challenge
end
```

#### Retrieve Challenge
```lua
local function get_challenge(challenge_id)
    -- Try Redis first
    if CONFIG.USE_REDIS then
        local redis_key = CONFIG.REDIS_KEY_PREFIX .. challenge_id
        local challenge = redis_get(redis_key)
        if challenge then
            return challenge
        end
    end
    
    -- Fallback to in-memory
    return challenges[challenge_id]
end
```

#### Delete Challenge
```lua
local function delete_challenge(challenge_id)
    -- Try Redis first
    if CONFIG.USE_REDIS then
        local redis_key = CONFIG.REDIS_KEY_PREFIX .. challenge_id
        redis_del(redis_key)
    end
    
    -- Also remove from memory
    challenges[challenge_id] = nil
end
```

### Session Operations

Similar pattern for session management with `SESSION_KEY_PREFIX`.

## Monitoring and Debugging

### Health Check Endpoint

```bash
curl http://localhost:8081/api/health
```

**Response**:
```json
{
    "status": "ok",
    "storage": "redis",
    "challenges": 5,
    "sessions": 12,
    "redis_connected": true,
    "config": {
        "use_redis": true,
        "redis_host": "127.0.0.1",
        "redis_port": 6379
    }
}
```

### Redis Commands

```bash
# Connect to Redis
docker exec -it haproxy-redis redis-cli

# View all challenges
KEYS challenge:*

# View all sessions
KEYS session:*

# Get specific challenge
GET challenge:uuid-here

# Monitor Redis operations
MONITOR

# Check Redis info
INFO memory
```

### Testing Script

```bash
# Run comprehensive Redis storage test
./test-redis-storage.sh
```

## Performance Considerations

### Redis Optimization

1. **Connection Pooling**: Single connection per HAProxy instance
2. **Timeout Handling**: 5-second connection timeout
3. **Automatic Cleanup**: TTL-based expiration
4. **Memory Management**: LRU eviction policy

### Fallback Strategy

1. **Graceful Degradation**: Automatic fallback to in-memory
2. **No Data Loss**: In-memory storage maintains functionality
3. **Transparent Operation**: No user-visible impact

## Troubleshooting

### Common Issues

#### Redis Connection Failed
```bash
# Check Redis status
docker ps | grep redis
docker logs haproxy-redis

# Check storage fallback
curl -s http://localhost:8081/api/health | jq '.storage, .redis_connected'
```

**Solutions**:
- Ensure Redis container is running
- Check network connectivity
- Verify port availability
- System automatically falls back to in-memory

#### High Memory Usage
```bash
# Check Redis memory
docker exec -it haproxy-redis redis-cli INFO memory

# Clear expired keys
docker exec -it haproxy-redis redis-cli FLUSHDB
```

#### Performance Issues
```bash
# Monitor Redis operations
docker exec -it haproxy-redis redis-cli MONITOR

# Check key count
docker exec -it haproxy-redis redis-cli DBSIZE
```

## Security Considerations

### Redis Security

1. **Network Isolation**: Redis runs on localhost only
2. **No Authentication**: Local development setup
3. **Data Encryption**: Consider TLS for production
4. **Access Control**: Containerized deployment

### Data Protection

1. **TTL Expiration**: Automatic cleanup of expired data
2. **UUID Generation**: Cryptographically secure IDs
3. **JSON Encoding**: Safe data serialization
4. **Error Handling**: Graceful failure modes

## Production Deployment

### Recommended Setup

1. **Redis Cluster**: For high availability
2. **Authentication**: Enable Redis AUTH
3. **TLS Encryption**: Secure network communication
4. **Monitoring**: Redis metrics and alerts
5. **Backup**: Regular data backups

### Configuration Example

```bash
# Production environment variables
export REDIS_HOST=redis-cluster.example.com
export REDIS_PORT=6379
export USE_REDIS=true
export REDIS_TIMEOUT=3000

# Start system
./start.sh
```

## Migration from In-Memory

The system automatically handles migration:

1. **Existing Data**: In-memory data remains accessible
2. **New Data**: Stored in Redis when available
3. **Seamless Transition**: No service interruption
4. **Backward Compatibility**: Works with or without Redis

## Conclusion

Redis storage provides:
- **Scalability**: Multiple HAProxy instances
- **Persistence**: Survives HAProxy restarts
- **Reliability**: Automatic fallback mechanism
- **Performance**: Fast key-value operations
- **Monitoring**: Rich debugging capabilities

The implementation ensures high availability while maintaining backward compatibility with in-memory storage. 