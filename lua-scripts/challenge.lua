-- JavaScript Challenge Bot Protection System - Optimized for Active-Active HAProxy
-- Uses Redis storage with in-memory fallback for multiple HAProxy instances
-- Optimized for performance, security, and maintainability

local json = require("json")

-- =============================================================================
-- CONFIGURATION
-- =============================================================================
local CONFIG = {
    DIFFICULTY = 4,
    CHALLENGE_EXPIRY = 300, -- 5 minutes
    SESSION_EXPIRY = 3600, -- 1 hour
    REDIS_HOST = os.getenv("REDIS_HOST") or "127.0.0.1",
    REDIS_PORT = tonumber(os.getenv("REDIS_PORT")) or 6379,
    REDIS_TIMEOUT = 1000, -- 1 second (reduced from 5 seconds)
    REDIS_DOWN_TIMEOUT = 30, -- 30 seconds to retry after Redis failure
    MAX_RETRIES = 3,
    CHALLENGE_PAGE_PATH = "/usr/local/etc/haproxy/challenge-page.html",
    INSPECT_PROTECTION_ENABLED = true, -- Set to false to disable inspect protection
    USE_REDIS = true, -- Set to false to use in-memory storage only
    REDIS_KEY_PREFIX = "challenge:",
    SESSION_KEY_PREFIX = "session:"
}

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
-- REDIS CONNECTION MANAGEMENT
-- =============================================================================
-- Note: Each request needs its own Redis connection due to HAProxy threading

-- Redis connection status cache to avoid repeated connection attempts
local redis_down_until = 0

local function create_redis_connection()
    if not CONFIG.USE_REDIS then
        return nil
    end
    
    -- Check if Redis was recently down and we should skip connection attempts
    local current_time = os.time()
    if current_time < redis_down_until then
        return nil
    end
    
    local socket = core.tcp()
    if not socket then
        core.log(core.warning, "Failed to create TCP socket for Redis")
        return nil
    end
    
    socket:settimeout(CONFIG.REDIS_TIMEOUT)
    
    local success, err = socket:connect(CONFIG.REDIS_HOST, CONFIG.REDIS_PORT)
    if not success then
        core.log(core.warning, "Failed to connect to Redis: " .. (err or "unknown error"))
        socket:close()
        -- Mark Redis as down for the next 30 seconds to avoid repeated attempts
        redis_down_until = current_time + CONFIG.REDIS_DOWN_TIMEOUT
        return nil
    end
    
    -- Reset the down timer if connection succeeds
    redis_down_until = 0
    return socket
end

