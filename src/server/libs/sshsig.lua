--[[
SSH signatures (the format of `ssh-keygen -Y sign`, which git uses for gpg.format=ssh).
GitHub and GitLab show commits signed this way as "Verified" once the public key is added as a signing key.

Keys are ed25519 only. The private key is a 32 byte seed kept in the plugin settings (never inside the place).
]]
local sshsig = {}

local hashlib = require(script.Parent.hashlib)
local ed25519 = require(script.Parent.ed25519)

local MAGIC = "SSHSIG"
local KEY_TYPE = "ssh-ed25519"

local function u32(n)
    return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

local function sshstring(s)
    return u32(#s) .. s
end

--[[
Reads an ssh "string" at pos. Returns the string and the position after it.
]]
local function read_string(data, pos)
    local a, b, c, d = string.byte(data, pos, pos + 3)
    if not d then return nil, pos end
    local len = ((a * 256 + b) * 256 + c) * 256 + d
    return data:sub(pos + 4, pos + 3 + len), pos + 4 + len
end

local function public_blob(public_key)
    return sshstring(KEY_TYPE) .. sshstring(public_key)
end

--[[
"ssh-ed25519 AAAA... comment", the line to paste into GitHub (Settings > SSH and GPG keys > New SSH key > Signing key).
]]
function sshsig.public_key_line(seed, comment)
    local blob = public_blob(ed25519.public_key(seed))
    return KEY_TYPE .. " " .. hashlib.bin_to_base64(blob) .. (comment and (" " .. comment) or "")
end

--[[
SHA256:... fingerprint, as printed by ssh-keygen and git.
]]
function sshsig.fingerprint(public_key)
    local digest = hashlib.hex_to_bin(hashlib.sha256(public_blob(public_key)))
    return "SHA256:" .. (hashlib.bin_to_base64(digest):gsub("=+$", ""))
end

local function signed_data(namespace, message)
    local digest = hashlib.hex_to_bin(hashlib.sha512(message))
    return MAGIC .. sshstring(namespace) .. sshstring("") .. sshstring("sha512") .. sshstring(digest)
end

--[[
Signs `message`, returns the armored "-----BEGIN SSH SIGNATURE-----" block (ending with a newline).
]]
function sshsig.sign(seed, message, namespace)
    namespace = namespace or "git"
    local signature = ed25519.sign(seed, signed_data(namespace, message))
    local blob = MAGIC .. u32(1)
        .. sshstring(public_blob(ed25519.public_key(seed)))
        .. sshstring(namespace)
        .. sshstring("")
        .. sshstring("sha512")
        .. sshstring(sshstring(KEY_TYPE) .. sshstring(signature))

    local encoded = hashlib.bin_to_base64(blob)
    local lines = {"-----BEGIN SSH SIGNATURE-----"}
    for i = 1, #encoded, 70 do
        table.insert(lines, encoded:sub(i, i + 69))
    end
    table.insert(lines, "-----END SSH SIGNATURE-----")
    return table.concat(lines, "\n") .. "\n"
end

--[[
Checks an armored signature. Returns ok, the signer's public key (32 bytes) and a reason when it fails.
]]
function sshsig.verify(armored, message, namespace)
    namespace = namespace or "git"
    local body = armored:match("%-%-%-%-%-BEGIN SSH SIGNATURE%-%-%-%-%-(.-)%-%-%-%-%-END SSH SIGNATURE%-%-%-%-%-")
    if not body then return false, nil, "not an SSH signature" end
    local ok, blob = pcall(hashlib.base64_to_bin, (body:gsub("%s", "")))
    if not ok or blob:sub(1, 6) ~= MAGIC then return false, nil, "malformed signature" end

    local pos = 11 --// after magic and version
    local key_blob, sig_namespace, hash_algorithm, sig_blob
    key_blob, pos = read_string(blob, pos)
    sig_namespace, pos = read_string(blob, pos)
    _, pos = read_string(blob, pos)
    hash_algorithm, pos = read_string(blob, pos)
    sig_blob, pos = read_string(blob, pos)
    if not sig_blob then return false, nil, "malformed signature" end

    local key_type, kpos = read_string(key_blob, 1)
    local public_key = read_string(key_blob, kpos)
    if key_type ~= KEY_TYPE then return false, nil, "unsupported key type " .. tostring(key_type) end
    if sig_namespace ~= namespace then return false, public_key, "wrong namespace" end
    if hash_algorithm ~= "sha512" then return false, public_key, "unsupported hash " .. tostring(hash_algorithm) end

    local _, spos = read_string(sig_blob, 1)
    local signature = read_string(sig_blob, spos)
    local valid = ed25519.verify(public_key, signed_data(namespace, message), signature)
    return valid, public_key, valid and nil or "bad signature"
end

--[[
Reads the seed out of an unencrypted OpenSSH private key ("-----BEGIN OPENSSH PRIVATE KEY-----").
]]
function sshsig.parse_private_key(text)
    local body = text:match("%-%-%-%-%-BEGIN OPENSSH PRIVATE KEY%-%-%-%-%-(.-)%-%-%-%-%-END OPENSSH PRIVATE KEY%-%-%-%-%-")
    if not body then return nil, "not an OpenSSH private key" end
    local data = hashlib.base64_to_bin((body:gsub("%s", "")))
    if data:sub(1, 15) ~= "openssh-key-v1\0" then return nil, "not an OpenSSH private key" end

    local pos = 16
    local cipher, kdf
    cipher, pos = read_string(data, pos)
    kdf, pos = read_string(data, pos)
    _, pos = read_string(data, pos) --// kdf options
    if cipher ~= "none" or kdf ~= "none" then
        return nil, "the key is protected by a passphrase; export an unencrypted copy (ssh-keygen -p -N \"\" -f <copy>)"
    end
    pos += 4 --// number of keys
    _, pos = read_string(data, pos) --// public key
    local private = read_string(data, pos)

    local p = 9 --// two check integers
    local key_type
    key_type, p = read_string(private, p)
    if key_type ~= KEY_TYPE then return nil, "only ed25519 keys are supported" end
    _, p = read_string(private, p) --// public key
    local secret = read_string(private, p) --// 64 bytes: seed .. public key
    if not secret or #secret ~= 64 then return nil, "malformed key" end
    return secret:sub(1, 32)
end

return sshsig
