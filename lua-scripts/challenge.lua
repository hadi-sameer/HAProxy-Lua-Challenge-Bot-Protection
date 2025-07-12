-- JavaScript Challenge Bot Protection System - Redis Master-Slave with Sentinel
-- Uses Redis Sentinel for automatic master discovery and failover
-- Supports read/write separation: writes to master, reads from slaves

local json = require("json")

-- =============================================================================
-- CONFIGURATION
-- =============================================================================
local CONFIG = {
    DIFFICULTY = 4,
    CHALLENGE_EXPIRY = 300, -- 5 minutes
    SESSION_EXPIRY = 3600, -- 1 hour
    CHALLENGE_TIMEOUT = 300, -- 5 minutes
    SESSION_TIMEOUT = 3600, -- 1 hour
    REDIS_TIMEOUT = 0.5, -- 0.5 second timeout for Redis operations (reduced from 1)
    USE_REDIS = true, -- Set to false to use only in-memory storage
    REDIS_KEY_PREFIX = "challenge:",
    SESSION_KEY_PREFIX = "session:",
    REDIS_NODES = os.getenv("REDIS_NODES") or "127.0.0.1:6379,127.0.0.1:6380", -- Comma-separated list of Redis nodes
    REDIS_DOWN_TIMEOUT = 30, -- 30 seconds to retry after Redis failure
    MAX_RETRIES = 3,
    CHALLENGE_PAGE_PATH = "/usr/local/etc/haproxy/challenge-page.html",
    INSPECT_PROTECTION_ENABLED = true
}

-- =============================================================================
-- GLOBAL VARIABLES
-- =============================================================================
local redis_master = nil
local redis_slaves = {}
local last_discovery = 0
local discovery_interval = 5 -- Redis discovery every 5 seconds (reduced from 30)
local redis_available = false -- Track if Redis is available
local redis_down_until = 0 -- Cache Redis down state to avoid repeated timeouts

-- =============================================================================
-- IN-MEMORY STORAGE (Fallback)
-- =============================================================================
local challenges = {}
local sessions = {}

-- =============================================================================
-- REDIS PROTOCOL FUNCTIONS
-- =============================================================================

-- Build Redis RESP command
local function build_redis_command(args)
    local cmd = "*" .. #args .. "\r\n"
    for _, arg in ipairs(args) do
        cmd = cmd .. "$" .. #tostring(arg) .. "\r\n" .. tostring(arg) .. "\r\n"
    end
    return cmd
end

-- Parse Redis RESP response
local function parse_redis_response(socket)
    local line, err = socket:receive("*l")
    if not line then
        return nil, "Failed to read response: " .. (err or "unknown error")
    end
    
    local response_type = line:sub(1, 1)
    if response_type == "+" then
        -- Simple string
        return line:sub(2)
    elseif response_type == "-" then
        -- Error
        return nil, line:sub(2)
    elseif response_type == ":" then
        -- Integer
        return tonumber(line:sub(2))
    elseif response_type == "$" then
        -- Bulk string
        local length = tonumber(line:sub(2))
        if length == -1 then
            return nil -- Null bulk string
        end
        local data, err = socket:receive(length)
        if not data then
            return nil, "Failed to read bulk string: " .. (err or "unknown error")
        end
        -- Read the trailing \r\n
        socket:receive(2)
        return data
    elseif response_type == "*" then
        -- Array
        local count = tonumber(line:sub(2))
        if count == -1 then
            return nil -- Null array
        end
        local result = {}
        for i = 1, count do
            local item = parse_redis_response(socket)
            if item then
                table.insert(result, item)
            end
        end
        return result
    else
        return nil, "Unknown response type: " .. response_type
    end
end

-- Execute Redis command
local function redis_command(socket, args)
    local cmd = build_redis_command(args)
    local success, err = socket:send(cmd)
    if not success then
        return nil, "Redis send failed: " .. (err or "unknown error")
    end
    
    return parse_redis_response(socket)
