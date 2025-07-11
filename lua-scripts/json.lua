-- Simple JSON encoder/decoder for HAProxy Lua
-- Lightweight implementation for basic JSON operations

local json = {}

-- Escape special characters in strings
local function escape_string(str)
    if type(str) ~= "string" then
        return str
    end
    
    local escape_map = {
        ["\""] = "\\\"",
        ["\\"] = "\\\\",
        ["/"] = "\\/",
        ["\b"] = "\\b",
        ["\f"] = "\\f",
        ["\n"] = "\\n",
        ["\r"] = "\\r",
        ["\t"] = "\\t"
    }
    
    return string.gsub(str, "[\"\\\b\f\n\r\t/]", escape_map)
end

-- Encode value to JSON
local function encode_value(value)
    local value_type = type(value)
    
    if value_type == "nil" then
        return "null"
    elseif value_type == "boolean" then
        return value and "true" or "false"
    elseif value_type == "number" then
        return tostring(value)
    elseif value_type == "string" then
        return "\"" .. escape_string(value) .. "\""
    elseif value_type == "table" then
        local is_array = true
        local max_index = 0
        
        -- Check if table is an array
        for k, v in pairs(value) do
            if type(k) ~= "number" or k <= 0 or k ~= math.floor(k) then
                is_array = false
                break
            end
            max_index = math.max(max_index, k)
        end
        
        -- Check for consecutive indices
        if is_array then
            for i = 1, max_index do
                if value[i] == nil then
                    is_array = false
                    break
                end
            end
        end
        
        if is_array then
            -- Encode as array
            local parts = {}
            for i = 1, max_index do
                parts[i] = encode_value(value[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            -- Encode as object
            local parts = {}
            for k, v in pairs(value) do
                local key = encode_value(tostring(k))
                local val = encode_value(v)
                table.insert(parts, key .. ":" .. val)
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    else
        error("Cannot encode value of type " .. value_type)
    end
end

-- Simple JSON decoder (basic implementation)
local function decode_value(str, pos)
    pos = pos or 1
    
    -- Skip whitespace
    while pos <= #str and string.match(string.sub(str, pos, pos), "%s") do
        pos = pos + 1
    end
    
    if pos > #str then
        return nil, pos
    end
    
    local char = string.sub(str, pos, pos)
    
    if char == "{" then
        -- Parse object
        local obj = {}
        pos = pos + 1
        
        -- Skip whitespace
        while pos <= #str and string.match(string.sub(str, pos, pos), "%s") do
            pos = pos + 1
        end
        
        if pos <= #str and string.sub(str, pos, pos) == "}" then
            return obj, pos + 1
        end
        
        while pos <= #str do
            -- Parse key
            local key, new_pos = decode_value(str, pos)
            pos = new_pos
            
            -- Skip whitespace and colon
            while pos <= #str and (string.match(string.sub(str, pos, pos), "%s") or string.sub(str, pos, pos) == ":") do
                pos = pos + 1
            end
            
            -- Parse value
            local value, new_pos = decode_value(str, pos)
            pos = new_pos
            
            obj[key] = value
            
            -- Skip whitespace
            while pos <= #str and string.match(string.sub(str, pos, pos), "%s") do
                pos = pos + 1
            end
            
            if pos <= #str and string.sub(str, pos, pos) == "," then
                pos = pos + 1
            elseif pos <= #str and string.sub(str, pos, pos) == "}" then
                return obj, pos + 1
            else
                break
            end
        end
        
        return obj, pos
        
    elseif char == "[" then
        -- Parse array
        local arr = {}
        pos = pos + 1
        local index = 1
        
        -- Skip whitespace
        while pos <= #str and string.match(string.sub(str, pos, pos), "%s") do
            pos = pos + 1
        end
        
        if pos <= #str and string.sub(str, pos, pos) == "]" then
            return arr, pos + 1
        end
        
        while pos <= #str do
            local value, new_pos = decode_value(str, pos)
            pos = new_pos
            arr[index] = value
            index = index + 1
            
            -- Skip whitespace
            while pos <= #str and string.match(string.sub(str, pos, pos), "%s") do
                pos = pos + 1
            end
            
            if pos <= #str and string.sub(str, pos, pos) == "," then
                pos = pos + 1
            elseif pos <= #str and string.sub(str, pos, pos) == "]" then
                return arr, pos + 1
            else
                break
            end
        end
        
        return arr, pos
        
    elseif char == "\"" then
        -- Parse string
        pos = pos + 1
        local start_pos = pos
        local result = ""
        
        while pos <= #str do
            local c = string.sub(str, pos, pos)
            if c == "\"" then
                return result, pos + 1
            elseif c == "\\" then
                pos = pos + 1
                if pos <= #str then
                    local escape_char = string.sub(str, pos, pos)
                    if escape_char == "n" then
                        result = result .. "\n"
                    elseif escape_char == "r" then
                        result = result .. "\r"
                    elseif escape_char == "t" then
                        result = result .. "\t"
                    elseif escape_char == "b" then
                        result = result .. "\b"
                    elseif escape_char == "f" then
                        result = result .. "\f"
                    else
                        result = result .. escape_char
                    end
                end
            else
                result = result .. c
            end
            pos = pos + 1
        end
        
        return result, pos
        
    elseif char == "t" and string.sub(str, pos, pos + 3) == "true" then
        return true, pos + 4
    elseif char == "f" and string.sub(str, pos, pos + 4) == "false" then
        return false, pos + 5
    elseif char == "n" and string.sub(str, pos, pos + 3) == "null" then
        return nil, pos + 4
    else
        -- Parse number
        local start_pos = pos
        while pos <= #str and string.match(string.sub(str, pos, pos), "[%d%.%-+eE]") do
            pos = pos + 1
        end
        local num_str = string.sub(str, start_pos, pos - 1)
        return tonumber(num_str), pos
    end
end

-- Public API
function json.encode(value)
    return encode_value(value)
end

function json.decode(str)
    if type(str) ~= "string" then
        return nil
    end
    
    local value, pos = decode_value(str, 1)
    return value
end

return json 