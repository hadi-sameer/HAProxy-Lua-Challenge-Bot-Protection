-- Browser Inspect Protection System for HAProxy
-- Blocks developer tools, inspect element, and other debugging attempts

local json = require("json")

-- Configuration
local INSPECT_BLOCK_ENABLED = true
local DEBUG_MODE = false
local INSPECT_BYPASS_SECRET_KEY = "7f3dadc4-b35f-4d1c-a130-ad0ea2ae1ab7"

-- Detection patterns for developer tools
local DEVTOOLS_PATTERNS = {
    "devtools",
    "developer",
    "inspect",
    "debugger",
    "console",
    "firebug",
    "web-inspector",
    "chrome-devtools",
    "safari-web-inspector"
}

-- User agent patterns that indicate developer tools
local DEVTOOLS_USER_AGENTS = {
    "Chrome%-DevTools",
    "Firefox%-DevTools",
    "Safari%-Web%-Inspector",
    "Edge%-DevTools"
}

-- Function to log detection events
local function log_detection(client_ip, user_agent, reason, headers)
    if DEBUG_MODE then
        core.log(core.info, string.format(
            "INSPECT_DETECTION: IP=%s, UA=%s, Reason=%s, Headers=%s",
            client_ip or "unknown",
            user_agent or "unknown",
            reason or "unknown",
            json.encode(headers or {})
        ))
    end
end

-- Function to check for developer tools in headers
local function detect_devtools_headers(headers)
    if not headers then return false end
    
    -- Check for common devtools headers
    local devtools_headers = {
        "x-devtools",
        "x-chrome-devtools",
        "x-firefox-devtools",
        "x-safari-web-inspector",
        "x-debugger",
        "x-inspector"
    }
    
    for _, header_name in ipairs(devtools_headers) do
        if headers[header_name] then
            return true, "devtools_header_" .. header_name
        end
    end
    
    return false
end

-- Function to check user agent for developer tools
local function detect_devtools_user_agent(user_agent)
    if not user_agent then return false end
    
    for _, pattern in ipairs(DEVTOOLS_USER_AGENTS) do
        if string.match(user_agent, pattern) then
            return true, "devtools_user_agent"
        end
    end
    
    return false
end

-- Function to check for suspicious request patterns
local function detect_suspicious_requests(headers, path)
    if not headers then return false end
    
    -- Check for requests to common devtools endpoints
    local suspicious_paths = {
        "/devtools",
        "/debugger",
        "/inspect",
        "/console",
        "/firebug",
        "/web-inspector"
    }
    
    for _, suspicious_path in ipairs(suspicious_paths) do
        if string.find(path or "", suspicious_path, 1, true) then
            return true, "suspicious_path_" .. suspicious_path
        end
    end
    
    -- Check for suspicious query parameters
    if path and string.find(path, "debug=") then
        return true, "debug_parameter"
    end
    
    if path and string.find(path, "inspect=") then
        return true, "inspect_parameter"
    end
    
    return false
end

-- Main inspection protection function
local function inspect_protection_action(txn)
    if not INSPECT_BLOCK_ENABLED then
        txn:set_var("req.inspect_blocked", "0")
        return
    end
    
    local client_ip = txn.sf and txn.sf:src() or "unknown"
    local headers = txn.http and txn.http:req_get_headers() or {}
    local user_agent = headers["user-agent"] and headers["user-agent"][0] or headers["User-Agent"] and headers["User-Agent"][0] or nil
    local path = txn.sn and txn.sn:req_get_uri() or ""
    
    -- Check for secret key to bypass protection
    local secret_key = headers["js_challenge_secret_key"] and headers["js_challenge_secret_key"][0] or 
                      headers["Js-Challenge-Secret-Key"] and headers["Js-Challenge-Secret-Key"][0] or nil
    
    if secret_key == INSPECT_BYPASS_SECRET_KEY then
        if DEBUG_MODE then
            core.log(core.info, "INSPECT_PROTECTION_BYPASS: Secret key provided, bypassing protection for IP=" .. client_ip)
        end
        txn:set_var("req.inspect_blocked", "0")
        txn:set_var("req.inspect_bypass", "1")
        return
    end
    
    -- Check for developer tools in headers
    local detected, reason = detect_devtools_headers(headers)
    if detected then
        log_detection(client_ip, user_agent, reason, headers)
        txn:set_var("req.inspect_blocked", "1")
        return
    end
    
    -- Check user agent for developer tools
    detected, reason = detect_devtools_user_agent(user_agent)
    if detected then
        log_detection(client_ip, user_agent, reason, headers)
        txn:set_var("req.inspect_blocked", "1")
        return
    end
    
    -- Check for suspicious requests
    detected, reason = detect_suspicious_requests(headers, path)
    if detected then
        log_detection(client_ip, user_agent, reason, headers)
        txn:set_var("req.inspect_blocked", "1")
        return
    end
    
    txn:set_var("req.inspect_blocked", "0")
end

-- Register the action and fetch method
core.register_action("inspect_protection", { "http-req" }, inspect_protection_action, 0)
core.register_fetches("inspect_protection", function(txn)
    return txn:get_var("req.inspect_blocked") or "0"
end)

