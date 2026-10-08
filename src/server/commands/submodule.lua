--[[
git submodule: other roGit repositories inside the place.

A submodule is a folder (with the RoGitSubmodule attribute) whose contents come from another repository, pinned to a
commit. The place's tree records only that commit (a "gitlink"), like git does. The submodule's repository lives in
.git/modules/<name>; its contents go inside the folder, so a library repository's "ReplicatedStorage/Lib" ends up as
<folder>/ReplicatedStorage/Lib. Settings are in ServerStorage/.gitmodules (git config format, tracked).
Run commands inside one with `git -C <path> <command>` or `git submodule foreach <command>`.
]]
local arguments = require(script.Parent.Parent.arguments)
local bash = require(script.Parent.Parent.bash)
local Handlers = require(script.Parent.Parent.libs.git_handlers)
local Remote = require(script.Parent.Parent.libs.git_remote)
local repo = require(script.Parent.Parent.libs.repo)
local Utilities = require(script.Parent.Parent.libs.utilities)
local ini_parser = require(script.Parent.Parent.libs.ini_parser)
local output = require(script.Parent.Parent.libs.output)

local function print(...)
    output.print(...)
end

local USAGE = [==[usage: git submodule [status] [--cached] [--recursive] [<path>...]
   or: git submodule add [-b <branch>] [--name <name>] [-f] <repository> [<path>]
   or: git submodule init [<path>...]
   or: git submodule deinit [-f] (--all | <path>...)
   or: git submodule update [--init] [--remote] [-f] [--recursive] [<path>...]
   or: git submodule set-branch (-b <branch> | -d) <path>
   or: git submodule set-url <path> <newurl>
   or: git submodule summary
   or: git submodule foreach [--recursive] <git command>
   or: git submodule sync [--recursive] [<path>...]]==]

--// ------------------------------------------------------------------ .gitmodules

local function gitmodules_holder(create)
    return bash.getServiceRoot("ServerStorage", create)
end

local function read_gitmodules()
    local holder = gitmodules_holder(false)
    return ini_parser.parseIni(holder and bash.getFileContents(holder, ".gitmodules") or "")
end

local function write_gitmodules(conf)
    local holder = gitmodules_holder(true)
    if next(conf) == nil then
        local file = holder:FindFirstChild(".gitmodules")
        if file then file:Destroy() end
        return
    end
    bash.writeFile(holder, ".gitmodules", ini_parser.serializeIni(conf))
end

local function section(name)
    return 'submodule "' .. name .. '"'
end

--[[
The name .gitmodules gives the submodule at `path` (git uses the path when there is none).
]]
local function name_for_path(path, modules)
    for sectionName, values in pairs(modules or read_gitmodules()) do
        local name = sectionName:match('^submodule "(.+)"$')
        if name and values.path == path then
            return name
        end
    end
    return path
end

--[[
The index style path of an instance in the current work tree.
]]
local function path_of(instance)
    local segments = {}
    local root = bash.getWorkRoot()
    local current = instance
    while current and current ~= root and current ~= game do
        table.insert(segments, 1, Utilities.escape_name(current.Name))
        current = current.Parent
    end
    return table.concat(segments, "/")
end

Remote.submoduleNameFor = function(folder)
    return name_for_path(path_of(folder))
end

--[[
Every submodule of the current repository: the gitlinks in the index, plus .gitmodules entries not staged yet.
]]
local function list_submodules(filters)
    local modules = read_gitmodules()
    local index = Handlers.read_index()
    local found, list = {}, {}
    local function add(path, recorded)
        if found[path] or not repo.matches_filters(path, filters) then return end
        found[path] = true
        local name = name_for_path(path, modules)
        local settings = modules[section(name)] or {}
        local folder = Utilities.parse_path(path)
        table.insert(list, {
            path = path,
            name = name,
            url = repo.get_config("submodule." .. name .. ".url") or settings.url,
            configured_url = repo.get_config("submodule." .. name .. ".url"),
            gitmodules_url = settings.url,
            branch = settings.branch,
            recorded = recorded,
            folder = folder,
        })
    end
    for path, data in pairs(index) do
        if data.mode == "160000" then
            add(path, data.sha)
        end
    end
    for sectionName, values in pairs(modules) do
        if sectionName:match('^submodule "') and values.path then
            add(values.path, nil)
        end
    end
    table.sort(list, function(a, b) return a.path < b.path end)
    return list
end

local function context_of(submodule)
    return {kind = "submodule", name = submodule.name, root = submodule.folder}
end

local function is_cloned(submodule)
    return Handlers.submodule_git_folder(submodule.name) ~= nil
end

local function head_of(submodule)
    if not submodule.folder or not is_cloned(submodule) then return nil end
    return bash.withContext(context_of(submodule), Handlers.get_ref, "HEAD")
end

