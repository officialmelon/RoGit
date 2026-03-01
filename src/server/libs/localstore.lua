local Auth = {}

local Utilities = require(script.Parent.utilities)
local bash = require(script.Parent.Parent.bash)
local ini_parser = require(script.Parent.ini_parser)

--// Creds & temp variables
Auth.memory_credentials = {}
Auth.ACTIVE_PLUGIN = nil

--[[
Returns the authorization header used in git requests.
]]
function Auth.getAuthHeader(url)
    if Auth.memory_credentials[url] then
        return "Basic " .. Utilities.b64Encode("x:" .. Auth.memory_credentials[url])
    end
    local token = Auth.getConfigValue("user.token") or Auth.getConfigValue("user.password")
    if token then
        return "Basic " .. Utilities.b64Encode("x:" .. token)
    end
    return nil
end

--[[
Sets authorization to config file.
(probably not safe? should probably not store in config.)
]]
function Auth.getConfigValue(key)
    local sensitive_keys = {
        ["user.name"] = true,
        ["user.email"] = true,
        ["user.token"] = true,
        ["user.password"] = true
    }

    local root = bash.getGitFolderRoot()
    local loaded_conf = {}
    if root then
        local config_content = bash.getFileContents(root, "config")
        if type(config_content) == "string" and config_content ~= "" then
            loaded_conf = ini_parser.parseIni(config_content)
        end
    end
    local conf = loaded_conf

    local userName = conf.user and conf.user.name
    local userEmail = conf.user and conf.user.email
    if not userName and Auth.ACTIVE_PLUGIN then
        pcall(function() userName = Auth.ACTIVE_PLUGIN:GetSetting("user.name") end)
    end
    if not userEmail and Auth.ACTIVE_PLUGIN then
        pcall(function() userEmail = Auth.ACTIVE_PLUGIN:GetSetting("user.email") end)
    end

    if key == "user.name" then return userName end
    if key == "user.email" then return userEmail end

    if sensitive_keys[key] and Auth.ACTIVE_PLUGIN then
        local val = Auth.ACTIVE_PLUGIN:GetSetting(key)
        if val then return val end
    end

    local key_parts = string.split(key, ".")
    if loaded_conf[key_parts[1]] then
        local val = loaded_conf[key_parts[1]][key_parts[2]]
        if type(val) == "string" then
            val = val:gsub('^"(.*)"$', '%1'):gsub("^'(.*)'$", "%1")
        end
        return val
    end
    return nil
end

return Auth