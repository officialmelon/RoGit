--[[
Ed25519 signatures in pure Luau (a port of TweetNaCl's sign/verify).

Field elements are 16 limbs of 16 bits stored in doubles (indexes 1..16), products stay well below 2^53.
Scalars/bytes used by modL are 0-indexed tables to match the reference closely.
Not constant time: fine for signing commits on your own machine, not for a server.
]]
local ed25519 = {}

local hashlib = require(script.Parent.hashlib)

local floor = math.floor

local function gf(init)
    local r = table.create(16, 0)
    if init then
        for i = 1, #init do r[i] = init[i] end
    end
    return r
end

local gf0 = gf()
local gf1 = gf({1})
local D = gf({0x78a3, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070, 0xe898, 0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f, 0x6cee, 0x5203})
local D2 = gf({0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0, 0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406})
local X = gf({0xd51a, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c, 0xdc5c, 0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e, 0x36d3, 0x2169})
local Y = gf({0x6658, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666})
local I = gf({0xa0b0, 0x4a0e, 0x1b27, 0xc4ee, 0xe478, 0xad2f, 0x1806, 0x2f43, 0xd7a7, 0x3dfb, 0x0099, 0x2b4d, 0xdf0b, 0x4fc1, 0x2480, 0x2b83})

--// L, the order of the base point, little endian (0-indexed)
local L = {[0] = 0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10}

local function set(r, a)
    for i = 1, 16 do r[i] = a[i] end
end

local function copy(a)
    local r = table.create(16, 0)
    for i = 1, 16 do r[i] = a[i] end
    return r
end

local function car(o)
    local c = 1
    for i = 1, 16 do
        local v = o[i] + c + 65535
        c = floor(v / 65536)
        o[i] = v - c * 65536
    end
    o[1] += c - 1 + 37 * (c - 1)
end

local function swap(p, q, b)
    if b == 1 then
        for i = 1, 16 do
            p[i], q[i] = q[i], p[i]
        end
    end
end

--// field element -> 32 bytes (1-indexed)
local function pack25519(n)
    local m, t = gf(), copy(n)
    car(t)
    car(t)
    car(t)
    for _ = 1, 2 do
        m[1] = t[1] - 0xffed
        for i = 2, 15 do
            m[i] = t[i] - 0xffff - (m[i - 1] < 0 and 1 or 0)
            m[i - 1] = m[i - 1] % 65536
        end
        m[16] = t[16] - 0x7fff - (m[15] < 0 and 1 or 0)
        local b = m[16] < 0 and 1 or 0
        m[15] = m[15] % 65536
        swap(t, m, 1 - b)
    end
    local o = table.create(32, 0)
    for i = 1, 16 do
        o[2 * i - 1] = t[i] % 256
        o[2 * i] = floor(t[i] / 256)
    end
    return o
end

local function neq25519(a, b)
    local c, d = pack25519(a), pack25519(b)
    for i = 1, 32 do
        if c[i] ~= d[i] then return true end
    end
    return false
end

local function par25519(a)
    return pack25519(a)[1] % 2
end

local function unpack25519(bytes)
    local o = gf()
    for i = 1, 16 do
        o[i] = bytes[2 * i - 1] + bytes[2 * i] * 256
    end
    o[16] = o[16] % 32768
    return o
end

local function A(o, a, b)
    for i = 1, 16 do o[i] = a[i] + b[i] end
end

local function Z(o, a, b)
    for i = 1, 16 do o[i] = a[i] - b[i] end
end

local function M(o, a, b)
    local t = table.create(31, 0)
    for i = 1, 16 do
        local ai = a[i]
        if ai ~= 0 then
            for j = 1, 16 do
                t[i + j - 1] += ai * b[j]
            end
        end
    end
    for i = 1, 15 do
        t[i] += 38 * t[i + 16]
    end
    for i = 1, 16 do o[i] = t[i] end
    car(o)
    car(o)
end

local function S(o, a)
    M(o, a, a)
end

local function inv25519(o, i)
    local c = copy(i)
    for a = 253, 0, -1 do
        S(c, c)
        if a ~= 2 and a ~= 4 then M(c, c, i) end
    end
    set(o, c)
end

local function pow2523(o, i)
    local c = copy(i)
    for a = 250, 0, -1 do
        S(c, c)
        if a ~= 1 then M(c, c, i) end
    end
    set(o, c)
end

--// points are {X, Y, Z, T} in extended coordinates
local function add(p, q)
    local a, b, c, d, e, f, g, h, t = gf(), gf(), gf(), gf(), gf(), gf(), gf(), gf(), gf()
    Z(a, p[2], p[1])
    Z(t, q[2], q[1])
    M(a, a, t)
    A(b, p[1], p[2])
    A(t, q[1], q[2])
    M(b, b, t)
    M(c, p[4], q[4])
    M(c, c, D2)
    M(d, p[3], q[3])
    A(d, d, d)
    Z(e, b, a)
    Z(f, d, c)
    A(g, d, c)
    A(h, b, a)
    M(p[1], e, f)
    M(p[2], h, g)
    M(p[3], g, f)
    M(p[4], e, h)
end

local function cswap(p, q, b)
    for i = 1, 4 do swap(p[i], q[i], b) end
end

local function pack(p)
    local tx, ty, zi = gf(), gf(), gf()
    inv25519(zi, p[3])
    M(tx, p[1], zi)
    M(ty, p[2], zi)
    local r = pack25519(ty)
    r[32] += par25519(tx) * 128
    return r
end

--// s: 0-indexed bytes
local function scalarmult(p, q, s)
    set(p[1], gf0)
    set(p[2], gf1)
    set(p[3], gf1)
    set(p[4], gf0)
    for i = 255, 0, -1 do
        local b = floor(s[floor(i / 8)] / 2 ^ (i % 8)) % 2
        cswap(p, q, b)
        add(q, p)
        add(p, p)
        cswap(p, q, b)
    end
end

local function scalarbase(p, s)
    local q = {copy(X), copy(Y), copy(gf1), gf()}
    M(q[4], X, Y)
    scalarmult(p, q, s)
end

local function new_point()
    return {gf(), gf(), gf(), gf()}
end

--// x: 0-indexed table of 64 numbers -> 32 reduced bytes (0-indexed)
local function modL(x)
    for i = 63, 32, -1 do
        local carry = 0
        local j = i - 32
        while j < i - 12 do
            x[j] += carry - 16 * x[i] * L[j - (i - 32)]
            carry = floor((x[j] + 128) / 256)
            x[j] -= carry * 256
            j += 1
        end
        x[j] += carry
        x[i] = 0
    end
    local carry = 0
    for j = 0, 31 do
        x[j] += carry - floor(x[31] / 16) * L[j]
        carry = floor(x[j] / 256)
        x[j] = x[j] % 256
    end
    for j = 0, 31 do
        x[j] -= carry * L[j]
    end
    local r = {}
    for i = 0, 31 do
        x[i + 1] += floor(x[i] / 256)
        r[i] = x[i] % 256
    end
    return r
end

local function bytes0(str)
    local t = {}
    for i = 1, #str do t[i - 1] = string.byte(str, i) end
    return t
end

local function bytes1(str)
    return {string.byte(str, 1, -1)}
end

local function to_string(bytes, zero_based)
    local parts = table.create(32)
    if zero_based then
        for i = 0, 31 do parts[i + 1] = string.char(bytes[i]) end
    else
        for i = 1, #bytes do parts[i] = string.char(bytes[i]) end
    end
    return table.concat(parts)
end

local function sha512(data)
    return hashlib.hex_to_bin(hashlib.sha512(data))
end

local function reduce(hash64)
    local x = bytes0(hash64)
    for i = #hash64, 63 do x[i] = 0 end
    return modL(x)
end

--[[
Expands a 32 byte seed into the clamped secret scalar (0-indexed bytes) and the 32 byte public key.
]]
local function expand(seed)
    assert(#seed == 32, "ed25519 seed must be 32 bytes")
    local d = bytes0(sha512(seed))
    d[0] -= d[0] % 8
    d[31] = d[31] % 128
    if d[31] < 64 then d[31] += 64 end
    local p = new_point()
    scalarbase(p, d)
    return d, to_string(pack(p))
end

function ed25519.public_key(seed)
    local _, pk = expand(seed)
    return pk
end

--[[
Signs a message with a 32 byte seed. Returns the 64 byte signature.
]]
function ed25519.sign(seed, message)
    local d, pk = expand(seed)
    local prefix = {}
    for i = 32, 63 do prefix[#prefix + 1] = string.char(d[i]) end

    local r = reduce(sha512(table.concat(prefix) .. message))
    local p = new_point()
    scalarbase(p, r)
    local R = to_string(pack(p))

    local h = reduce(sha512(R .. pk .. message))
    local x = {}
    for i = 0, 63 do x[i] = 0 end
    for i = 0, 31 do x[i] = r[i] end
    for i = 0, 31 do
        for j = 0, 31 do
            x[i + j] += h[i] * d[j]
        end
    end
    return R .. to_string(modL(x), true)
end

local function unpackneg(r, pk)
    local t, chk, num, den, den2, den4, den6 = gf(), gf(), gf(), gf(), gf(), gf(), gf()
    set(r[3], gf1)
    set(r[2], unpack25519(pk))
    S(num, r[2])
    M(den, num, D)
    Z(num, num, r[3])
    A(den, r[3], den)
    S(den2, den)
    S(den4, den2)
    M(den6, den4, den2)
    M(t, den6, num)
    M(t, t, den)
    pow2523(t, t)
    M(t, t, num)
    M(t, t, den)
    M(t, t, den)
    M(r[1], t, den)
    S(chk, r[1])
    M(chk, chk, den)
    if neq25519(chk, num) then M(r[1], r[1], I) end
    S(chk, r[1])
    M(chk, chk, den)
    if neq25519(chk, num) then return false end
    if par25519(r[1]) == floor(pk[32] / 128) then Z(r[1], gf0, r[1]) end
    M(r[4], r[1], r[2])
    return true
end

--[[
Checks a 64 byte signature of `message` against a 32 byte public key.
]]
function ed25519.verify(public_key, message, signature)
    if #public_key ~= 32 or #signature ~= 64 then return false end
    local q = new_point()
    if not unpackneg(q, bytes1(public_key)) then return false end

    local R = signature:sub(1, 32)
    local h = reduce(sha512(R .. public_key .. message))
    local p = new_point()
    scalarmult(p, q, h)
    local base = new_point()
    scalarbase(base, bytes0(signature:sub(33, 64)))
    add(p, base)
    return to_string(pack(p)) == R
end

return ed25519