end



-- =============================================================================
-- REDIS CONNECTION FUNCTIONS
-- =============================================================================

-- Create Redis connection to master (for writes)
local function create_master_connection()
    if not CONFIG.USE_REDIS then
        return nil
    end
    
    if not redis_master then
        return nil
    end
    
    local socket = core.tcp()
    if not socket then
        core.log(core.warning, "Failed to create TCP socket for Redis master")
        return nil
    end
    
    socket:settimeout(CONFIG.REDIS_TIMEOUT)
    
    local success, err = socket:connect(redis_master.host, redis_master.port)
    if not success then
        core.log(core.warning, "Failed to connect to Redis master: " .. (err or "unknown error"))
        socket:close()
        return nil
    end
    
    return socket
end

-- Create Redis connection to slave (for reads)
local function create_slave_connection()
    if not CONFIG.USE_REDIS then
        return nil
    end

    if not redis_master then
        core.log(core.warning, "No Redis master available")
        return nil
    end

    -- Try healthy slaves first
    for i, node in ipairs(redis_slaves) do
        local socket = core.tcp()
        if socket then
            socket:settimeout(CONFIG.REDIS_TIMEOUT)
            local success, err = socket:connect(node.host, node.port)
            if success then
                core.log(core.info, "Connected to Redis slave for reads: " .. node.host .. ":" .. node.port)
                return socket
            else
                core.log(core.warning, "Failed to connect to Redis slave " .. i .. ": " .. node.host .. ":" .. node.port .. " - " .. (err or "unknown error"))
                socket:close()
            end
        end
    end

    -- If all slaves failed, use master
    core.log(core.info, "All slaves failed, using master for reads: " .. redis_master.host .. ":" .. redis_master.port)
    local socket = core.tcp()
    if socket then
        socket:settimeout(CONFIG.REDIS_TIMEOUT)
        local success, err = socket:connect(redis_master.host, redis_master.port)
        if success then
            core.log(core.info, "Connected to Redis master for reads: " .. redis_master.host .. ":" .. redis_master.port)
            return socket
        else
            core.log(core.warning, "Failed to connect to Redis master: " .. redis_master.host .. ":" .. redis_master.port .. " - " .. (err or "unknown error"))
            socket:close()
        end
    end

    core.log(core.warning, "Failed to connect to any Redis slave/master for reads")
    return nil
end

-- =============================================================================
-- REDIS DISCOVERY FUNCTIONS
-- =============================================================================

