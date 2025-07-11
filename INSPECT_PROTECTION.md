# Browser Inspect Protection System

This HAProxy setup includes comprehensive browser inspect protection to prevent users from accessing developer tools, inspecting elements, or debugging the application.

## Features

### 1. Server-Side Protection (Lua-based)

#### Request Filtering
- **Developer Tools Detection**: Blocks requests with devtools-related headers
- **User Agent Filtering**: Detects and blocks browser developer tools user agents
- **Suspicious Path Blocking**: Blocks requests to common devtools endpoints
- **Query Parameter Filtering**: Blocks requests with debug/inspect parameters

#### Protected Headers
- `x-devtools`
- `x-chrome-devtools`
- `x-firefox-devtools`
- `x-safari-web-inspector`
- `x-debugger`
- `x-inspector`

#### Blocked Paths
- `/devtools`
- `/debugger`
- `/inspect`
- `/console`
- `/firebug`
- `/web-inspector`

### 2. Client-Side Protection (JavaScript)

#### Keyboard Shortcut Blocking
- **F12**: Developer Tools
- **Ctrl+Shift+I**: Chrome DevTools
- **Ctrl+Shift+J**: Chrome Console
- **Ctrl+U**: View Source
- **Ctrl+Shift+C**: Chrome Elements Inspector
- **F5/Ctrl+R**: Page Refresh

#### Context Menu Protection
- Disables right-click context menu
- Prevents "Inspect Element" access

#### Developer Tools Detection
- **Window Size Monitoring**: Detects when devtools panel is opened
- **Continuous Monitoring**: Checks every 500ms for devtools
- **Threshold Detection**: Uses 160px threshold for detection

#### Console Protection
- **Console Method Override**: Blocks `console.log`, `console.warn`, `console.error`
- **Access Denied Response**: Shows blocking message when console is accessed

#### Text Selection Prevention
- Disables text selection across the entire page
- Prevents copying of content

#### Drag and Drop Protection
- Disables drag and drop functionality
- Prevents image dragging

### 3. CSS-based Protection

#### User Selection Prevention
```css
* {
    -webkit-user-select: none !important;
    -moz-user-select: none !important;
    -ms-user-select: none !important;
    user-select: none !important;
}
```

#### DevTools Detection via Media Queries
```css
@media screen and (max-width: 100px) {
    body * { display: none !important; }
    body::after {
        content: "Access Denied - Developer tools detected";
        display: block !important;
    }
}
```

#### Image Protection
```css
img {
    -webkit-user-drag: none;
    pointer-events: none;
}
```

### 4. Security Headers

#### Content Security Policy
```
X-Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline' cdnjs.cloudflare.com; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self';
```

#### Permissions Policy
```
Permissions-Policy: geolocation=(), microphone=(), camera=(), payment=(), usb=(), magnetometer=(), gyroscope=(), accelerometer=()
```

## Implementation Details

### Files Modified/Created

1. **`lua-scripts/inspect-protection.lua`**: Main protection logic
2. **`challenge-page.html`**: Protected challenge page
3. **`haproxy.cfg`**: Updated configuration
4. **`Dockerfile`**: Added challenge page file

### Protection Layers

1. **Network Level**: HAProxy blocks suspicious requests
2. **Application Level**: Lua scripts provide server-side protection
3. **Client Level**: JavaScript and CSS provide client-side protection
4. **Header Level**: Security headers prevent various attacks

## Configuration

### Enable/Disable Protection
In `lua-scripts/inspect-protection.lua`:
```lua
local INSPECT_BLOCK_ENABLED = true  -- Set to false to disable
local DEBUG_MODE = false           -- Set to true for logging
```

### Customize Detection Thresholds
```lua
-- Window size threshold for devtools detection
const threshold = 160;  // pixels

-- Monitoring intervals
setInterval(detectDevTools, 1000);  // 1 second
setInterval(devtoolsCheck, 500);    // 500ms
```

## Testing the Protection

### Test Cases

1. **F12 Key**: Should be blocked
2. **Right-click**: Context menu should be disabled
3. **Ctrl+Shift+I**: Should be blocked
4. **View Source**: Should be blocked
5. **Console Access**: Should show blocking message
6. **Text Selection**: Should be disabled
7. **DevTools Panel**: Should trigger detection

### Bypass Attempts

The system is designed to prevent common bypass attempts:
- **Keyboard shortcuts**: All major devtools shortcuts blocked
- **Context menu**: Right-click disabled
- **Console access**: Overridden with blocking
- **Window resizing**: Detected and blocked
- **Network requests**: Filtered at HAProxy level

## Limitations

1. **Advanced Users**: Experienced developers may find ways around client-side protection
2. **Browser Extensions**: Some browser extensions might bypass certain protections
3. **Mobile Devices**: Some protections may not work on mobile browsers
4. **Accessibility**: Some protections may interfere with accessibility tools

## Best Practices

1. **Multi-layered Approach**: Use both server-side and client-side protection
2. **Regular Updates**: Keep protection mechanisms updated
3. **Monitoring**: Enable debug logging to monitor attempts
4. **User Experience**: Ensure legitimate users aren't blocked
5. **Testing**: Regularly test protection mechanisms

## Troubleshooting

### Common Issues

1. **False Positives**: Adjust detection thresholds
2. **Performance Impact**: Reduce monitoring frequency
3. **Accessibility Issues**: Disable certain protections for accessibility users
4. **Mobile Issues**: Test on mobile devices

### Debug Mode

Enable debug logging:
```lua
local DEBUG_MODE = true
```

This will log detection events to HAProxy logs.

## Security Considerations

1. **Client-side Only**: Client-side protection can be bypassed
2. **Server-side Critical**: Server-side protection is more reliable
3. **Defense in Depth**: Use multiple protection layers
4. **Regular Updates**: Keep protection mechanisms current
5. **Monitoring**: Monitor for bypass attempts

## Conclusion

This browser inspect protection system provides comprehensive protection against common developer tools access while maintaining usability for legitimate users. The multi-layered approach ensures that even if one layer is bypassed, others remain active. 