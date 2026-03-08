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
    local base_url = url:match("^(https?://[^/]+)") or url
    local creds = Auth.memory_credentials[base_url]
    
    if creds then
        return "Basic " .. Utilities.b64Encode(creds.username .. ":" .. creds.password)
    end
    
    local token = Auth.getConfigValue("user_token") or Auth.getConfigValue("user_password")
    if token then
        local userName = Auth.getConfigValue("user_name") or "x"
        return "Basic " .. Utilities.b64Encode(userName .. ":" .. token)
    end
    return nil
end

--[[
Sets authorization to config file.
(probably not safe? should probably not store in config.)
]]
function Auth.getConfigValue(key)
    local root = bash.getGitFolderRoot()
    local loaded_conf = {}
    if root then
        local config_content = bash.getFileContents(root, "config")
        if type(config_content) == "string" and config_content ~= "" then
            loaded_conf = ini_parser.parseIni(config_content)
        end
    end
    
    -- Try local config first
    local key_parts = string.split(key, ".")
    if #key_parts >= 2 and loaded_conf[key_parts[1]] then
        local val = loaded_conf[key_parts[1]][key_parts[2]]
        if val then
            if type(val) == "string" then
                val = val:gsub('^"(.*)"$', '%1'):gsub("^'(.*)'$", "%1")
            end
            return val
        end
    end

    -- If not found (or for sensitive/global keys), try plugin settings
    local plugin_ref = Auth.ACTIVE_PLUGIN or _G.ACTIVE_PLUGIN
    if plugin_ref then
        local val
        pcall(function()
            val = plugin_ref:GetSetting(key)
        end)
        if val then
            if type(val) == "string" then
                val = val:gsub('^"(.*)"$', '%1'):gsub("^'(.*)'$", "%1")
            end
            return val
        end
    end

    return nil
end

return Auth