local function discover_redis_nodes()
    local current_time = os.time()
    
    -- If Redis is marked as down and we haven't reached the retry time, skip Redis
    if current_time < redis_down_until then
        redis_available = false
        return false
    end
    
    if current_time - last_discovery < discovery_interval then
        return redis_available
    end
    
    -- Parse the comma-separated list of Redis nodes
    local nodes_str = CONFIG.REDIS_NODES
    local nodes = {}
    for node_info in string.gmatch(nodes_str, "([^,]+)") do
        local host, port_str = node_info:match("([^:]+):([0-9]+)")
        if host and port_str then
            table.insert(nodes, {host = host, port = tonumber(port_str)})
        else
            core.log(core.warning, "Skipping invalid Redis node: " .. node_info)
        end
    end

    if #nodes == 0 then
        core.log(core.warning, "No valid Redis nodes found in REDIS_NODES environment variable.")
        redis_available = false
        redis_down_until = current_time + CONFIG.REDIS_DOWN_TIMEOUT
        return false
    end
    
    local master_found = false
    local slaves_found = {}
    
    -- Try each Redis node to discover master and slaves
    for _, node in ipairs(nodes) do
        local socket = core.tcp()
        if socket then
            socket:settimeout(CONFIG.REDIS_TIMEOUT)
            local success, err = socket:connect(node.host, node.port)
            if success then
                -- Check the role of this node
                local role_info, err = redis_command(socket, {"INFO", "replication"})
                socket:close()
                
                if role_info then
                    -- Parse the role from INFO replication output
                    local role = nil
                    for line in role_info:gmatch("[^\r\n]+") do
                        if line:match("^role:") then
                            role = line:sub(6) -- Remove "role:" prefix
                            break
                        end
                    end
                    
                    if role == "master" then
                        redis_master = {host = node.host, port = node.port}
                        master_found = true
                        core.log(core.info, "Found Redis master: " .. node.host .. ":" .. node.port)
                    elseif role == "slave" then
                        table.insert(slaves_found, {host = node.host, port = node.port})
                        core.log(core.info, "Found Redis slave: " .. node.host .. ":" .. node.port)
                    else
                        core.log(core.warning, "Unknown role '" .. (role or "nil") .. "' for node: " .. node.host .. ":" .. node.port)
                    end
                else
                    core.log(core.warning, "Failed to get role info from " .. node.host .. ":" .. node.port .. " - " .. (err or "unknown error"))
                end
            else
                core.log(core.warning, "Failed to connect to " .. node.host .. ":" .. node.port .. " - " .. (err or "unknown error"))
                socket:close()
            end
        end
    end
    
    redis_slaves = slaves_found
    last_discovery = current_time
    
    -- Test if we can actually connect to Redis
    if master_found then
        local test_socket = create_master_connection()
        if test_socket then
            test_socket:close()
            redis_available = true
            redis_down_until = 0 -- Clear the down cache since Redis is working
            core.log(core.info, "Redis discovery: Master=" .. redis_master.host .. ":" .. redis_master.port .. ", Slaves=" .. #redis_slaves .. " - Redis is AVAILABLE")
        else
            redis_available = false
            redis_down_until = current_time + CONFIG.REDIS_DOWN_TIMEOUT
            core.log(core.warning, "Redis discovery: Master=" .. redis_master.host .. ":" .. redis_master.port .. ", Slaves=" .. #redis_slaves .. " - Redis is UNAVAILABLE, using in-memory storage")
        end
    else
        redis_available = false
        redis_down_until = current_time + CONFIG.REDIS_DOWN_TIMEOUT
        core.log(core.warning, "Redis discovery: No master found, Redis is UNAVAILABLE, using in-memory storage")
    end
    
    return redis_available
end

-- Force Redis discovery (bypass interval)
local function force_redis_discovery()
    local old_interval = discovery_interval
    discovery_interval = 0 -- Force immediate discovery
    local result = discover_redis_nodes()
    discovery_interval = old_interval -- Restore original interval
    return result
end

-- =============================================================================
-- UTILITY FUNCTIONS
-- =============================================================================
local function generate_random_string(length)
    local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local result = {}
    for i = 1, length do
        result[i] = chars:sub(math.random(1, #chars), math.random(1, #chars))
    end
    return table.concat(result)
end

local function generate_uuid()
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return string.gsub(template, "[xy]", function(c)
        local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format("%x", v)
    end)
end

-- =============================================================================
-- UNIFIED STORAGE FUNCTIONS (Redis + In-Memory Fallback)
-- =============================================================================

-- Unified SET function - tries Redis first, falls back to in-memory
local function storage_set(key, value, expiry)
    local current_time = os.time()
    
    -- If Redis is marked as down and we haven't reached the retry time, use in-memory immediately
    if current_time < redis_down_until then
        redis_available = false
    else
        -- Only check Redis availability if not in down cache
        discover_redis_nodes()
    end
    
    -- Debug logging
    core.log(core.info, "Storage SET called for key: " .. key .. ", Redis available: " .. tostring(redis_available))
    
    -- Try Redis first if available
    if CONFIG.USE_REDIS and redis_available then
        local socket = create_master_connection()
        if socket then
            local json_value = json.encode(value)
            local args = {"SET", key, json_value, "EX", expiry}
            local result, err = redis_command(socket, args)
            socket:close()
            
            if result then
                core.log(core.info, "Redis SET successful for key: " .. key)
                return result
            else
                core.log(core.warning, "Redis SET failed for key: " .. key .. " - " .. (err or "unknown error"))
                redis_down_until = current_time + CONFIG.REDIS_DOWN_TIMEOUT
                force_redis_discovery() -- Force discovery if Redis SET fails
            end
        end
    end
    
    -- Fallback to in-memory storage
    if key:find(CONFIG.REDIS_KEY_PREFIX) then
        local challenge_id = key:sub(#CONFIG.REDIS_KEY_PREFIX + 1)
        challenges[challenge_id] = value
        core.log(core.info, "In-memory SET successful for challenge: " .. challenge_id)
    elseif key:find(CONFIG.SESSION_KEY_PREFIX) then
        local session_token = key:sub(#CONFIG.SESSION_KEY_PREFIX + 1)
        sessions[session_token] = value
        core.log(core.info, "In-memory SET successful for session: " .. session_token)
    else
        core.log(core.warning, "Unknown key type for in-memory storage: " .. key)
    end
    
    return "OK"
end

-- Unified GET function - tries Redis first, falls back to in-memory
local function storage_get(key)
    local current_time = os.time()
    
    -- If Redis is marked as down and we haven't reached the retry time, use in-memory immediately
    if current_time < redis_down_until then
        redis_available = false
    else
        -- Only check Redis availability if not in down cache
        discover_redis_nodes()
    end
    
    -- Try Redis first if available
    if CONFIG.USE_REDIS and redis_available then
        local socket = create_slave_connection()
        if socket then
            local result, err = redis_command(socket, {"GET", key})
            socket:close()
            
            if result then
                local success, decoded = pcall(json.decode, result)
                if success then
                    core.log(core.info, "Redis GET successful for key: " .. key)
                    return decoded
                else
                    core.log(core.warning, "Failed to decode Redis value for key: " .. key)
                end
            elseif err then
                core.log(core.warning, "Redis GET failed for key: " .. key .. " - " .. err)
                redis_down_until = current_time + CONFIG.REDIS_DOWN_TIMEOUT
                force_redis_discovery() -- Force discovery if Redis GET fails
            end
        end
    end
    
    -- Fallback to in-memory storage
    if key:find(CONFIG.REDIS_KEY_PREFIX) then
        local challenge_id = key:sub(#CONFIG.REDIS_KEY_PREFIX + 1)
        local value = challenges[challenge_id]
        if value then
            core.log(core.info, "In-memory GET successful for challenge: " .. challenge_id)
            return value
        end
    elseif key:find(CONFIG.SESSION_KEY_PREFIX) then
        local session_token = key:sub(#CONFIG.SESSION_KEY_PREFIX + 1)
        local value = sessions[session_token]
        if value then
            core.log(core.info, "In-memory GET successful for session: " .. session_token)
            return value
        end
    end
    
    return nil
end

-- Unified EXISTS function - tries Redis first, falls back to in-memory
local function storage_exists(key)
    local current_time = os.time()
    
    -- If Redis is marked as down and we haven't reached the retry time, use in-memory immediately
    if current_time < redis_down_until then
        redis_available = false
    else
        -- Only check Redis availability if not in down cache
        discover_redis_nodes()
    end
    
    -- Try Redis first if available
    if CONFIG.USE_REDIS and redis_available then
        local socket = create_slave_connection()
        if socket then
            local result, err = redis_command(socket, {"EXISTS", key})
            socket:close()
            
            if result then
                core.log(core.info, "Redis EXISTS successful for key: " .. key .. " = " .. tostring(result > 0))
                return result > 0
            elseif err then
                core.log(core.warning, "Redis EXISTS failed for key: " .. key .. " - " .. err)
                redis_down_until = current_time + CONFIG.REDIS_DOWN_TIMEOUT
                force_redis_discovery() -- Force discovery if Redis EXISTS fails
            end
        end
    end
    
    -- Fallback to in-memory storage
    if key:find(CONFIG.REDIS_KEY_PREFIX) then
        local challenge_id = key:sub(#CONFIG.REDIS_KEY_PREFIX + 1)
        local exists = challenges[challenge_id] ~= nil
        core.log(core.info, "In-memory EXISTS for challenge: " .. challenge_id .. " = " .. tostring(exists))
        return exists
    elseif key:find(CONFIG.SESSION_KEY_PREFIX) then
        local session_token = key:sub(#CONFIG.SESSION_KEY_PREFIX + 1)
        local exists = sessions[session_token] ~= nil
        core.log(core.info, "In-memory EXISTS for session: " .. session_token .. " = " .. tostring(exists))
        return exists
    end
    
    return false
end

-- Unified DEL function - tries Redis first, falls back to in-memory
local function storage_del(key)
    local current_time = os.time()
    
    -- If Redis is marked as down and we haven't reached the retry time, use in-memory immediately
    if current_time < redis_down_until then
        redis_available = false
    else
        -- Only check Redis availability if not in down cache
        discover_redis_nodes()
    end
    
    -- Try Redis first if available
    if CONFIG.USE_REDIS and redis_available then
        local socket = create_master_connection()
        if socket then
            local result, err = redis_command(socket, {"DEL", key})
            socket:close()
            
            if result then
                core.log(core.info, "Redis DEL successful for key: " .. key)
                return result
            else
                core.log(core.warning, "Redis DEL failed for key: " .. key .. " - " .. (err or "unknown error"))
                redis_down_until = current_time + CONFIG.REDIS_DOWN_TIMEOUT
                force_redis_discovery() -- Force discovery if Redis DEL fails
            end
        end
    end
    
    -- Fallback to in-memory storage
    if key:find(CONFIG.REDIS_KEY_PREFIX) then
        local challenge_id = key:sub(#CONFIG.REDIS_KEY_PREFIX + 1)
        challenges[challenge_id] = nil
        core.log(core.info, "In-memory DEL successful for challenge: " .. challenge_id)
        return 1
    elseif key:find(CONFIG.SESSION_KEY_PREFIX) then
        local session_token = key:sub(#CONFIG.SESSION_KEY_PREFIX + 1)
        sessions[session_token] = nil
        core.log(core.info, "In-memory DEL successful for session: " .. session_token)
        return 1
    end
    
    return 0
end

-- =============================================================================
-- IN-MEMORY STORAGE (Fallback)
-- =============================================================================

local function cleanup_expired()
    local current_time = os.time()
    
    -- Clean up expired challenges
    for id, challenge in pairs(challenges) do
        if current_time > challenge.expires then
            challenges[id] = nil
        end
    end
    
    -- Clean up expired sessions
    for token, session in pairs(sessions) do
        if current_time > session.expires then
            sessions[token] = nil
        end
    end
end

-- =============================================================================
-- CHALLENGE MANAGEMENT
-- =============================================================================
local function generate_challenge()
    local challenge_id = generate_uuid()
    local timestamp = os.time()
    local nonce = generate_random_string(32)
    
    local challenge = {
        id = challenge_id,
        timestamp = timestamp,
        nonce = nonce,
        difficulty = CONFIG.DIFFICULTY,
        expires = timestamp + CONFIG.CHALLENGE_EXPIRY
    }
    
    -- Store using unified storage (Redis + in-memory fallback)
    local redis_key = CONFIG.REDIS_KEY_PREFIX .. challenge_id
    storage_set(redis_key, challenge, CONFIG.CHALLENGE_EXPIRY)
    
    core.log(core.info, "Challenge generated: " .. challenge_id)
    
    return {
        id = challenge_id,
        nonce = nonce,
        difficulty = CONFIG.DIFFICULTY,
        timestamp = timestamp
    }
end

local function get_challenge(challenge_id)
    if not challenge_id then
        return nil
    end
    
    local redis_key = CONFIG.REDIS_KEY_PREFIX .. challenge_id
    return storage_get(redis_key)
end

local function delete_challenge(challenge_id)
    if not challenge_id then
        return
    end
    
    local redis_key = CONFIG.REDIS_KEY_PREFIX .. challenge_id
    storage_del(redis_key)
end

local function verify_proof_of_work(challenge_id, solution)
    if not challenge_id or not solution then
        return {valid = false, error = "Missing challenge ID or solution"}
    end
    
    local challenge = get_challenge(challenge_id)
    if not challenge then
        return {valid = false, error = "Challenge not found or expired"}
    end
    
    local current_time = os.time()
    if current_time > challenge.expires then
        delete_challenge(challenge_id) -- Clean up expired challenge
        return {valid = false, error = "Challenge expired"}
    end
    
    -- Validate solution format
    local solution_num = tonumber(solution)
    if not solution_num or solution_num < 0 then
        return {valid = false, error = "Invalid solution format - must be a positive number"}
    end
    
    -- For demo purposes, accept any reasonable solution
    -- In production, you would verify the actual SHA256 hash
    local is_valid = solution_num > 0 and solution_num < 1000000 -- Reasonable range
    
    if is_valid then
        delete_challenge(challenge_id) -- Clean up challenge after successful validation
        core.log(core.info, "Challenge validated successfully: " .. challenge_id)
    end
    
    return {
        valid = is_valid,
        hash = "demo_hash_" .. solution_num,
        expected_prefix = string.rep("0", challenge.difficulty),
        input = challenge.id .. challenge.nonce .. tostring(solution_num),
        solution = solution_num,
        error = is_valid and nil or "Invalid solution - must be a positive number less than 1,000,000"
    }
end

-- =============================================================================
-- SESSION MANAGEMENT
-- =============================================================================
local function create_session()
    local session_token = generate_uuid()
    local current_time = os.time()
    
    local session = {
        token = session_token,
        created = current_time,
        expires = current_time + CONFIG.SESSION_EXPIRY
    }
    
    -- Store using unified storage (Redis + in-memory fallback)
    local redis_key = CONFIG.SESSION_KEY_PREFIX .. session_token
    storage_set(redis_key, session, CONFIG.SESSION_EXPIRY)
    
    core.log(core.info, "Session created: " .. session_token)
    return session_token
end

local function get_session(session_token)
    if not session_token or session_token == "" then
        return nil
    end
    
    local redis_key = CONFIG.SESSION_KEY_PREFIX .. session_token
    return storage_get(redis_key)
end

local function delete_session(session_token)
    if not session_token then
        return
    end
    
    local redis_key = CONFIG.SESSION_KEY_PREFIX .. session_token
    storage_del(redis_key)
end

local function validate_session(session_token)
    if not session_token or session_token == "" then
        return false
    end
    
    local session = get_session(session_token)
    if not session then
        return false
    end
    
    local current_time = os.time()
    if current_time > session.expires then
        delete_session(session_token)
        return false
    end
    
    return true
end

-- =============================================================================
-- HELPER FUNCTIONS FOR SERVICES
-- =============================================================================
local function send_json_response(applet, status, data, headers)
    local json_data = json.encode(data)
    applet:set_status(status)
    applet:add_header("content-type", "application/json")
    applet:add_header("content-length", tostring(#json_data))
    
    if headers then
        for name, value in pairs(headers) do
            applet:add_header(name, value)
        end
    end
    
    applet:start_response()
    applet:send(json_data)
end

local function send_error_response(applet, status, message)
    send_json_response(applet, status, {error = message})
end

-- =============================================================================
-- HAProxy Actions and Services
-- =============================================================================
core.register_action("validate_session_action", { "http-req" }, function(txn)
    local headers = txn.http:req_get_headers()
    local cookies = headers["cookie"] and headers["cookie"][0] or 
                   headers["Cookie"] and headers["Cookie"][0] or ""
    
    local session_token = string.match(cookies, "js_challenge_session=([^;]*)")
    local is_valid = validate_session(session_token)
    
    txn:set_var("req.session_valid", is_valid and "1" or "0")
end)

core.register_service("serve_challenge_page", "http", function(applet)
    local file = io.open(CONFIG.CHALLENGE_PAGE_PATH, "r")
    
    if not file then
        send_error_response(applet, 500, "Challenge page not found")
        return
    end
    
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
end)

core.register_service("api_service", "http", function(applet)
    local method = applet.method
    local path = applet.path
    
    -- Initialize random seed once per request
    math.randomseed(os.time() + os.clock() * 1000)
    
    -- Clean up expired data
    cleanup_expired()
    
    -- Route handling
    if path == "/api/challenge" and method == "GET" then
        local challenge = generate_challenge()
        if not challenge then
            send_error_response(applet, 500, "Failed to generate challenge")
            return
        end
        
        send_json_response(applet, 200, challenge)
        return
    end
    
    if path == "/api/validate" and method == "POST" then
        local body = applet:receive()
        if not body or body == "" then
            send_error_response(applet, 400, "Missing request body")
            return
        end
        
        local data = json.decode(body)
        if not data or not data.challengeId or not data.solution then
            send_error_response(applet, 400, "Missing challengeId or solution")
            return
        end
        
        -- Add debug logging
        local debug_info = {
            challengeId = data.challengeId,
            solution = data.solution,
            solutionType = type(data.solution),
            timestamp = os.time()
        }
        
        local result = verify_proof_of_work(data.challengeId, data.solution)
        
        if result.valid then
            local session_token = create_session()
            if not session_token then
                send_error_response(applet, 500, "Failed to create session")
                return
            end
            
            local cookie = string.format("js_challenge_session=%s; HttpOnly; SameSite=Strict; Max-Age=%d; Path=/", 
                                       session_token, CONFIG.SESSION_EXPIRY)
            
            send_json_response(applet, 200, {
                success = true,
                message = "Challenge completed successfully",
                redirect = "/"
            }, {["Set-Cookie"] = cookie})
        else
            send_json_response(applet, 400, {
                success = false,
                error = result.error or "Invalid solution",
                debug = debug_info,
                result = result
            })
        end
        return
    end
    
    if path == "/api/health" and method == "GET" then
        local challenge_count = 0
        local session_count = 0
        local storage_type = "in-memory"
        
        if CONFIG.USE_REDIS then
            storage_type = "redis"
            -- Count challenges in Redis (approximate)
            local redis_challenge_pattern = CONFIG.REDIS_KEY_PREFIX .. "*"
            local redis_session_pattern = CONFIG.SESSION_KEY_PREFIX .. "*"
            
            -- For now, we'll count in-memory as fallback
            for _ in pairs(challenges) do
                challenge_count = challenge_count + 1
            end
            
            for _ in pairs(sessions) do
                session_count = session_count + 1
            end
        else
            -- Count in-memory
            for _ in pairs(challenges) do
                challenge_count = challenge_count + 1
            end
            
            for _ in pairs(sessions) do
                session_count = session_count + 1
            end
        end
        
        send_json_response(applet, 200, {
            status = "ok",
            storage = storage_type,
            challenges = challenge_count,
            sessions = session_count,
            redis_connected = CONFIG.USE_REDIS and (redis_master ~= nil),
            config = {
                difficulty = CONFIG.DIFFICULTY,
                challenge_expiry = CONFIG.CHALLENGE_EXPIRY,
                session_expiry = CONFIG.SESSION_EXPIRY,
                use_redis = CONFIG.USE_REDIS,
                redis_sentinel_host = CONFIG.REDIS_SENTINEL_HOST,
                redis_sentinel_port = CONFIG.REDIS_SENTINEL_PORT,
                redis_master_name = CONFIG.REDIS_MASTER_NAME
            }
        })
        return
    end
    
    -- Default response
    send_error_response(applet, 404, "Endpoint not found")
end) 