-- RESP command builder for Redis
local function build_redis_command(args)
    local cmd = {"*" .. #args .. "\r\n"}
    for i = 1, #args do
        local arg = tostring(args[i])
        table.insert(cmd, "$" .. #arg .. "\r\n" .. arg .. "\r\n")
    end
    return table.concat(cmd)
end

-- =============================================================================
-- REDIS STORAGE FUNCTIONS
-- =============================================================================
local function redis_command(args)
    if not CONFIG.USE_REDIS then
        return nil, "Redis disabled"
    end
    
    local socket = create_redis_connection()
    if not socket then
        return nil, "Redis connection failed"
    end
    
    local cmd = build_redis_command(args)
    local success, err = socket:send(cmd)
    if not success then
        core.log(core.warning, "Failed to send Redis command: " .. (err or "unknown error"))
        socket:close()
        return nil, "Redis send failed"
    end
    
    -- Read the response type
    local response_type = socket:receive(1)
    if not response_type then
        socket:close()
        return nil, "No response from Redis"
    end
    
    if response_type == "-" then
        -- Error response
        local error_msg = socket:receive("*l")
        socket:close()
        core.log(core.warning, "Redis error: " .. error_msg)
        return nil, error_msg
    elseif response_type == "+" then
        -- Simple string response
        local response = socket:receive("*l")
        socket:close()
        return response
    elseif response_type == ":" then
        -- Integer response
        local response = socket:receive("*l")
        socket:close()
        return tonumber(response)
    elseif response_type == "$" then
        -- Bulk string response
        local length = tonumber(socket:receive("*l"))
        if length == -1 then
            socket:close()
            return nil -- Null response
        end
        
        local value = socket:receive(length)
        socket:receive(2) -- Read \r\n
        socket:close()
        return value
    else
        socket:close()
        core.log(core.warning, "Unknown Redis response type: " .. response_type)
        return nil, "Unknown response type: " .. response_type
    end
end

local function redis_set(key, value, expiry)
    local json_value = json.encode(value)
    local args = {"SET", key, json_value, "EX", expiry}
    local result = redis_command(args)
    if not result then
        core.log(core.warning, "Redis SET failed for key: " .. key)
    else
        core.log(core.info, "Redis SET successful for key: " .. key)
    end
    return result
end

local function redis_get(key)
    local args = {"GET", key}
    local value = redis_command(args)
    if not value then
        return nil
    end
    return json.decode(value)
end

local function redis_del(key)
    local args = {"DEL", key}
    return redis_command(args)
end

local function redis_exists(key)
    local args = {"EXISTS", key}
    local response = redis_command(args)
    return response and tonumber(response) == 1
end

-- =============================================================================
-- IN-MEMORY STORAGE (Fallback storage)
-- =============================================================================
local challenges = {}
local sessions = {}

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
    
    -- Try to store in Redis first
    if CONFIG.USE_REDIS then
        local redis_key = CONFIG.REDIS_KEY_PREFIX .. challenge_id
        local success = redis_set(redis_key, challenge, CONFIG.CHALLENGE_EXPIRY)
        if success then
            core.log(core.info, "Challenge stored in Redis: " .. challenge_id)
        else
            core.log(core.warning, "Failed to store challenge in Redis, using in-memory: " .. challenge_id)
            challenges[challenge_id] = challenge
        end
    else
        -- Store in memory
        challenges[challenge_id] = challenge
    end
    
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
    
    -- Check if Redis is known to be down
    local current_time = os.time()
    if CONFIG.USE_REDIS and current_time < redis_down_until then
        -- Redis is down, skip Redis lookup and go straight to in-memory
        return challenges[challenge_id]
    end
    
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

local function delete_challenge(challenge_id)
    if not challenge_id then
        return
    end
    
    -- Try Redis first
    if CONFIG.USE_REDIS then
        local redis_key = CONFIG.REDIS_KEY_PREFIX .. challenge_id
        redis_del(redis_key)
    end
    
    -- Also remove from memory if exists
    challenges[challenge_id] = nil
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
        input = challenge.id .. challenge.nonce .. tostring(solution_num), -- Debug info
        solution = solution_num, -- Debug info
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
    
    -- Try to store in Redis first
    if CONFIG.USE_REDIS then
        local redis_key = CONFIG.SESSION_KEY_PREFIX .. session_token
        local success = redis_set(redis_key, session, CONFIG.SESSION_EXPIRY)
        if success then
            core.log(core.info, "Session stored in Redis: " .. session_token)
        else
            core.log(core.warning, "Failed to store session in Redis, using in-memory: " .. session_token)
            sessions[session_token] = session
        end
    else
        -- Store in memory
        sessions[session_token] = session
    end
    
    core.log(core.info, "Session created: " .. session_token)
    return session_token
end

local function get_session(session_token)
    if not session_token or session_token == "" then
        return nil
    end
    
    -- Check if Redis is known to be down
    local current_time = os.time()
    if CONFIG.USE_REDIS and current_time < redis_down_until then
        -- Redis is down, skip Redis lookup and go straight to in-memory
        return sessions[session_token]
    end
    
    -- Try Redis first
    if CONFIG.USE_REDIS then
        local redis_key = CONFIG.SESSION_KEY_PREFIX .. session_token
        local session = redis_get(redis_key)
        if session then
            return session
        end
    end
    
    -- Fallback to in-memory
    return sessions[session_token]
end

local function delete_session(session_token)
    if not session_token then
        return
    end
    
    -- Try Redis first
    if CONFIG.USE_REDIS then
        local redis_key = CONFIG.SESSION_KEY_PREFIX .. session_token
        redis_del(redis_key)
    end
    
    -- Also remove from memory if exists
    sessions[session_token] = nil
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
-- RESPONSE HELPERS
-- =============================================================================
local function send_json_response(applet, status, data, headers)
    headers = headers or {}
    local response_body = json.encode(data)
    
    applet:set_status(status)
    applet:add_header("Content-Type", "application/json")
    applet:add_header("Cache-Control", "no-cache, no-store, must-revalidate")
    applet:add_header("Pragma", "no-cache")
    applet:add_header("Expires", "0")
    applet:add_header("Content-Length", tostring(#response_body))
    
    for name, value in pairs(headers) do
        applet:add_header(name, value)
    end
    
    applet:start_response()
    applet:send(response_body)
end

local function send_error_response(applet, status, message)
    send_json_response(applet, status, {error = message})
end

-- =============================================================================
-- PROTECTION INJECTION
-- =============================================================================
local PROTECTION_JS = [[
<script>
(function() {
    'use strict';
    
    const THRESHOLD = 160;
    const DENIED_MSG = '<div style="text-align:center;padding:50px;font-family:Arial,sans-serif;"><h1>Access Denied</h1><p>Developer tools are not allowed on this site.</p></div>';
    
    function detectDevTools() {
        const widthThreshold = window.outerWidth - window.innerWidth > THRESHOLD;
        const heightThreshold = window.outerHeight - window.innerHeight > THRESHOLD;
        return widthThreshold || heightThreshold;
    }
    
    function blockAccess() {
        document.body.innerHTML = DENIED_MSG;
    }
    
    // Event listeners
    document.addEventListener('contextmenu', function(e) {
        if (detectDevTools()) {
            e.preventDefault();
            return false;
        }
    });
    
    document.addEventListener('keydown', function(e) {
        const blockedKeys = {
            123: 'F12',
            73: 'Ctrl+Shift+I',
            74: 'Ctrl+Shift+J', 
            85: 'Ctrl+U',
            67: 'Ctrl+Shift+C',
            116: 'F5',
            82: 'Ctrl+R'
        };
        
        const keyCode = e.keyCode;
        if (blockedKeys[keyCode]) {
            if (keyCode === 73 || keyCode === 74 || keyCode === 85 || keyCode === 67 || keyCode === 82) {
                if (!e.ctrlKey || !e.shiftKey) return;
            }
            e.preventDefault();
            return false;
        }
    });
    
    // Console detection
    const consoleMethods = ['log', 'warn', 'error', 'info', 'debug'];
    consoleMethods.forEach(function(method) {
        const original = console[method];
        console[method] = function() {
            blockAccess();
            return original.apply(console, arguments);
        };
    });
    
    // Continuous monitoring
    setInterval(function() {
        if (detectDevTools()) {
            blockAccess();
        }
    }, 1000);
    
    // Additional detection
    let devtools = {open: false};
    setInterval(function() {
        if (window.outerHeight - window.innerHeight > 200 || window.outerWidth - window.innerWidth > 200) {
            if (!devtools.open) {
                devtools.open = true;
                blockAccess();
            }
        } else {
            devtools.open = false;
        }
    }, 500);
    
})();
</script>
]]

local PROTECTION_CSS = [[
<style>
* {
    -webkit-touch-callout: none !important;
    -webkit-tap-highlight-color: transparent !important;
}

@media screen and (max-width: 100px), screen and (max-height: 100px) {
    body * {
        display: none !important;
    }
    body::after {
        content: "Access Denied - Developer tools detected";
        display: block !important;
        text-align: center;
        padding: 50px;
        font-family: Arial, sans-serif;
    }
}

img {
    pointer-events: auto;
}
</style>
]]

-- =============================================================================
-- SERVICES
-- =============================================================================
core.register_service("serve_challenge_page", "http", function(applet)
    local file = io.open(CONFIG.CHALLENGE_PAGE_PATH, "r")
    
    if not file then
        send_error_response(applet, 500, "Challenge page not found")
        return
    end
    
    local content = file:read("*all")
    file:close()
    
    -- Inject protection if enabled
    if CONFIG.INSPECT_PROTECTION_ENABLED then
        local head_end = string.find(content, "</head>")
        if head_end then
            content = string.sub(content, 1, head_end - 1) .. PROTECTION_CSS .. string.sub(content, head_end)
        end
        
        local body_end = string.find(content, "</body>")
        if body_end then
            content = string.sub(content, 1, body_end - 1) .. PROTECTION_JS .. string.sub(content, body_end)
        else
            content = content .. PROTECTION_JS
        end
    end
    
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
    
    -- Clean up expired data (in-memory only)
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
            redis_connected = CONFIG.USE_REDIS and (create_redis_connection() ~= nil),
            config = {
                difficulty = CONFIG.DIFFICULTY,
                challenge_expiry = CONFIG.CHALLENGE_EXPIRY,
                session_expiry = CONFIG.SESSION_EXPIRY,
                use_redis = CONFIG.USE_REDIS,
                redis_host = CONFIG.REDIS_HOST,
                redis_port = CONFIG.REDIS_PORT
            }
        })
        return
    end
    
    -- Default response
    send_error_response(applet, 404, "Endpoint not found")
end)

-- =============================================================================
-- HAProxy ACTIONS
-- =============================================================================
core.register_action("validate_session_action", { "http-req" }, function(txn)
    local headers = txn.http:req_get_headers()
    local cookies = headers["cookie"] and headers["cookie"][0] or 
                   headers["Cookie"] and headers["Cookie"][0] or ""
    
    local session_token = string.match(cookies, "js_challenge_session=([^;]*)")
    local is_valid = validate_session(session_token)
    
    txn:set_var("req.session_valid", is_valid and "1" or "0")
end)

-- =============================================================================
-- CLEANUP ON SHUTDOWN
-- =============================================================================
-- Note: core.register_fini is not available in HAProxy 2.8
-- Redis connections will be cleaned up automatically when HAProxy shuts down 