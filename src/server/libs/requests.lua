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
Requests credentials for auth via plugin terminal.
]]
local function ask_for_credential(prompt_text, is_password)
    if prompt_callback then
        return prompt_callback(prompt_text, is_password)
    end
    return nil
end

--[[
Makes a request to the git repository.
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
            Auth.memory_credentials[base_url] = password
            
            req_options.Headers = req_options.Headers or {}
            req_options.Headers["Authorization"] = "Basic " .. Utilities.b64Encode(username .. ":" .. password)
            
            ok, res = pcall(function() return HttpService:RequestAsync(req_options) end)
            if not ok then return false, res end
        end
    end
    return true, res
end

return Requests