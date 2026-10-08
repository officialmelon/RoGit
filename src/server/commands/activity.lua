--[[
git activity: a log of the commands run in this place (who, when, how long, and whether they worked).

Kept in .git/logs/activity (the last 500 commands), so it is shared with everyone in Team Create.
Turn it off with: git config rogit.activityLog false
]]
local arguments = require(script.Parent.Parent.arguments)
local bash = require(script.Parent.Parent.bash)
local repo = require(script.Parent.Parent.libs.repo)
local trace = require(script.Parent.Parent.libs.trace)
local output = require(script.Parent.Parent.libs.output)
local Auth = require(script.Parent.Parent.libs.localstore)

local function print(...)
    output.print(...)
end

local LOG_PATH = "logs/activity"
local MAX_ENTRIES = 500
local SKIP = {activity = true, help = true, h = true, version = true, v = true, ["--version"] = true}

local function main_folder()
    return bash.getMainGitFolder()
end

local function read_lines()
    local main = main_folder()
    local file = main and bash.getDirectoryOrFile(main, LOG_PATH)
    local content = file and bash.getFileContents(file.Parent, file.Name) or ""
    local lines = {}
    for line in content:gmatch("[^\n]+") do
        table.insert(lines, line)
    end
    return lines
end

local function write_lines(lines)
    local main = main_folder()
    if not main then return end
    local folder = bash.createFolder(main, "logs")
    bash.writeFile(folder, "activity", #lines > 0 and (table.concat(lines, "\n") .. "\n") or "")
end

local function clean(text)
    return (tostring(text or ""):gsub("\27%[[%d;]*m", ""):gsub("[\t\n\r]+", " "))
end

--[[
Records a finished top level command.
]]
local function record(ok, err, seconds, command, argument, ...)
    if command ~= "git" or SKIP[argument or ""] then return end
    local main = main_folder()
    if not main then return end
    local enabled = bash.withContext(nil, repo.get_config, "rogit.activityLog")
    if enabled == "false" or enabled == false then return end

    local message = ""
    if not ok then
        message = clean(tostring(err):match("^[^\n]*"))
    end
    local line = table.concat({
        tostring(os.time()),
        clean(Auth.getConfigValue("user_name") or "unknown"),
        tostring(math.floor(seconds * 1000 + 0.5)),
        ok and "ok" or "failed",
        clean(trace.redact(trace.command_line(command, argument, ...))),
        message,
    }, "\t")

    local lines = read_lines()
    table.insert(lines, line)
    while #lines > MAX_ENTRIES do
        table.remove(lines, 1)
    end
    write_lines(lines)
end

arguments.onFinish = function(depth, ok, err, seconds, command, ...)
    if trace.enabled("perf") then
        trace.log("perf", "%s%s %s in %d ms", string.rep("  ", depth), trace.command_line(command, ...), ok and "finished" or "failed", seconds * 1000)
    end
    if depth == 0 then
        record(ok, err, seconds, command, ...)
    end
end

local function format_duration(ms)
    if ms >= 60000 then
        return string.format("%dm%02ds", ms // 60000, (ms % 60000) // 1000)
    elseif ms >= 1000 then
        return string.format("%.1fs", ms / 1000)
    end
    return ms .. "ms"
end

arguments.createArgument("git", "activity", "", function(...)
    repo.require_root()
    local limit, failed_only, author, grep = 20, false, nil, nil
    local args = {...}
    local i = 1
    while i <= #args do
        local arg = args[i]
        if arg == "-n" or arg == "--max-count" then
            limit = tonumber(args[i + 1]) or limit
            i += 1
        elseif arg:match("^%-%d+$") then
            limit = tonumber(arg:sub(2))
        elseif arg:match("^%-%-max%-count=") then
            limit = tonumber(arg:match("=(.*)$")) or limit
        elseif arg == "--all" then
            limit = math.huge
        elseif arg == "--failed" then
            failed_only = true
        elseif arg:match("^%-%-author=") then
            author = arg:match("=(.*)$"):lower()
        elseif arg:match("^%-%-grep=") then
            grep = arg:match("=(.*)$"):lower()
        elseif arg == "--clear" then
            write_lines({})
            print("Cleared the activity log.")
            return
        else
            error("usage: git activity [-n <count> | --all] [--failed] [--author=<name>] [--grep=<text>] [--clear]", 0)
        end
        i += 1
    end

    local lines = read_lines()
    local shown = 0
    for index = #lines, 1, -1 do
        if shown >= limit then break end
        local time, who, ms, status, command, message = lines[index]:match("^(%d+)\t([^\t]*)\t(%d+)\t(%a+)\t([^\t]*)\t?(.*)$")
        if time
            and (not failed_only or status == "failed")
            and (not author or who:lower():find(author, 1, true))
            and (not grep or command:lower():find(grep, 1, true) or message:lower():find(grep, 1, true)) then
            shown += 1
            local color = status == "ok" and "\27[32m" or "\27[31m"
            print(string.format("\27[33m%s\27[0m  %-12s %7s  %s%-6s\27[0m %s", os.date("%Y-%m-%d %H:%M:%S", tonumber(time)), who, format_duration(tonumber(ms)), color, status, command))
            if status == "failed" and message ~= "" then
                print("                                             \27[31m" .. message .. "\27[0m")
            end
        end
    end
    if shown == 0 then
        print(#lines == 0 and "No activity recorded yet." or "No matching activity.")
    end
end)

return {
    record = record,
}
