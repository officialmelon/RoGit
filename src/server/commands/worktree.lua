--[[
git worktree: more than one branch checked out at once.

The place itself is the main worktree. Others are folders in ServerStorage/RoGitWorktrees/<name>, holding a copy of
the services ("Workspace", "ReplicatedStorage", ...) at another commit. Their HEAD, index and in-progress state live
in .git/worktrees/<name>; branches, tags, config and objects are shared with the place.
Run commands in one with `git -C <name> <command>` (or `cd <name>` in the roGit terminal).
]]
local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")

local arguments = require(script.Parent.Parent.arguments)
local bash = require(script.Parent.Parent.bash)
local Handlers = require(script.Parent.Parent.libs.git_handlers)
local repo = require(script.Parent.Parent.libs.repo)
local output = require(script.Parent.Parent.libs.output)
local hooks = require(script.Parent.Parent.libs.hooks)

local function print(...)
    output.print(...)
end

local USAGE = [[usage: git worktree add [-f] [--detach] [-b <new-branch>] <name> [<commit-ish>]
   or: git worktree list [--porcelain]
   or: git worktree lock [--reason <string>] <name>
   or: git worktree move <name> <new-name>
   or: git worktree prune [-n] [-v]
   or: git worktree remove [-f] <name>
   or: git worktree unlock <name>]]

local function holder(create)
    local folder = ServerStorage:FindFirstChild(bash.WORKTREES_FOLDER)
    if not folder and create then
        folder = Instance.new("Folder")
        folder.Name = bash.WORKTREES_FOLDER
        folder.Parent = ServerStorage
    end
    return folder
end

local function find(name)
    for _, worktree in ipairs(repo.list_worktrees()) do
        if worktree.name and (worktree.name == name or worktree.path == name or worktree.path:gsub("%.", "/") == name) then
            return worktree
        end
    end
    error("fatal: '" .. tostring(name) .. "' is not a working tree", 0)
end

local function describe_head(head)
    local branch = head and head:match("^ref: refs/heads/(.+)$")
    if branch then
        return Handlers.get_ref("refs/heads/" .. branch), "[" .. branch .. "]"
    end
    return head, "(detached HEAD)"
end

local function subject(sha)
    local commit = sha and Handlers.read_commit(sha)
    return commit and commit.message:match("^[^\n]*") or ""
end

