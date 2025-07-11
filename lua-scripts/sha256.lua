-- SHA256 implementation for Lua
-- Compatible with CryptoJS SHA256 output
-- Simplified version for HAProxy compatibility

local function band(a, b)
    local result = 0
    local bitval = 1
    for i = 0, 31 do
        if a % 2 == 1 and b % 2 == 1 then
            result = result + bitval
        end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
        bitval = bitval * 2
        if a == 0 and b == 0 then break end
    end
    return result
end

local function bxor(a, b)
    local result = 0
    local bitval = 1
    for i = 0, 31 do
        if a % 2 ~= b % 2 then
            result = result + bitval
        end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
        bitval = bitval * 2
        if a == 0 and b == 0 then break end
    end
    return result
end

local function bnot(a)
    return 4294967295 - a
end

local function rshift(a, b)
    return math.floor(a / 2^b)
end

local function lshift(a, b)
    return (a * 2^b) % 4294967296
end

local function rrotate(x, n)
    return rshift(x, n) + lshift(x, 32 - n)
end

local function choice(x, y, z)
    return bxor(band(x, y), band(bnot(x), z))
end

local function majority(x, y, z)
    return bxor(band(x, y), band(x, z), band(y, z))
end

local function sha256_Sigma0(x)
    return bxor(rrotate(x, 2), rrotate(x, 13), rrotate(x, 22))
end

local function sha256_Sigma1(x)
    return bxor(rrotate(x, 6), rrotate(x, 11), rrotate(x, 25))
end

local function sha256_sigma0(x)
    return bxor(rrotate(x, 7), rrotate(x, 18), rshift(x, 3))
end

local function sha256_sigma1(x)
    return bxor(rrotate(x, 17), rrotate(x, 19), rshift(x, 10))
end

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
}

local function sha256_transform(state, data)
    local a, b, c, d, e, f, g, h = table.unpack(state)
    local w = {}
    
    for i = 1, 16 do
        w[i] = data[i]
    end
    
    for i = 17, 64 do
        w[i] = band(sha256_sigma1(w[i-2]) + w[i-7] + sha256_sigma0(w[i-15]) + w[i-16], 0xffffffff)
    end
    
    for i = 1, 64 do
        local temp1 = band(h + sha256_Sigma1(e) + choice(e, f, g) + K[i] + w[i], 0xffffffff)
        local temp2 = band(sha256_Sigma0(a) + majority(a, b, c), 0xffffffff)
        
        h = g
        g = f
        f = e
        e = band(d + temp1, 0xffffffff)
        d = c
        c = b
        b = a
        a = band(temp1 + temp2, 0xffffffff)
    end
    
    state[1] = band(state[1] + a, 0xffffffff)
    state[2] = band(state[2] + b, 0xffffffff)
    state[3] = band(state[3] + c, 0xffffffff)
    state[4] = band(state[4] + d, 0xffffffff)
    state[5] = band(state[5] + e, 0xffffffff)
    state[6] = band(state[6] + f, 0xffffffff)
    state[7] = band(state[7] + g, 0xffffffff)
    state[8] = band(state[8] + h, 0xffffffff)
end

local function sha256_finalize(state, data, len)
    local padding = {}
    local pad_len = 56 - (len % 64)
    if pad_len <= 0 then pad_len = pad_len + 64 end
    
    padding[1] = 0x80
    for i = 2, pad_len do
        padding[i] = 0
    end
    
    local length_bytes = {}
    local bit_len = len * 8
    for i = 1, 8 do
        length_bytes[i] = band(bit_len, 0xff)
        bit_len = rshift(bit_len, 8)
    end
    
    -- Add padding
    local padded_data = {}
    for i = 1, len do
        padded_data[i] = data[i]
    end
    for i = 1, pad_len do
        padded_data[len + i] = padding[i]
    end
    for i = 1, 8 do
        padded_data[len + pad_len + i] = length_bytes[i]
    end
    
    -- Process blocks
    for i = 1, #padded_data, 64 do
        local block = {}
        for j = 1, 64 do
            block[j] = padded_data[i + j - 1] or 0
        end
        sha256_transform(state, block)
    end
end

local function sha256(str)
    local state = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    }
    
    local data = {}
    for i = 1, #str do
        data[i] = string.byte(str, i)
    end
    
    sha256_finalize(state, data, #str)
    
    local result = ""
    for i = 1, 8 do
        result = result .. string.format("%08x", state[i])
    end
    
    return result
end

return sha256 