local function describe(submodule, sha)
    if not sha then return "" end
    return bash.withContext(context_of(submodule), function()
        local branch = Handlers.get_current_branch()
        if branch and Handlers.get_ref("refs/heads/" .. branch) == sha then
            return " (heads/" .. branch .. ")"
        end
        for refName, refSha in pairs(Handlers.list_refs()) do
            if refSha == sha and refName:match("^refs/tags/") then
                return " (" .. refName:sub(6) .. ")"
            end
        end
        return ""
    end)
end

--[[
Clones (if needed) and checks out `target` in a submodule. Returns true when something changed.
]]
local function checkout_submodule(submodule, target, url, force)
    if not submodule.folder then
        local parentPath, leaf = submodule.path:match("^(.*)/([^/]+)$")
        local parent = parentPath and Utilities.parse_path(parentPath)
        if not parent then
            error("fatal: cannot create the folder for submodule '" .. submodule.path .. "'", 0)
        end
        submodule.folder = Remote.writeGitlink(parent, Utilities.unescape_name(leaf), target)
    end
    submodule.folder:SetAttribute(Handlers.SUBMODULE_ATTRIBUTE, submodule.name)
    local context = context_of(submodule)

    if not is_cloned(submodule) then
        if not url then
            error("fatal: No url found for submodule path '" .. submodule.path .. "' in .gitmodules", 0)
        end
        local ok, err = pcall(bash.withContext, context, arguments.execute, "git", "clone", "-q", url)
        if not ok then
            local folder = Handlers.submodule_git_folder(submodule.name)
            if folder then folder:Destroy() end
            error("fatal: clone of '" .. url .. "' into submodule path '" .. submodule.path .. "' failed\n" .. tostring(err), 0)
        end
    end

    return bash.withContext(context, function()
        local head = Handlers.get_ref("HEAD")
        local empty = #submodule.folder:GetChildren() == 0
        if head == target and not empty and not force then
            return false
        end
        if head == target or force then
            --// same commit but the folder was cleared (deinit) or --force: write everything again
            local commit = Handlers.read_commit(target)
            if not commit then
                pcall(Remote.fetch, "origin", true)
                commit = Handlers.read_commit(target)
            end
            if not commit then
                error("fatal: Unable to find current revision " .. target .. " in submodule path '" .. submodule.path .. "'", 0)
            end
            if force then Handlers.write_index({}) end
            Handlers.set_head(target, "submodule update: checkout " .. target)
            repo.checkout_tree(commit.tree)
        else
            arguments.execute("git", "switch", "--detach", target)
        end
        return true
    end)
end

--// ------------------------------------------------------------------ subcommands

local function parse(args, flags_with_values)
    local flags, positional = {}, {}
    local i = 1
    while i <= #args do
        local arg = args[i]
        if arg == "--" then
            for j = i + 1, #args do table.insert(positional, args[j]) end
            break
        elseif flags_with_values and flags_with_values[arg] then
            flags[flags_with_values[arg]] = args[i + 1]
            i += 1
        elseif arg:sub(1, 1) == "-" then
            flags[arg] = (flags[arg] or 0) + 1
        else
            table.insert(positional, repo.normalize_user_path(arg))
        end
        i += 1
    end
    return flags, positional
end

local function resolve_url(url)
    if url:match("^%.%.?/") then
        --// relative to the superproject's origin, like git
        local base = repo.get_config("remote.origin.url")
        if not base then
            error("fatal: cannot resolve relative url '" .. url .. "': the superproject has no 'origin' remote", 0)
        end
        base = base:gsub("/+$", ""):gsub("%.git$", "")
        for part in url:gmatch("[^/]+") do
            if part == ".." then
                base = base:gsub("/[^/]+$", "")
            elseif part ~= "." then
                base ..= "/" .. part
            end
        end
        return base
    end
    return Utilities.normalize_url(url)
end

local function set_config_url(name, url)
    local conf = repo.read_config()
    conf[section(name)] = conf[section(name)] or {}
    conf[section(name)].url = url
    conf[section(name)].active = "true"
    repo.write_config(conf)
end

local commands = {}

