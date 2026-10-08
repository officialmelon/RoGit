--[[
Git hooks as Luau: a ModuleScript named after the hook (pre-commit, commit-msg, ...) inside .git/hooks
(or the folder `core.hooksPath` points at) that returns a function.

    return function(context)
        -- context.name, context.args, context.message (commit-msg), context.git("status") runs a git command
        if somethingIsWrong then
            return false, "why"       -- (or error()) stops the command, for the hooks that can stop things
        end
        return true                   -- commit-msg / prepare-commit-msg may return a new message instead
    end

Hooks are re-loaded every time they run, so editing them takes effect immediately.
]]
local hooks = {}

local bash = require(script.Parent.Parent.bash)
local Utilities = require(script.Parent.utilities)
local output = require(script.Parent.output)
local trace = require(script.Parent.trace)

hooks.NAMES = {
    "pre-commit", "prepare-commit-msg", "commit-msg", "post-commit",
    "pre-merge-commit", "post-merge", "pre-rebase", "post-rewrite",
    "post-checkout", "pre-push", "post-update",
}

--// how a hook ModuleScript is turned into a function (tests swap this out)
hooks.loader = function(module)
    --// requiring a fresh clone picks up edits (require caches per instance)
    local copy = module:Clone()
    copy.Parent = module.Parent
    local ok, result = pcall(require, copy)
    copy:Destroy()
    if not ok then error(result, 0) end
    return result
end

--// set by git.lua so hooks can run git commands
hooks.run_git = nil

--// --no-verify sets this for the duration of one command
hooks.disabled = false

--[[
The folder hooks live in.
]]
function hooks.folder()
    local root = bash.getGitFolderRoot()
    if not root then return nil end
    local custom = hooks.config_path and hooks.config_path()
    if custom and custom ~= "" then
        return Utilities.parse_path(custom)
    end
    return root:FindFirstChild("hooks")
end

function hooks.find(name)
    local folder = hooks.folder()
    local module = folder and folder:FindFirstChild(name)
    if module and module:IsA("ModuleScript") then
        return module
    end
    return nil
end

--[[
Runs a hook if it exists. Returns ok (false when the hook said no or failed) and its result/reason.
]]
function hooks.run(name, context)
    if hooks.disabled then return true, nil end
    local module = hooks.find(name)
    if not module then return true, nil end

    context = context or {}
    context.name = name
    context.args = context.args or {}
    context.git = function(...)
        assert(hooks.run_git, "git commands aren't available from hooks here")
        return hooks.run_git(...)
    end

    local loaded, fn = pcall(hooks.loader, module)
    if not loaded then
        return false, "the " .. name .. " hook failed to load: " .. tostring(fn)
    end
    if type(fn) ~= "function" then
        return false, "the " .. name .. " hook must return a function"
    end

    trace.log("hook", "running %s (%s)", name, module:GetFullName())
    local started = os.clock()
    local ok, result, reason = pcall(fn, context)
    trace.log("hook", "%s finished: %s (%d ms)", name, not ok and ("error: " .. tostring(result)) or (result == false and "declined" or "ok"), (os.clock() - started) * 1000)
    if not ok then
        return false, tostring(result)
    end
    if result == false then
        return false, reason
    end
    return true, result
end

--[[
Runs a hook that may stop the command: errors when it declines.
]]
function hooks.run_blocking(name, context)
    local ok, reason = hooks.run(name, context)
    if not ok then
        error("error: the '" .. name .. "' hook declined" .. (reason and (": " .. tostring(reason)) or ""), 0)
    end
    return reason
end

--[[
Runs a hook that only gets told about something (post-*): problems are reported, never fatal.
]]
function hooks.notify(name, context)
    local ok, reason = hooks.run(name, context)
    if not ok and reason then
        output.warn("warning: the '" .. name .. "' hook failed: " .. tostring(reason))
    end
end

--[[
commit-msg / prepare-commit-msg: the hook may return a replacement message.
]]
function hooks.run_message_hook(name, message, args)
    local ok, result = hooks.run(name, {message = message, args = args})
    if not ok then
        error("error: the '" .. name .. "' hook declined" .. (result and (": " .. tostring(result)) or ""), 0)
    end
    if type(result) == "string" then
        return result
    end
    return message
end

hooks.TEMPLATE = [[
--[=[
roGit "%s" hook. It runs %s.

Return false (optionally with a reason) or error() to stop the command, true to let it continue.
context.args holds the arguments git passes to this hook, context.git("<command>", ...) runs a git command.
]=]
return function(context)
    return true
end
]]

return hooks