-- Function to inject protection JavaScript
local function inject_protection_js()
    return [[
<script>
(function() {
    'use strict';
    
    // Disable right-click context menu
    document.addEventListener('contextmenu', function(e) {
        e.preventDefault();
        return false;
    });
    
    // Disable keyboard shortcuts
    document.addEventListener('keydown', function(e) {
        // F12 key
        if (e.keyCode === 123) {
            e.preventDefault();
            return false;
        }
        
        // Ctrl+Shift+I (Chrome DevTools)
        if (e.ctrlKey && e.shiftKey && e.keyCode === 73) {
            e.preventDefault();
            return false;
        }
        
        // Ctrl+Shift+J (Chrome Console)
        if (e.ctrlKey && e.shiftKey && e.keyCode === 74) {
            e.preventDefault();
            return false;
        }
        
        // Ctrl+U (View Source)
        if (e.ctrlKey && e.keyCode === 85) {
            e.preventDefault();
            return false;
        }
        
        // Ctrl+Shift+C (Chrome Elements)
        if (e.ctrlKey && e.shiftKey && e.keyCode === 67) {
            e.preventDefault();
            return false;
        }
        
        // F5 and Ctrl+R (Refresh)
        if (e.keyCode === 116 || (e.ctrlKey && e.keyCode === 82)) {
            e.preventDefault();
            return false;
        }
    });
    
    // Detect developer tools
    function detectDevTools() {
        const threshold = 160;
        const widthThreshold = window.outerWidth - window.innerWidth > threshold;
        const heightThreshold = window.outerHeight - window.innerHeight > threshold;
        
        if (widthThreshold || heightThreshold) {
            document.body.innerHTML = '<div style="text-align:center;padding:50px;font-family:Arial,sans-serif;"><h1>Access Denied</h1><p>Developer tools are not allowed on this site.</p></div>';
            return true;
        }
        return false;
    }
    
    // Continuous monitoring
    setInterval(detectDevTools, 1000);
    
    // Additional detection methods
    let devtools = {
        open: false,
        orientation: null
    };
    
    setInterval(() => {
        if (window.outerHeight - window.innerHeight > 200 || window.outerWidth - window.innerWidth > 200) {
            if (!devtools.open) {
                devtools.open = true;
                document.body.innerHTML = '<div style="text-align:center;padding:50px;font-family:Arial,sans-serif;"><h1>Access Denied</h1><p>Developer tools detected. Access blocked.</p></div>';
            }
        } else {
            devtools.open = false;
        }
    }, 500);
    
    // Console detection
    const originalLog = console.log;
    const originalWarn = console.warn;
    const originalError = console.error;
    
    console.log = function() {
        document.body.innerHTML = '<div style="text-align:center;padding:50px;font-family:Arial,sans-serif;"><h1>Access Denied</h1><p>Console access is not allowed.</p></div>';
        return originalLog.apply(console, arguments);
    };
    
    console.warn = function() {
        document.body.innerHTML = '<div style="text-align:center;padding:50px;font-family:Arial,sans-serif;"><h1>Access Denied</h1><p>Console access is not allowed.</p></div>';
        return originalWarn.apply(console, arguments);
    };
    
    console.error = function() {
        document.body.innerHTML = '<div style="text-align:center;padding:50px;font-family:Arial,sans-serif;"><h1>Access Denied</h1><p>Console access is not allowed.</p></div>';
        return originalError.apply(console, arguments);
    };
    
    // Disable text selection
    document.addEventListener('selectstart', function(e) {
        e.preventDefault();
        return false;
    });
    
    // Disable drag and drop
    document.addEventListener('dragstart', function(e) {
        e.preventDefault();
        return false;
    });
    
})();
</script>
]]
end

-- Function to inject protection CSS
local function inject_protection_css()
    return [[
<style>
/* Disable text selection */
* {
    -webkit-user-select: none !important;
    -moz-user-select: none !important;
    -ms-user-select: none !important;
    user-select: none !important;
    -webkit-touch-callout: none !important;
    -webkit-tap-highlight-color: transparent !important;
}

/* Hide elements when devtools are open */
@media screen and (max-width: 100px) {
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

/* Additional protection */
body {
    -webkit-touch-callout: none;
    -webkit-user-select: none;
    -khtml-user-select: none;
    -moz-user-select: none;
    -ms-user-select: none;
    user-select: none;
}

/* Disable images drag */
img {
    -webkit-user-drag: none;
    -khtml-user-drag: none;
    -moz-user-drag: none;
    -o-user-drag: none;
    user-drag: none;
    pointer-events: none;
}

/* Hide scrollbars when devtools are open */
@media screen and (max-height: 100px) {
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
</style>
]]
end

-- Register functions for use in HAProxy
core.register_fetches("inspect_protection_js", function()
    return inject_protection_js()
end)

core.register_fetches("inspect_protection_css", function()
    return inject_protection_css()
end)

-- Export the main protection function
return {
    inspect_protection_action = inspect_protection_action,
    inject_protection_js = inject_protection_js,
    inject_protection_css = inject_protection_css
} 