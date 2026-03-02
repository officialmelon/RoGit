--[[
This will handle all git protos.
Im going to kms (/j)
]]

local proto = {}

--// Quick utilities

local function getHexValue(b: number)
    if b >= 48 and b <= 57 then return b - 48 end
    if b >= 65 and b <= 70 then return (b - 65) + 10 end
    if b >= 97 and b <= 102 then return (b - 97) + 10 end
    return 0
end

local function numToHex(n: number)
    if n < 10 then
        return n + 48
    else
        return n + 87
    end
end

--// Converts 4 hex bytes to a number
local function convertHexByteToNumber(buf: buffer, cursor: number)
    local b1 = getHexValue(buffer.readu8(buf, cursor))
    local b2 = getHexValue(buffer.readu8(buf, cursor + 1))
    local b3 = getHexValue(buffer.readu8(buf, cursor + 2))
    local b4 = getHexValue(buffer.readu8(buf, cursor + 3))
    return bit32.bor(bit32.lshift(b1, 12), bit32.lshift(b2, 8), bit32.lshift(b3, 4), b4)
end

--// opposite
local function convertNumberToHexByte(n: number)
    local d1 = numToHex(bit32.band(bit32.rshift(n, 12), 0xF))
    local d2 = numToHex(bit32.band(bit32.rshift(n, 8), 0xF))
    local d3 = numToHex(bit32.band(bit32.rshift(n, 4), 0xF))
    local d4 = numToHex(bit32.band(n, 0xF))
    return d1, d2, d3, d4
end

local function readU32BE(b, c)
    return bit32.bor(
        bit32.lshift(buffer.readu8(b, c), 24),
        bit32.lshift(buffer.readu8(b, c + 1), 16),
        bit32.lshift(buffer.readu8(b, c + 2), 8),
        buffer.readu8(b, c + 3)
    )
end

local function readDeltaVariant(s: string, pos: number)
    local b = string.byte(s, pos)
    pos += 1

    local size = bit32.band(b, 0x7F)
    local shift = 7

    while bit32.band(b, 0x80) ~= 0 do
        b = string.byte(s, pos)
        pos += 1
        size = bit32.bor(size, bit32.lshift(bit32.band(b, 0x7F), shift))
        shift += 7
    end

    return size, pos
end

function proto.writeU32BE(n)
    return string.char(
        bit32.band(bit32.rshift(n,24), 0xFF),
        bit32.band(bit32.rshift(n,16), 0xFF),
        bit32.band(bit32.rshift(n,8), 0xFF),
        bit32.band(n, 0xFF)
    )
end

function proto.decodePkt(buf: buffer, cursor: number)
    
    local l = convertHexByteToNumber(buf,cursor)

    -- Handle flush packet
    if l == 0 then
        return nil, cursor + 4
    end

    local dataS = l - 4
    local data = buffer.create(dataS)

    buffer.copy(data, 0, buf, cursor+4, dataS)

    return data, cursor + l
end

function proto.encodePkt(data: buffer)

    local dataL = buffer.len(data)
    local totalL = dataL + 4
    local buf = buffer.create(totalL)

    local d1, d2, d3, d4 = convertNumberToHexByte(totalL)

    buffer.writeu8(buf, 0, d1)
    buffer.writeu8(buf, 1, d2)
    buffer.writeu8(buf, 2, d3)
    buffer.writeu8(buf, 3, d4)

    buffer.copy(buf, 4, data, 0, dataL)
    
    return buf
end