local function add(args)
    local new_branch, reset_branch, detach, force = nil, false, false, false
    local positional = {}
    local i = 1
    while i <= #args do
        local arg = args[i]
        if arg == "-b" or arg == "-B" then
            new_branch = args[i + 1]
            reset_branch = arg == "-B"
            i += 1
        elseif arg == "--detach" or arg == "-d" then
            detach = true
        elseif arg == "-f" or arg == "--force" then
            force = true
        elseif arg == "--checkout" or arg == "-q" or arg == "--quiet" or arg == "--track" or arg == "--guess-remote" then
            --// always checked out
        elseif arg:sub(1, 1) == "-" then
            error("error: unknown option `" .. arg .. "'\n" .. USAGE, 0)
        else
            table.insert(positional, arg)
        end
        i += 1
    end

    local path = positional[1]
    if not path then
        error(USAGE, 0)
    end
    local name = path:match("([^/%.]+)$") or path
    if not name:match("^[%w_%-]+$") then
        error("fatal: invalid worktree name '" .. name .. "' (use letters, digits, '-' and '_')", 0)
    end

    local main = repo.require_root()
    local states = main:FindFirstChild("worktrees")
    if (states and states:FindFirstChild(name)) or (holder() and holder():FindFirstChild(name)) then
        error("fatal: '" .. name .. "' already exists", 0)
    end

    local commitish = positional[2]
    local branch, target
    if new_branch then
        if Handlers.get_ref("refs/heads/" .. new_branch) and not reset_branch then
            error("fatal: a branch named '" .. new_branch .. "' already exists", 0)
        end
        target = Handlers.resolve_revision(commitish or "HEAD")
        branch = new_branch
    elseif commitish then
        target = Handlers.resolve_revision(commitish)
        if not detach and Handlers.get_ref("refs/heads/" .. commitish) then
            branch = commitish
        elseif not detach and Handlers.get_ref("refs/remotes/origin/" .. commitish) then
            --// like git: a branch that only exists on the remote gets a local tracking branch
            new_branch = commitish
            branch = commitish
        end
    else
        target = Handlers.resolve_revision("HEAD")
        if not detach then
            branch = name
            if not Handlers.get_ref("refs/heads/" .. name) then
                new_branch = name
            else
                target = Handlers.get_ref("refs/heads/" .. name)
            end
        end
    end
    if not target then
        error("fatal: invalid reference: " .. tostring(commitish or "HEAD"), 0)
    end
    local commit = Handlers.read_commit(target)
    if not commit then
        error("fatal: invalid reference: " .. tostring(commitish or "HEAD"), 0)
    end

    if branch and not new_branch and not force then
        local where = repo.branch_worktree(branch)
        if where or (bash.context == nil and Handlers.get_current_branch() == branch) then
            error("fatal: '" .. branch .. "' is already used by worktree at '" .. (where or "game") .. "'", 0)
        end
    end

    if new_branch then
        print("Preparing worktree (new branch '" .. new_branch .. "')")
        Handlers.update_ref("refs/heads/" .. new_branch, target, "branch: Created from " .. (commitish or "HEAD"))
        if commitish and Handlers.get_ref("refs/remotes/origin/" .. commitish) and commitish == new_branch then
            repo.set_upstream(new_branch, "origin", commitish)
        end
    elseif branch then
        print("Preparing worktree (checking out '" .. branch .. "')")
    else
        print("Preparing worktree (detached HEAD " .. target:sub(1, 7) .. ")")
    end

    local state = bash.createFolder(main, "worktrees/" .. name)
    local root = Instance.new("Folder")
    root.Name = name
    root.Parent = holder(true)
    bash.writeFile(state, "HEAD", branch and ("ref: refs/heads/" .. branch) or target)
    bash.writeFile(state, "index", "")
    bash.writeFile(state, "gitdir", root:GetFullName())
    bash.writeFile(state, "commondir", "../..")

    local context = {kind = "worktree", name = name, root = root}
    local ok, err = pcall(bash.withContext, context, function()
        Handlers.append_reflog("HEAD", nil, target, "worktree add: " .. name)
        repo.checkout_tree(commit.tree)
        hooks.notify("post-checkout", {args = {repo.ZERO_SHA, target, "1"}})
    end)
    if not ok then
        root:Destroy()
        state:Destroy()
        error(err, 0)
    end
    print("HEAD is now at " .. target:sub(1, 7) .. " " .. subject(target))
    print("Use it with: git -C " .. name .. " <command>   (or 'cd " .. name .. "' in the roGit terminal)")
end

local function is_dirty(worktree)
    if not worktree.root then return false end
    local changes = bash.withContext({kind = "worktree", name = worktree.name, root = worktree.root}, repo.get_changes)
    return #changes > 0
end

local function remove(args)
    local force = 0
    local name
    for _, arg in ipairs(args) do
        if arg == "-f" or arg == "--force" then
            force += 1
        elseif arg:sub(1, 1) ~= "-" then
            name = arg
        end
    end
    if not name then error(USAGE, 0) end
    local worktree = find(name)
    if worktree.locked and force < 2 then
        error("fatal: cannot remove a locked working tree" .. (worktree.locked ~= "" and (", lock reason: " .. worktree.locked) or "")
            .. "\nuse 'remove -f -f' to override or unlock first", 0)
    end
    if force == 0 and is_dirty(worktree) then
        error("fatal: '" .. worktree.name .. "' contains modified or untracked instances, use --force to delete it", 0)
    end
    if bash.context and bash.context.kind == "worktree" and bash.context.name == worktree.name then
        error("fatal: '" .. worktree.name .. "' is the current worktree; run this from another one", 0)
    end
    if worktree.root then worktree.root:Destroy() end
    worktree.state:Destroy()
