local Utilities = {}

local _HttpService = game:GetService("HttpService")
--// Yielding defintions
local _ro_yield = 0
local last_yield = os.clock()


--[[
Yeilds every 400 calls to the function, or every 0.04 seconds.
]]
function Utilities.roYield()
    _ro_yield = _ro_yield + 1
    if _ro_yield > 400 then
        _ro_yield = 0
        if os.clock() - last_yield > 0.04 then
            task.wait()
            last_yield = os.clock()
        end
    end
end

--[[
Turns an instance name into a safe path segment. Names can hold characters that can't be part of a git tree entry:
"/" (the path separator), nothing at all, "." / ".." and ".git".
They are written as %2F, %00 and %2E, and a "%" that could be mistaken for one of those becomes %25.
Ordinary names are left alone, so existing repositories keep working.
]]
function Utilities.escape_name(name: string): string
    if name == "" then return "%00" end

    name = name:gsub("%%(%x%x)", function(hex)
        local upper = hex:upper()
        if upper == "2F" or upper == "25" or upper == "00" or upper == "2E" then
            return "%25" .. hex
        end
        return nil
    end)
    name = name:gsub("/", "%%2F")

    local lower = name:lower()
    if name == "." or name == ".." or lower == ".git" or lower == ".properties" then
        name = "%2E" .. name:sub(2)
    end
    return name
end

--[[
Reverse of escape_name.
]]
function Utilities.unescape_name(segment: string): string
    if segment == "%00" then return "" end
    if not segment:find("%", 1, true) then return segment end

    local result = segment:gsub("%%(%x%x)", function(hex)
        local upper = hex:upper()
        if upper == "2F" then return "/" end
        if upper == "25" then return "%" end
        if upper == "2E" then return "." end
        return nil
    end)
    return result
end

--[[
Parses a path into a Roblox Instance.
Returns the instance, the last segment, and the segments.
]]
function Utilities.parse_path(path)
    if not path or path == "" then
        return nil
    end

    local ROGIT_ID = "_rogit_id"
    local cleaned = path:gsub("^game[./]", "")
    if not cleaned:find("/", 1, true) then
        -- Dot notation from user input (example: game.Workspace.Part).
        cleaned = cleaned:gsub("%.", "/")
    else
        -- Slash notation can contain literal dots in instance names.
        cleaned = cleaned:gsub("^Workspace%.", "Workspace/")
    end
    cleaned = cleaned:gsub("^Workspace[./]", "Workspace/")
    local segments = string.split(cleaned, "/")
    local currObj = require(script.Parent.Parent.bash).getWorkRoot()

    for _, segment in ipairs(segments) do
        if not currObj then return nil, segments[#segments], segments end
        
        local baseName, indexStr = segment:match("^(.*) %[(%d+)%]$")
        if indexStr then
            local targetIndex = tonumber(indexStr)
            local unescapedBase = Utilities.unescape_name(baseName)
            local children = {}
            for _, child in ipairs(currObj:GetChildren()) do
                if child.Name == unescapedBase then
                    table.insert(children, child)
                end
            end
            
            table.sort(children, function(a, b)
                if a.Name ~= b.Name then
                    return a.Name < b.Name
                end
                return (a:GetAttribute(ROGIT_ID) or "") < (b:GetAttribute(ROGIT_ID) or "")
            end)
            
            currObj = children[targetIndex]
        else
            currObj = currObj:FindFirstChild(Utilities.unescape_name(segment))
        end
        
        if not currObj then
            return nil, segments[#segments], segments
        end
    end

    return currObj, segments[#segments], segments
end

--[[
Returns the URLs for the git service we need.
]]
function Utilities.return_urls(url: string, service: string?)
    local svc = service or "git-upload-pack"
    url = (url:gsub("/+$", ""))
    return {url .. "/info/refs?service=" .. svc, url .. "/" .. svc}
end

--[[
Cleans up a remote URL so more spellings work:
`git@github.com:user/repo.git`, `ssh://git@host/user/repo`, `github.com/user/repo` and trailing slashes
all end up as plain https:// URLs (only the smart HTTP protocol is supported).
]]
function Utilities.normalize_url(url: string): string
    url = url:match("^%s*(.-)%s*$")

    local host, path = url:match("^[%w_.-]+@([^:/]+):(.+)$")
    if host then
        url = "https://" .. host .. "/" .. path
    end

    local sshHost, sshPath = url:match("^ssh://[%w_.-]+@([^/]+)/(.+)$")
    if sshHost then
        url = "https://" .. sshHost .. "/" .. sshPath
    end

    url = url:gsub("^git://", "https://")
    if not url:match("^https?://") then
        url = "https://" .. url
    end

    url = url:gsub("/+$", "")
    return url
end

--[[
Encodes data into base64.
]]
function Utilities.b64Encode(data)
    local b = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local res = {}
    local last_yield = os.clock()
    for i = 1, #data, 3 do
        if os.clock() - last_yield > 0.03 then
            task.wait()
            last_yield = os.clock()
        end
        local c1, c2, c3 = string.byte(data, i, i + 2)
        local n = bit32.bor(bit32.lshift(c1 or 0, 16), bit32.lshift(c2 or 0, 8), c3 or 0)
        table.insert(res, string.sub(b, bit32.rshift(n, 18) + 1, bit32.rshift(n, 18) + 1))
        table.insert(res, string.sub(b, bit32.band(bit32.rshift(n, 12), 63) + 1, bit32.band(bit32.rshift(n, 12), 63) + 1))
        table.insert(res, c2 and string.sub(b, bit32.band(bit32.rshift(n, 6), 63) + 1, bit32.band(bit32.rshift(n, 6), 63) + 1) or "=")
        table.insert(res, c3 and string.sub(b, bit32.band(n, 63) + 1, bit32.band(n, 63) + 1) or "=")
    end
    return table.concat(res)
end

return Utilities