function proto.parseRef(data: buffer)

    local s= buffer.tostring(data)

    -- Ignore service thingo (# service=git-...)
    if string.sub(s, 1, 1) == "#" then
        return nil
    end

    -- bye newlines
    s = s:gsub("\n", "")

    local sha = string.sub(s, 1, 40)

    local info = string.sub(s, 42)

    local nullIndex = string.find(info, "\0", 1, true)
    local name, caps

    if nullIndex then
        name = string.sub(info, 1, nullIndex - 1)
        caps = string.sub(info, nullIndex + 1)
    else
        name = info
    end

    return sha, name, caps
end

function proto.flush()
    return buffer.fromstring("0000")
end

-- Packfile

function proto.parsePackHeader(buf: buffer, cursor: number)
    local isPack = 
        buffer.readi8(buf, cursor) == 80 and -- P 
        buffer.readi8(buf, cursor + 1) == 65 and -- A 
        buffer.readi8(buf, cursor + 2) == 67 and -- C 
        buffer.readi8(buf, cursor + 3) == 75 -- K 

    assert(isPack, "Invalid Packfile: Magic number 'PACK' not found at cursor " .. cursor)

    local version = readU32BE(buf, cursor + 4)
    local objCount = readU32BE(buf, cursor + 8)

    return version, objCount, cursor + 12
end

function proto.parseObjectHeader(buf: buffer, cursor: number)
    local b = buffer.readu8(buf, cursor)
    cursor += 1

    local type = bit32.band(bit32.rshift(b, 4), 7)

    local size = bit32.band(b, 0xF)
    local shift = 4

    while bit32.band(b, 0x80) ~= 0 do
        b = buffer.readu8(buf, cursor)
        cursor += 1
        size = bit32.bor(size, bit32.lshift(bit32.band(b, 0x7F), shift))
        shift += 7
    end

    return type, size, cursor
end

function proto.encodeObjectHeader(objType, size)
    local bytes = {}
    local b = bit32.bor(bit32.lshift(objType, 4), bit32.band(size, 0xF))
    size = bit32.rshift(size, 4)
    
    while size > 0 do
        table.insert(bytes, bit32.bor(b, 0x80))
        b = bit32.band(size, 0x7F)
        size = bit32.rshift(size, 7)
    end
    table.insert(bytes, b)

    return string.char(table.unpack(bytes))
end

function proto.applyDelta(base: string, delta: string)
    local pos = 1
    local result = {}
	local res_index = 1
	local byte = string.byte
	local sub = string.sub
	local band = bit32.band
	local bor = bit32.bor
	local lshift = bit32.lshift

    local _, newPos = readDeltaVariant(delta, pos)
    pos = newPos

    local _, newPos2 = readDeltaVariant(delta, pos)
    pos = newPos2

	local delta_len = #delta

    while pos <= delta_len do
        local cmd = byte(delta, pos)
        pos += 1

        if band(cmd, 0x80) ~= 0 then
            local offset = 0
            local size = 0

            if band(cmd, 0x01) ~= 0 then offset = bor(offset, byte(delta, pos)) pos += 1 end
            if band(cmd, 0x02) ~= 0 then offset = bor(offset, lshift(byte(delta, pos), 8)) pos += 1 end
            if band(cmd, 0x04) ~= 0 then offset = bor(offset, lshift(byte(delta, pos), 16)) pos += 1 end
            if band(cmd, 0x08) ~= 0 then offset = bor(offset, lshift(byte(delta, pos), 24)) pos += 1 end

            if band(cmd, 0x10) ~= 0 then size = bor(size, byte(delta, pos)) pos += 1 end
            if band(cmd, 0x20) ~= 0 then size = bor(size, lshift(byte(delta, pos), 8)) pos += 1 end
            if band(cmd, 0x40) ~= 0 then size = bor(size, lshift(byte(delta, pos), 16)) pos += 1 end

            if size == 0 then size = 0x10000 end

            result[res_index] = sub(base, offset + 1, offset + size)
			res_index += 1
        elseif cmd > 0 then
            result[res_index] = sub(delta, pos, pos + cmd - 1)
			res_index += 1
            pos += cmd
        end
    end

    return table.concat(result)
end

function proto.wrapInPktLines(data)
    local MAX_DATA = 65520
    local parts = {}
    local pos = 1
    local len = #data

    while pos <= len do
        local chunkSize = math.min(MAX_DATA, len - pos + 1)
        local totalSize = chunkSize + 4
        local d1, d2, d3, d4 = convertNumberToHexByte(totalSize)
        table.insert(parts, string.char(d1, d2, d3, d4))
        table.insert(parts, string.sub(data, pos, pos + chunkSize - 1))
        pos = pos + chunkSize
    end

    return table.concat(parts)
end

return proto