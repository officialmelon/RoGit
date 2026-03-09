local Auth = {}

local Utilities = require(script.Parent.utilities)
local bash = require(script.Parent.Parent.bash)
local ini_parser = require(script.Parent.ini_parser)

--// Creds & temp variables
Auth.memory_credentials = {}
Auth.ACTIVE_PLUGIN = nil

--[[
Encodes the auth in base64 followed by an 'x' and returns the header
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
Gets authorization from the plugin settings
(Old did get from the config. However if in team create that leaks your key blah blah)
]]
function Auth.getConfigValue(key)
    local plugin_ref = Auth.ACTIVE_PLUGIN
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