end

local function list(args)
    local porcelain = table.find(args, "--porcelain") ~= nil
    local verbose = table.find(args, "-v") ~= nil or table.find(args, "--verbose") ~= nil
    local rows = repo.list_worktrees()
    local width = 0
    for _, worktree in ipairs(rows) do
        width = math.max(width, #worktree.path)
    end
    for _, worktree in ipairs(rows) do
        local sha, label = describe_head(worktree.head)
        if porcelain then
            print("worktree " .. worktree.path)
            print("HEAD " .. tostring(sha or repo.ZERO_SHA))
            local branch = worktree.head and worktree.head:match("^ref: (refs/heads/.+)$")
            print(branch and ("branch " .. branch) or "detached")
            if worktree.locked then print("locked" .. (worktree.locked ~= "" and (" " .. worktree.locked) or "")) end
            if worktree.name and not worktree.root then print("prunable gitdir file points to non-existent location") end
            print("")
        else
            local line = string.format("%-" .. width .. "s  %s %s", worktree.path, sha and sha:sub(1, 7) or "0000000", label)
            if worktree.locked then
                line ..= " locked"
                if verbose and worktree.locked ~= "" then line ..= "\n\tlocked: " .. worktree.locked end
            end
            if worktree.name and not worktree.root then line ..= " prunable" end
            print(line)
        end
    end
end

local function prune(args)
    local dry = table.find(args, "-n") ~= nil or table.find(args, "--dry-run") ~= nil
    local verbose = dry or table.find(args, "-v") ~= nil or table.find(args, "--verbose") ~= nil
    for _, worktree in ipairs(repo.list_worktrees()) do
        if worktree.name and not worktree.root and not worktree.locked then
            if verbose then
                print("Removing worktrees/" .. worktree.name .. ": gitdir file points to non-existent location")
            end
            if not dry then worktree.state:Destroy() end
        end
    end
end

arguments.createArgument("git", "worktree", "", function(...)
    repo.require_root()
    local args = {...}
    local sub = table.remove(args, 1) or "list"

    if sub == "add" then
        add(args)
    elseif sub == "list" then
        list(args)
    elseif sub == "remove" then
        remove(args)
    elseif sub == "prune" then
        prune(args)
    elseif sub == "lock" then
        local reason, name = "", nil
        local i = 1
        while i <= #args do
            if args[i] == "--reason" then reason = args[i + 1] or "" i += 1
            elseif args[i]:sub(1, 1) ~= "-" then name = args[i] end
            i += 1
        end
        local worktree = find(name)
        if worktree.locked then
            error("fatal: '" .. worktree.name .. "' is already locked" .. (worktree.locked ~= "" and (", reason: " .. worktree.locked) or ""), 0)
        end
        bash.writeFile(worktree.state, "locked", reason)
    elseif sub == "unlock" then
        local worktree = find(args[1])
        if not worktree.locked then
            error("fatal: '" .. worktree.name .. "' is not locked", 0)
        end
        worktree.state:FindFirstChild("locked"):Destroy()
    elseif sub == "move" then
        local worktree = find(args[1])
        local new_name = args[2]
        if not new_name or not new_name:match("^[%w_%-]+$") then
            error(USAGE, 0)
        end
        if worktree.locked then
            error("fatal: cannot move a locked working tree", 0)
        end
        if worktree.state.Parent:FindFirstChild(new_name) then
            error("fatal: '" .. new_name .. "' already exists", 0)
        end
        worktree.state.Name = new_name
        if worktree.root then
            worktree.root.Name = new_name
            bash.writeFile(worktree.state, "gitdir", worktree.root:GetFullName())
        end
    elseif sub == "repair" then
        for _, worktree in ipairs(repo.list_worktrees()) do
            if worktree.name and worktree.root then
                bash.writeFile(worktree.state, "gitdir", worktree.root:GetFullName())
            end
        end
    else
        error(USAGE, 0)
    end
end)

return {}