function commands.add(args)
    local flags, positional = parse(args, {["-b"] = "branch", ["--branch"] = "branch", ["--name"] = "name"})
    local raw_url = nil
    for _, arg in ipairs(args) do
        if arg:sub(1, 1) ~= "-" and arg ~= flags.branch and arg ~= flags.name then
            raw_url = arg
            break
        end
    end
    if not raw_url then
        error(USAGE, 0)
    end
    table.remove(positional, 1)
    local url = resolve_url(raw_url)
    local path = positional[1] or ("ReplicatedStorage/" .. ((raw_url:match("([^/]+)$") or "submodule"):gsub("%.git$", "")))
    local force = flags["-f"] or flags["--force"]

    local parentPath, leaf = path:match("^(.*)/([^/]+)$")
    if not parentPath then
        error("fatal: a submodule needs a path inside a service, like ReplicatedStorage/Packages/" .. path, 0)
    end
    local index = Handlers.read_index()
    for indexPath, data in pairs(index) do
        if indexPath == path or indexPath:sub(1, #path + 1) == path .. "/" then
            if data.mode ~= "160000" or not force then
                error("fatal: '" .. path .. "' already exists in the index", 0)
            end
        end
    end
    local existing = Utilities.parse_path(path)
    if existing and not force then
        error("fatal: '" .. path .. "' already exists and is not a valid git repo", 0)
    end

    local parent = Utilities.parse_path(parentPath)
    if not parent then
        error("fatal: '" .. parentPath .. "' does not exist", 0)
    end

    local name = flags.name or path
    local folder = existing or Instance.new("Folder")
    folder.Name = Utilities.unescape_name(leaf)
    folder:SetAttribute(Handlers.SUBMODULE_ATTRIBUTE, name)
    folder.Parent = parent

    local submodule = {path = path, name = name, url = url, folder = folder}
    if Handlers.submodule_git_folder(name) and not force then
        print("A git directory for '" .. name .. "' is found locally, reusing it.")
    end
    print("Cloning into '" .. path .. "'...")
    local ok, err = pcall(function()
        local context = context_of(submodule)
        if not is_cloned(submodule) then
            bash.withContext(context, arguments.execute, "git", "clone", "-q", url, table.unpack(flags.branch and {"-b", flags.branch} or {}))
        end
    end)
    if not ok then
        if not existing then folder:Destroy() end
        error(err, 0)
    end

    local modules = read_gitmodules()
    modules[section(name)] = {path = path, url = raw_url:match("^%.%.?/") and raw_url or url, branch = flags.branch}
    write_gitmodules(modules)
    set_config_url(name, url)

    arguments.execute("git", "add", "ServerStorage/.gitmodules", path)
end

local function status(args)
    local flags, positional = parse(args)
    local cached = flags["--cached"]
    local conflicts = {}
    for _, conflict in ipairs(repo.read_conflicts()) do conflicts[conflict.path] = true end
    for _, submodule in ipairs(list_submodules(positional)) do
        local head = head_of(submodule)
        local sha = submodule.recorded or head or repo.ZERO_SHA
        local prefix = " "
        if conflicts[submodule.path] then
            prefix = "U"
        elseif not head or #submodule.folder:GetChildren() == 0 then
            prefix = "-"
        elseif submodule.recorded and head ~= submodule.recorded then
            prefix = "+"
            if not cached then sha = head end
        end
        print(prefix .. sha .. " " .. submodule.path .. (head and describe(submodule, sha) or ""))
        if flags["--recursive"] and head then
            bash.withContext(context_of(submodule), arguments.execute, "git", "submodule", "status", "--recursive")
        end
    end
end
commands.status = status

function commands.init(args)
    local _, positional = parse(args)
    for _, submodule in ipairs(list_submodules(positional)) do
        if not submodule.configured_url and submodule.gitmodules_url then
            local url = resolve_url(submodule.gitmodules_url)
            set_config_url(submodule.name, url)
            print("Submodule '" .. submodule.name .. "' (" .. url .. ") registered for path '" .. submodule.path .. "'")
        end
    end
end

function commands.update(args)
    local flags, positional = parse(args)
    if flags["--init"] then
        commands.init(positional)
    end
    local any = false
    for _, submodule in ipairs(list_submodules(positional)) do
        local url = submodule.configured_url and resolve_url(submodule.configured_url)
        if url and submodule.recorded then
            local target = submodule.recorded
            local changed = checkout_submodule(submodule, target, url, flags["-f"] or flags["--force"])
            if flags["--remote"] then
                --// move to the newest commit of the tracked branch instead of the recorded one
                local newest = bash.withContext(context_of(submodule), function()
                    pcall(Remote.fetch, "origin", true)
                    for _, branch in ipairs({submodule.branch or "main", "main", "master"}) do
                        local sha = Handlers.get_ref("refs/remotes/origin/" .. branch)
                        if sha then return sha end
                    end
                    return nil
                end)
                if newest and newest ~= Handlers.submodule_head(submodule.folder) then
                    bash.withContext(context_of(submodule), arguments.execute, "git", "switch", "--detach", newest)
                    target, changed = newest, true
                end
            end
            if changed then
                print("Submodule path '" .. submodule.path .. "': checked out '" .. target .. "'")
                any = true
            end
            if flags["--recursive"] then
                bash.withContext(context_of(submodule), arguments.execute, "git", "submodule", "update", "--init", "--recursive")
            end
        end
    end
    return any
end

function commands.deinit(args)
    local flags, positional = parse(args)
    local force = flags["-f"] or flags["--force"]
    if #positional == 0 and not flags["--all"] then
        error("fatal: Use '--all' if you really want to deinitialize all submodules", 0)
    end
    for _, submodule in ipairs(list_submodules(positional)) do
        if submodule.folder then
            if is_cloned(submodule) and not force then
                local changes = bash.withContext(context_of(submodule), repo.get_changes)
                if #changes > 0 then
                    error("error: Submodule work tree '" .. submodule.path .. "' contains local modifications; use '-f' to discard them", 0)
                end
            end
            submodule.folder:ClearAllChildren()
            print("Cleared directory '" .. submodule.path .. "'")
        end
        local conf = repo.read_config()
        if conf[section(submodule.name)] then
            conf[section(submodule.name)] = nil
            repo.write_config(conf)
            print("Submodule '" .. submodule.name .. "' (" .. tostring(submodule.url) .. ") unregistered for path '" .. submodule.path .. "'")
        end
    end
end

function commands.foreach(args)
    local recursive = false
    while args[1] == "--recursive" or args[1] == "--quiet" or args[1] == "-q" do
        if table.remove(args, 1) == "--recursive" then recursive = true end
    end
    if args[1] == "git" then table.remove(args, 1) end
    if #args == 0 then
        error("usage: git submodule foreach [--recursive] <git command>", 0)
    end
    for _, submodule in ipairs(list_submodules({})) do
        if submodule.folder and is_cloned(submodule) then
            print("Entering '" .. submodule.path .. "'")
            bash.withContext(context_of(submodule), function()
                arguments.execute("git", table.unpack(args))
                if recursive then
                    arguments.execute("git", "submodule", "foreach", "--recursive", "git", table.unpack(args))
                end
            end)
        end
    end
end

function commands.sync(args)
    local flags, positional = parse(args)
    for _, submodule in ipairs(list_submodules(positional)) do
        if submodule.gitmodules_url then
            local url = resolve_url(submodule.gitmodules_url)
            print("Synchronizing submodule url for '" .. submodule.path .. "'")
            if submodule.configured_url then
                set_config_url(submodule.name, url)
            end
            if is_cloned(submodule) and submodule.folder then
                bash.withContext(context_of(submodule), function()
                    arguments.execute("git", "remote", "set-url", "origin", url)
                    if flags["--recursive"] then
                        arguments.execute("git", "submodule", "sync", "--recursive")
                    end
                end)
            end
        end
    end
end

commands["set-url"] = function(args)
    local _, positional = parse(args)
    local path, url = positional[1], args[#args]
    if not path or not url or #positional < 2 then
        error("usage: git submodule set-url <path> <newurl>", 0)
    end
    local modules = read_gitmodules()
    local name = name_for_path(path, modules)
    if not modules[section(name)] then
        error("fatal: no submodule mapping found in .gitmodules for path '" .. path .. "'", 0)
    end
    modules[section(name)].url = url
    write_gitmodules(modules)
    commands.sync({path})
end

commands["set-branch"] = function(args)
    local flags, positional = parse(args, {["-b"] = "branch", ["--branch"] = "branch"})
    local path = positional[#positional]
    local modules = read_gitmodules()
    local name = path and name_for_path(path, modules)
    if not name or not modules[section(name)] then
        error("usage: git submodule set-branch (-b <branch> | -d) <path>", 0)
    end
    modules[section(name)].branch = (flags["-d"] or flags["--default"]) and nil or flags.branch
    write_gitmodules(modules)
end

function commands.summary(args)
    local _, positional = parse(args)
    for _, submodule in ipairs(list_submodules(positional)) do
        local head = head_of(submodule)
        if head and submodule.recorded and head ~= submodule.recorded then
            local count = bash.withContext(context_of(submodule), function()
                local seen = Handlers.ancestors(submodule.recorded)
                local n = 0
                for sha in pairs(Handlers.ancestors(head)) do
                    if not seen[sha] then n += 1 end
                end
                return n
            end)
            print("* " .. submodule.path .. " " .. submodule.recorded:sub(1, 7) .. "..." .. head:sub(1, 7) .. " (" .. count .. "):")
            bash.withContext(context_of(submodule), arguments.execute, "git", "log", "--oneline", submodule.recorded .. ".." .. head)
            print("")
        end
    end
end

function commands.absorbgitdirs()
    --// roGit always keeps submodule repositories in .git/modules
end

arguments.createArgument("git", "submodule", "", function(...)
    repo.require_root()
    local args = {...}
    local sub = args[1]
    if not sub or sub:sub(1, 1) == "-" then
        sub = "status"
    else
        table.remove(args, 1)
    end
    local command = commands[sub]
    if not command then
        error(USAGE, 0)
    end
    command(args)
end)

return {
    list = list_submodules,
}
