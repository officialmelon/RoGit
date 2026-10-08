--[[
Tracing, like GIT_TRACE / GIT_TRACE_CURL: prints what roGit is doing while a command runs.

    git config --global rogit.trace true        everything, for every command
    git config --global rogit.trace http,hook   only some kinds
    git -c rogit.trace=1 push                   just this once

Kinds: run (commands, including ones run by other commands and hooks), http (requests, status, size, time),
hook, context (worktree/submodule switches), perf (how long each top level command took).
]]
local trace = {}

local Auth = require(script.Parent.localstore)
local output = require(script.Parent.output)

local ALL = {["1"] = true, ["true"] = true, yes = true, on = true, all = true, ["2"] = true}

function trace.enabled(kind)
    local value = Auth.getConfigValue("rogit_trace")
    if value == nil or value == false then return false end
    value = tostring(value):lower()
    if ALL[value] then return true end
    for name in value:gmatch("[^,%s]+") do
        if name == kind then return true end
    end
    return false
end

function trace.log(kind, message, ...)
    if not trace.enabled(kind) then return end
    if select("#", ...) > 0 then
        message = string.format(message, ...)
    end
    output.print(string.format("\27[90m%s.%03d trace %s: %s\27[0m", os.date("%H:%M:%S"), math.floor((os.clock() % 1) * 1000), kind, message))
end

--[[
Hides credentials in a URL (https://user:token@host -> https://user:***@host).
]]
function trace.redact(url)
    return (tostring(url):gsub("^(https?://[^:/@]+:)[^@]+@", "%1***@"))
end

--[[
Quotes arguments with spaces, so the line can be pasted back into the terminal.
]]
function trace.command_line(command, ...)
    local parts = {command}
    for i = 1, select("#", ...) do
        local arg = tostring((select(i, ...)))
        if arg == "" or arg:find("[%s\"']") then
            arg = '"' .. arg:gsub('"', '\\"') .. '"'
        end
        table.insert(parts, arg)
    end
    return table.concat(parts, " ")
end

return trace
