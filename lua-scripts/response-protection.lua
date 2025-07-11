-- Response Protection System for HAProxy
-- Injects browser inspect protection into all HTML responses

local json = require("json")

-- Configuration
local PROTECTION_ENABLED = true
local DEBUG_MODE = false

-- Function to log injection events
local function log_injection(client_ip, path, content_length)
    if DEBUG_MODE then
        core.log(core.info, string.format(
            "PROTECTION_INJECTED: IP=%s, Path=%s, Content-Length=%s",
            client_ip or "unknown",
            path or "unknown",
            content_length or "unknown"
        ))
    end
end

-- Function to inject protection JavaScript
local function get_protection_js()
    return [[
<script>
(function() {
    'use strict';
    
    // Allow right-click but detect devtools
    document.addEventListener('contextmenu', function(e) {
        // Allow normal right-click, but check for devtools
        const threshold = 160;
        const widthThreshold = window.outerWidth - window.innerWidth > threshold;
        const heightThreshold = window.outerHeight - window.innerHeight > threshold;
        
        if (widthThreshold || heightThreshold) {
            e.preventDefault();
            return false;
        }
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
    
    // Allow text selection but detect devtools
    document.addEventListener('selectstart', function(e) {
        // Allow normal text selection, but check for devtools
        const threshold = 160;
        const widthThreshold = window.outerWidth - window.innerWidth > threshold;
        const heightThreshold = window.outerHeight - window.innerHeight > threshold;
        
        if (widthThreshold || heightThreshold) {
            e.preventDefault();
            return false;
        }
    });
    
    // Allow drag and drop but detect devtools
    document.addEventListener('dragstart', function(e) {
        // Allow normal drag and drop, but check for devtools
        const threshold = 160;
        const widthThreshold = window.outerWidth - window.innerWidth > threshold;
        const heightThreshold = window.outerHeight - window.innerHeight > threshold;
        
        if (widthThreshold || heightThreshold) {
            e.preventDefault();
            return false;
        }
    });
    
})();
</script>
]]
end

-- Function to inject protection CSS
local function get_protection_css()
    return [[
<style>
/* Allow text selection but disable in devtools */
* {
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

/* Allow image interaction but disable in devtools */
img {
    pointer-events: auto;
}
</style>
]]
end

-- Function to inject protection into HTML content
local function inject_protection_into_html(content)
    if not content or type(content) ~= "string" then
        return content
    end
    
    local protection_js = get_protection_js()
    local protection_css = get_protection_css()
    
    -- Inject CSS into head
    local head_end = string.find(content, "</head>")
    if head_end then
        content = string.sub(content, 1, head_end - 1) .. protection_css .. string.sub(content, head_end)
    end
    
    -- Inject JavaScript before closing body tag
    local body_end = string.find(content, "</body>")
    if body_end then
        content = string.sub(content, 1, body_end - 1) .. protection_js .. string.sub(content, body_end)
    else
        -- If no body tag, inject at the end
        content = content .. protection_js
    end
    
    return content
end

-- Response modification service
core.register_service("inject_protection", "http", function(applet)
    local method = applet.method
    local path = applet.path
    
    -- Only process GET requests
    if method ~= "GET" then
        applet:set_status(405)
        applet:add_header("Content-Type", "text/plain")
        applet:add_header("Content-Length", "15")
        applet:start_response()
        applet:send("Method not allowed")
        return
    end
    
    -- Forward the request to the backend
    local backend = core.tcp()
    local ok, err = backend:connect("127.0.0.1", 8080)
    if not ok then
        applet:set_status(502)
        applet:add_header("Content-Type", "text/plain")
        applet:add_header("Content-Length", "19")
        applet:start_response()
        applet:send("Backend unavailable")
        return
    end
    
    -- Send request to backend
    local request = string.format("GET %s HTTP/1.1\r\nHost: localhost:8080\r\nConnection: close\r\n\r\n", path)
    backend:send(request)
    
    -- Read response from backend
    local response = backend:receive()
    if not response then
        backend:close()
        applet:set_status(502)
        applet:add_header("Content-Type", "text/plain")
        applet:add_header("Content-Length", "19")
        applet:start_response()
        applet:send("Backend error")
        return
    end
    
    -- Parse status line
    local status_code = response:match("HTTP/%d+%.%d+ (%d+)")
    if not status_code then
        backend:close()
        applet:set_status(502)
        applet:add_header("Content-Type", "text/plain")
        applet:add_header("Content-Length", "19")
        applet:start_response()
        applet:send("Invalid response")
        return
    end
    
    -- Read headers
    local headers = {}
    local content_length = 0
    local content_type = ""
    
    while true do
        local line = backend:receive()
        if not line or line == "" then
            break
        end
        
        local name, value = line:match("^([^:]+):%s*(.+)")
        if name and value then
            name = string.lower(name)
            headers[name] = value
            
            if name == "content-length" then
                content_length = tonumber(value) or 0
            elseif name == "content-type" then
                content_type = value
            end
        end
    end
    
    -- Read body
    local body = ""
    if content_length > 0 then
        body = backend:receive(content_length)
    else
        -- Read until connection closes
        while true do
            local chunk = backend:receive()
            if not chunk then
                break
            end
            body = body .. chunk
        end
    end
    
    backend:close()
    
    -- Check if this is HTML content that needs protection
    local is_html = content_type:find("text/html") or path:match("%.html?$")
    
    if is_html and PROTECTION_ENABLED then
        -- Inject protection into HTML
        local protected_body = inject_protection_into_html(body)
        local new_content_length = #protected_body
        
        -- Update content length header
        headers["content-length"] = tostring(new_content_length)
        
        -- Log the injection
        log_injection("unknown", path, new_content_length)
        
        -- Send modified response
        applet:set_status(tonumber(status_code))
        
        -- Add all headers
        for name, value in pairs(headers) do
            applet:add_header(name, value)
        end
        
        applet:start_response()
        applet:send(protected_body)
    else
        -- Send original response without modification
        applet:set_status(tonumber(status_code))
        
        -- Add all headers
        for name, value in pairs(headers) do
            applet:add_header(name, value)
        end
        
        applet:start_response()
        applet:send(body)
    end
end)

-- Export functions for use in other scripts
return {
    inject_protection_into_html = inject_protection_into_html,
    get_protection_js = get_protection_js,
    get_protection_css = get_protection_css
} 