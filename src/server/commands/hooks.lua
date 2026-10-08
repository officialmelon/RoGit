--[[
git hook: list, create, run and remove Luau hooks (see libs/hooks.lua).
]]
local arguments = require(script.Parent.Parent.arguments)
local repo = require(script.Parent.Parent.libs.repo)
local hooks = require(script.Parent.Parent.libs.hooks)
local output = require(script.Parent.Parent.libs.output)
local bash = require(script.Parent.Parent.bash)
local Auth = require(script.Parent.Parent.libs.localstore)

local function print(...)
    output.print(...)
end

local WHEN = {
    ["pre-commit"] = "before a commit is made (return false to stop it)",
    ["prepare-commit-msg"] = "before the commit message editor opens (return a string to change the message)",
    ["commit-msg"] = "after the commit message is written (return false to stop the commit, or a string to change it)",
    ["post-commit"] = "after a commit is made",
    ["pre-merge-commit"] = "before a merge commit is made (return false to stop it)",
    ["post-merge"] = "after a merge or pull updated the place",
    ["pre-rebase"] = "before a rebase starts (return false to stop it)",
    ["post-rewrite"] = "after commit --amend or a rebase rewrote commits",
    ["post-checkout"] = "after switch/checkout moved HEAD (args: old, new, is branch checkout)",
    ["pre-push"] = "before anything is pushed (args: remote name, url; context.updates lists the refs)",
    ["post-update"] = "after refs were updated by a push",
}

arguments.createArgument("git", "hook", "", function(...)
    local root = repo.require_root()
    local tuple = {...}
    local sub = tuple[1] or "list"

    if sub == "list" then
        local any = false
        for _, name in ipairs(hooks.NAMES) do
            if hooks.find(name) then
                print(name)
                any = true
            end
        end
        if not any then
            print("No hooks. Create one with: git hook create <name>")
            print("Available: " .. table.concat(hooks.NAMES, ", "))
        end

    elseif sub == "create" then
        local name = tuple[2]
        if not name or not WHEN[name] then
            error("usage: git hook create <name>\nnames: " .. table.concat(hooks.NAMES, ", "), 0)
        end
        if hooks.find(name) then
            error("error: the " .. name .. " hook already exists", 0)
        end
        local folder = hooks.folder() or bash.createFolder(root, "hooks")
        local module = Instance.new("ModuleScript")
        module.Name = name
        module.Source = string.format(hooks.TEMPLATE, name, WHEN[name])
        module.Parent = folder
        print("Created hook " .. name .. " (" .. module:GetFullName() .. ")")
        local plugin = Auth.ACTIVE_PLUGIN or _G.ACTIVE_PLUGIN
        if plugin then
            pcall(function() plugin:OpenScript(module) end)
        end

    elseif sub == "run" then
        local name = tuple[2]
        if not name then
            error("usage: git hook run <name> [-- <args>...]", 0)
        end
        if not hooks.find(name) then
            error("error: cannot find a hook named " .. name, 0)
        end
        local args = {}
        for i = 3, #tuple do
            if tuple[i] ~= "--" then table.insert(args, tuple[i]) end
        end
        local ok, result = hooks.run(name, {args = args})
        if not ok then
            error("error: hook " .. name .. " failed" .. (result and (": " .. tostring(result)) or ""), 0)
        end

    elseif sub == "remove" or sub == "rm" then
        local module = tuple[2] and hooks.find(tuple[2])
        if not module then
            error("error: no hook named " .. tostring(tuple[2]), 0)
        end
        module:Destroy()

    else
        error("usage: git hook (list | create <name> | run <name> [-- <args>] | remove <name>)", 0)
    end
end)

return {}
