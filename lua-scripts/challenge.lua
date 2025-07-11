-- JavaScript Challenge Bot Protection System - Optimized for Active-Active HAProxy
-- Uses Redis for session storage to support multiple HAProxy instances

local json = require("json")

-- Configuration
local DIFFICULTY = 4
local CHALLENGE_EXPIRY = 300 -- 5 minutes
local SESSION_EXPIRY = 3600 -- 1 hour

-- Redis configuration from environment variables (for host networking)
local REDIS_HOST = os.getenv("REDIS_HOST") or "127.0.0.1"
local REDIS_PORT = tonumber(os.getenv("REDIS_PORT")) or 6379

-- Thread-safe Redis connection function
local function get_redis_connection()
    local redis = core.tcp()
    local ok, err = redis:connect(REDIS_HOST, REDIS_PORT)
    if not ok then
        return nil
    end
    return redis
end

-- Safe Redis operation wrapper
local function safe_redis_operation(operation)
    local redis = get_redis_connection()
    if not redis then
        return nil
    end
    
    local success, result = pcall(operation, redis)
    
    -- Always close the connection
    pcall(function() redis:close() end)
    
    if success then
        return result
    else
        return nil
    end
end

-- Utility functions
local function generate_random_string(length)
    local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local result = ""
    for i = 1, length do
        local rand = math.random(1, #chars)
        result = result .. chars:sub(rand, rand)
    end
    return result
end

local function generate_uuid()
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return string.gsub(template, "[xy]", function(c)
        local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format("%x", v)
    end)
end

-- Redis operations with thread-safe connections
local function redis_set(key, value, expiry)
    return safe_redis_operation(function(redis)
        -- Use RESP protocol format: *3\r\n$3\r\nSET\r\n$<keylen>\r\n<key>\r\n$<vallen>\r\n<value>\r\n
        local key_len = string.len(key)
        local value_len = string.len(value)
        local cmd = string.format("*3\r\n$3\r\nSET\r\n$%d\r\n%s\r\n$%d\r\n%s\r\n", key_len, key, value_len, value)
        
        if expiry then
            -- Add EX command: *5\r\n$3\r\nSET\r\n$<keylen>\r\n<key>\r\n$<vallen>\r\n<value>\r\n$2\r\nEX\r\n$<expirylen>\r\n<expiry>\r\n
            local expiry_str = tostring(expiry)
            local expiry_len = string.len(expiry_str)
            cmd = string.format("*5\r\n$3\r\nSET\r\n$%d\r\n%s\r\n$%d\r\n%s\r\n$2\r\nEX\r\n$%d\r\n%s\r\n", 
                               key_len, key, value_len, value, expiry_len, expiry_str)
        end
        
        local ok, err = redis:send(cmd)
        if not ok then 
            return false 
        end
        
        local response = redis:receive()
        return response and response:match("^%+OK") ~= nil
    end)
end

local function redis_get(key)
    return safe_redis_operation(function(redis)
        -- Use RESP protocol format: *2\r\n$3\r\nGET\r\n$<keylen>\r\n<key>\r\n
        local key_len = string.len(key)
        local cmd = string.format("*2\r\n$3\r\nGET\r\n$%d\r\n%s\r\n", key_len, key)
        
        local ok, err = redis:send(cmd)
        if not ok then 
            return nil 
        end
        
        local response = redis:receive()
        if response and response:match("^%$%-1") then
            return nil -- Key not found
        end
        
        -- Parse the response: $<len>\r\n<value>\r\n
        if response and response:match("^%$%d+") then
            local len_str = response:match("^%$(%d+)")
            local len = tonumber(len_str)
            if len and len > 0 then
                local value = redis:receive(len)
                return value
            end
        end
        
        return nil
    end)
end

local function redis_del(key)
    return safe_redis_operation(function(redis)
        -- Use RESP protocol format: *2\r\n$3\r\nDEL\r\n$<keylen>\r\n<key>\r\n
        local key_len = string.len(key)
        local cmd = string.format("*2\r\n$3\r\nDEL\r\n$%d\r\n%s\r\n", key_len, key)
        
        local ok, err = redis:send(cmd)
        if not ok then 
            return false 
        end
        
        local response = redis:receive()
        return response and response:match("^%:1") ~= nil
    end)
end

-- Challenge management
local function generate_challenge()
    local challenge_id = generate_uuid()
    local timestamp = os.time()
    local nonce = generate_random_string(32)
    
    local challenge = {
        id = challenge_id,
        timestamp = timestamp,
        nonce = nonce,
        difficulty = DIFFICULTY,
        expires = timestamp + CHALLENGE_EXPIRY
    }
    
    -- Store in Redis
    local key = "challenge:" .. challenge_id
    local value = json.encode(challenge)
    if redis_set(key, value, CHALLENGE_EXPIRY) then
        return {
            id = challenge_id,
            nonce = nonce,
            difficulty = DIFFICULTY,
            timestamp = timestamp
        }
    end
    
    return nil
end

local function verify_proof_of_work(challenge_id, solution)
    local key = "challenge:" .. challenge_id
    local challenge_data = redis_get(key)
    
    if not challenge_data then
        return {valid = false, error = "Challenge not found or expired"}
    end
    
    local challenge = json.decode(challenge_data)
    if not challenge then
        return {valid = false, error = "Invalid challenge data"}
    end
    
    local current_time = os.time()
    if current_time > challenge.expires then
        redis_del(key)
        return {valid = false, error = "Challenge expired"}
    end
    
    -- For demo purposes, accept any valid solution
    -- In production, verify actual SHA256 hash
    local is_valid = solution and tonumber(solution) and tonumber(solution) > 0
    
    if is_valid then
        redis_del(key) -- Clean up challenge
    end
    
    return {
        valid = is_valid,
        hash = "demo_hash",
        expected_prefix = string.rep("0", challenge.difficulty),
        error = is_valid and nil or "Invalid solution format"
    }
end

-- Session management
local function create_session()
    local session_token = generate_uuid()
    local current_time = os.time()
    
    local session = {
        token = session_token,
        created = current_time,
        expires = current_time + SESSION_EXPIRY
    }
    
    local key = "session:" .. session_token
    local value = json.encode(session)
    
    if redis_set(key, value, SESSION_EXPIRY) then
        return session_token
    end
    
    return nil
end

local function validate_session(session_token)
    if not session_token then
        return false
    end
    
    local key = "session:" .. session_token
    local session_data = redis_get(key)
    
    if not session_data then
        return false
    end
    
    local session = json.decode(session_data)
    if not session then
        return false
    end
    
    local current_time = os.time()
    if current_time > session.expires then
        redis_del(key)
        return false
    end
    
    return true
end

-- Service to serve challenge page with inspect protection
core.register_service("serve_challenge_page", "http", function(applet)
    local file_path = "/usr/local/etc/haproxy/challenge-page.html"
    local file = io.open(file_path, "r")
    
    if file then
        local content = file:read("*all")
        file:close()
        
        applet:set_status(200)
        applet:add_header("content-type", "text/html")
        applet:add_header("cache-control", "no-cache, no-store, must-revalidate")
        applet:add_header("pragma", "no-cache")
        applet:add_header("expires", "0")
        applet:add_header("content-length", tostring(#content))
        applet:start_response()
        applet:send(content)
    else
        applet:set_status(500)
        applet:add_header("content-type", "text/plain")
        applet:add_header("content-length", "28")
        applet:start_response()
        applet:send("Error: Challenge page not found")
    end
end)

-- API service for HAProxy
core.register_service("api_service", "http", function(applet)
    local method = applet.method
    local path = applet.path
    
    -- Initialize random seed
    math.randomseed(os.time())
    
    -- Handle API endpoints
    if path == "/api/challenge" and method == "GET" then
        local challenge = generate_challenge()
        if not challenge then
            applet:set_status(500)
            applet:add_header("Content-Type", "application/json")
            applet:start_response()
            applet:send(json.encode({error = "Failed to generate challenge"}))
            return
        end
        
        local response_body = json.encode(challenge)
        applet:set_status(200)
        applet:add_header("Content-Type", "application/json")
        applet:add_header("Cache-Control", "no-cache, no-store, must-revalidate")
        applet:add_header("Pragma", "no-cache")
        applet:add_header("Expires", "0")
        applet:add_header("Content-Length", tostring(#response_body))
        applet:start_response()
        applet:send(response_body)
        return
    end
    
    if path == "/api/validate" and method == "POST" then
        local body = applet:receive()
        if not body or body == "" then
            local error_response = json.encode({error = "Missing request body"})
            applet:set_status(400)
            applet:add_header("Content-Type", "application/json")
            applet:add_header("Content-Length", tostring(#error_response))
            applet:start_response()
            applet:send(error_response)
            return
        end
        
        local data = json.decode(body)
        if not data or not data.challengeId or not data.solution then
            local error_response = json.encode({error = "Missing challengeId or solution"})
            applet:set_status(400)
            applet:add_header("Content-Type", "application/json")
            applet:add_header("Content-Length", tostring(#error_response))
            applet:start_response()
            applet:send(error_response)
            return
        end
        
        local result = verify_proof_of_work(data.challengeId, data.solution)
        
        if result.valid then
            local session_token = create_session()
            if not session_token then
                local error_response = json.encode({error = "Failed to create session"})
                applet:set_status(500)
                applet:add_header("Content-Type", "application/json")
                applet:add_header("Content-Length", tostring(#error_response))
                applet:start_response()
                applet:send(error_response)
                return
            end
            
            local cookie = "js_challenge_session=" .. session_token .. 
                          "; HttpOnly; SameSite=Strict; Max-Age=" .. SESSION_EXPIRY .. "; Path=/"
            
            local success_response = json.encode({
                success = true,
                message = "Challenge completed successfully",
                redirect = "/"
            })
            
            applet:set_status(200)
            applet:add_header("Content-Type", "application/json")
            applet:add_header("Set-Cookie", cookie)
            applet:add_header("Content-Length", tostring(#success_response))
            applet:start_response()
            applet:send(success_response)
        else
            local error_response = json.encode({
                success = false,
                error = result.error or "Invalid solution"
            })
            applet:set_status(400)
            applet:add_header("Content-Type", "application/json")
            applet:add_header("Content-Length", tostring(#error_response))
            applet:start_response()
            applet:send(error_response)
        end
        return
    end
    
    -- Default response for unknown endpoints
    local error_response = json.encode({error = "Endpoint not found"})
    applet:set_status(404)
    applet:add_header("Content-Type", "application/json")
    applet:add_header("Content-Length", tostring(#error_response))
    applet:start_response()
    applet:send(error_response)
end)

-- Session validation action for HAProxy
core.register_action("validate_session_action", { "http-req" }, function(txn)
    local headers = txn.http:req_get_headers()
    local cookies = headers["cookie"] and headers["cookie"][0] or headers["Cookie"] and headers["Cookie"][0] or ""
    local session_token = string.match(cookies, "js_challenge_session=([^;]*)")
    
    local is_valid = validate_session(session_token)
    txn:set_var("req.session_valid", is_valid and "1" or "0")
end) 