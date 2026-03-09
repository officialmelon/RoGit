local Requests = {}

local HttpService = game:GetService("HttpService")
local Auth = require(script.Parent.localstore)
local Utilities = require(script.Parent.utilities)

local prompt_callback = nil

--[[
Sets the prompt_callback
]]
function Requests.setPromptCallback(cb)
    prompt_callback = cb
end

--[[
Requests credentials for auth
]]
local function ask_for_credential(prompt_text, is_password)
    if prompt_callback then
        return prompt_callback(prompt_text, is_password)
    end
    return nil
end

--[[
Makes a request to anything that we need to.
]]
function Requests.url_request_with_retry(req_options)
    local ok, res = pcall(function() return HttpService:RequestAsync(req_options) end)
    if not ok then return false, res end

    if res.StatusCode == 401 or res.StatusCode == 404 then
        local username = ask_for_credential("Username for '" .. (req_options.Url:match("^(https?://[^/]+)") or req_options.Url) .. "':", false)
        if not username or username == "" then
            return true, res
        end
        
        local password = ask_for_credential("Password for '" .. (req_options.Url:match("^(https?://[^/]+)") or req_options.Url) .. "':", true)
        
        if password and password ~= "" then
            local base_url = req_options.Url:match("^(https?://[^/]+)") or req_options.Url
            Auth.memory_credentials[base_url] = {
                username = username,
                password = password
            }
            
            --[[
            ts bugged tf out, why tf u not saving gng?
            lowkey finna crash out in ts mf ass lines of code.
            fuck ass code should work first try, but no
            you decided to be a bitch today. SAVE THE FUCKING CREDENTIALS
            pls uwu

            OKAY NVM
            turns out roblox siltently fails if you include '.' or '/' inside of the damn thing
            probably json escape code issue? anyways idk. lets NOT use that.
            ]]
            local plugin_ref = Auth.ACTIVE_PLUGIN or _G.ACTIVE_PLUGIN
            if plugin_ref then
                pcall(function()
                    plugin_ref:SetSetting("user_name", username)
                    plugin_ref:SetSetting("user_token", password)
                end)
            end
            
            req_options.Headers = req_options.Headers or {}
            req_options.Headers["Authorization"] = "Basic " .. Utilities.b64Encode(username .. ":" .. password)
            
            ok, res = pcall(function() return HttpService:RequestAsync(req_options) end)
            if not ok then return false, res end
        end
    end
    return true, res
end

return Requests
