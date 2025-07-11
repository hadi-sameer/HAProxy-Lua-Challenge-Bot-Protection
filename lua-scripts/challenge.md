# HAProxy Lua Plugin: JavaScript Challenge Bot Protection System

## Overview

This Lua plugin implements a **Proof-of-Work JavaScript Challenge** for bot protection on HAProxy, supporting **active-active deployments** through a shared Redis-based session backend.

It intercepts HTTP requests, issues computational challenges, validates submitted solutions, and creates temporary sessions stored in Redis. Clients with valid session cookies bypass the challenge.

---

## Features

* Stateless bot protection via SHA256 Proof-of-Work challenge
* Redis-backed session storage (for multi-instance HAProxy)
* Optimized Redis connection pooling
* Supports session cookie validation via HAProxy action
* Built-in API endpoints:

  * `/api/challenge`: GET a new challenge
  * `/api/validate`: POST to validate challenge and obtain session cookie

---

## Requirements

* HAProxy 2.2+
* Lua 5.3 or higher
* Redis 5.0+
* `json.lua` library (e.g., [rxi/json.lua](https://github.com/rxi/json.lua))

---

## Deployment

### 1. Environment Variables

| Variable     | Description   | Default     |
| ------------ | ------------- | ----------- |
| `REDIS_HOST` | Redis host IP | `127.0.0.1` |
| `REDIS_PORT` | Redis port    | `6379`      |

### 2. HAProxy Configuration

```haproxy
lua-load /etc/haproxy/js_challenge.lua

frontend http-in
    bind *:80
    http-request lua.validate_session_action
    http-request use-service lua.api_service if { path_beg /api/ }

    # Protect sensitive paths
    acl session_valid var(req.session_valid) -m str 1
    http-request redirect location /js-challenge.html if !session_valid path_beg /protected
```

### 3. Redis Configuration

Ensure Redis is reachable by all HAProxy instances (e.g., via host networking, or Kubernetes `ClusterIP`/`Headless` service).

---

## API Endpoints

### `GET /api/challenge`

Returns a new JavaScript challenge with a nonce and difficulty.

#### Response:

```json
{
  "id": "challenge-uuid",
  "nonce": "random-string",
  "difficulty": 4,
  "timestamp": 1721010000
}
```

### `POST /api/validate`

Validates a submitted challenge and issues a session cookie.

#### Request:

```json
{
  "challengeId": "challenge-uuid",
  "solution": "123456"
}
```

#### Successful Response:

```json
{
  "success": true,
  "message": "Challenge completed successfully",
  "redirect": "/"
}
```

Sets the cookie:

```http
Set-Cookie: js_challenge_session=<token>; HttpOnly; SameSite=Strict; Max-Age=3600; Path=/
```

#### Failure Response:

```json
{
  "success": false,
  "error": "Challenge not found or expired",
  "hash": "demo_hash",
  "expected_prefix": "0000"
}
```

---

## Challenge Logic

1. Client fetches challenge from `/api/challenge`.
2. JavaScript in browser computes a SHA256 hash of `nonce + solution`.
3. Valid solution must produce a hash prefix of N zeroes (difficulty).
4. Client sends solution to `/api/validate`.
5. On success:

   * Server returns a session cookie.
   * Client can access protected endpoints.

*Note: SHA256 validation is stubbed in this plugin — production should compute real hash!*

---

## Lua Plugin Internals

* **Session keys**: `session:<uuid>`
* **Challenge keys**: `challenge:<uuid>`
* **Session Expiry**: 1 hour
* **Challenge Expiry**: 5 minutes
* **Redis Pooling**: max 10 connections, reused every request

---

## Session Validation (HAProxy Lua Action)

```lua
core.register_action("validate_session_action", {"http-req"}, function(txn)
    -- Parses 'js_challenge_session' cookie and validates it from Redis
    -- Sets txn var `req.session_valid` to "1" or "0"
end)
```

---

## Security Notes

* The plugin currently accepts any non-zero numeric `solution` for testing.
* For production, replace the placeholder `verify_proof_of_work` logic to compute SHA256 and verify difficulty.
* All Redis keys use strict namespacing: `challenge:` and `session:`.

---

## Redis Protocol (RESP)

The plugin implements low-level RESP protocol for `GET`, `SET`, and `DEL` manually for high performance and portability.

---

## Cleanup

Every 5 minutes, idle Redis connections are closed to avoid resource leaks:

```lua
core.register_task(function()
    while true do
        core.sleep(300)
        for i, redis in pairs(redis_connections) do
            if redis then
                redis:close()
                redis_connections[i] = nil
            end
        end
    end
end)
```

---

## Example JavaScript (Client-Side)

```javascript
fetch("/api/challenge")
  .then(res => res.json())
  .then(challenge => {
    const solution = 123456; // replace with PoW miner result
    return fetch("/api/validate", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({challengeId: challenge.id, solution})
    });
  })
  .then(res => res.json())
  .then(result => {
    if (result.success) location.href = result.redirect;
    else console.error("Challenge failed", result.error);
  });
```

---
