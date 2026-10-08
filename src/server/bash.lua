local Bash = {}

local ServerStorage = game:GetService("ServerStorage")

local conf = {
    gitRoot = ServerStorage
}

--// Services whose contents are tracked. A service Studio doesn't have is simply skipped.
Bash.trackingRoot = {}
for _, serviceName in ipairs({
    "Workspace",
    "ReplicatedStorage",
    "ReplicatedFirst",
    "ServerScriptService",
    "ServerStorage",
    "StarterGui",
    "Lighting",
    "StarterPack",
    "StarterPlayer",
    "SoundService",
    "AdService",
    "LocalizationService",
    "PhysicsService",
    "TextService",
    "Teams",
    "MaterialService",
    "TextChatService",
}) do
    local ok, service = pcall(function()
        return game:GetService(serviceName)
    end)
    if ok and service then
        table.insert(Bash.trackingRoot, service)
    end
end

--[[
Kind-of emulates "bash"?
Needs a real filesystem setup/filesystem navigation commands.
]]

--[[
The repository commands act on. nil is the place itself (.git in ServerStorage, the services as the work tree).
Other contexts (see `git -C`):
  worktree:  {kind = "worktree", name, root = Folder}, its own HEAD/index/state in .git/worktrees/<name>
  submodule: {kind = "submodule", name, root = Folder}, a whole repository in .git/modules/<name>
Objects always live in the main .git, so every context can read every commit.
]]
Bash.context = nil
Bash.WORKTREES_FOLDER = "RoGitWorktrees"

local contextListeners = {}

--[[
Runs `callback` when the context changes (caches that depend on the repository register here).
]]
function Bash.onContextChanged(callback)
    table.insert(contextListeners, callback)
end

--[[
Runs fn(...) with `context` active and restores the previous one afterwards, even when fn errors.
]]
function Bash.withContext(context, fn, ...)
    local previous = Bash.context
    Bash.context = context
    for _, listener in ipairs(contextListeners) do listener() end
    local results = table.pack(pcall(fn, ...))
    Bash.context = previous
    for _, listener in ipairs(contextListeners) do listener() end
    if not results[1] then
        error(results[2], 0)
    end
    return table.unpack(results, 2, results.n)
end

--[[
The main repository (ServerStorage/.git), whatever the context.
]]
function Bash.getMainGitFolder()
    return conf.gitRoot:FindFirstChild(".git")
end

--[[
Returns our git root folder: config, refs, hooks, ... of the active repository.
]]
function Bash.getGitFolderRoot()
    local context = Bash.context
    if context and context.kind == "submodule" then
        local main = Bash.getMainGitFolder()
        local modules = main and main:FindFirstChild("modules")
        return modules and modules:FindFirstChild(context.name) or nil
    end
    return Bash.getMainGitFolder()
end

--[[
Where the object store is (always the main repository).
]]
function Bash.getObjectsRoot()
    return Bash.getMainGitFolder() or Bash.getGitFolderRoot()
end

--[[
The folder with the per-worktree files (HEAD, index, ...) of the active worktree, or nil for the main one.
]]
function Bash.getWorktreeStateFolder()
    local context = Bash.context
    if context and context.kind == "worktree" then
        local main = Bash.getMainGitFolder()
        local worktrees = main and main:FindFirstChild("worktrees")
        return worktrees and worktrees:FindFirstChild(context.name) or nil
    end
    return nil
end

--// files each worktree has its own copy of (everything else in .git is shared)
local PER_WORKTREE = {
    HEAD = true, index = true, ORIG_HEAD = true, MERGE_HEAD = true, MERGE_MSG = true, MERGE_MODE = true,
    CHERRY_PICK_HEAD = true, REVERT_HEAD = true, AUTO_MERGE = true, COMMIT_EDITMSG = true,
    last_commit_index = true, EDITOR = true,
}

function Bash.isPerWorktreePath(path)
    local first = path:match("^[^/]*")
    return PER_WORKTREE[first] == true or first:match("^ROGIT_") ~= nil or first:match("^BISECT_") ~= nil
        or path == "logs/HEAD" or path:match("^refs/bisect") ~= nil
end

--[[
Inside a worktree, paths like "HEAD" or "index" under the git folder go to the worktree's own folder.
]]
local function redirect(parent, name)
    local state = Bash.context and Bash.context.kind == "worktree" and Bash.getWorktreeStateFolder()
    if state and name and parent == Bash.getMainGitFolder() and Bash.isPerWorktreePath(name) then
        return state
    end
    return parent
end
Bash.resolveGitParent = redirect

--[[
The instance whose children are the top of the work tree: game, or the folder of a worktree/submodule.
]]
function Bash.getWorkRoot()
    return Bash.context and Bash.context.root or game
end

--[[
A top level entry of the work tree ("Workspace", "ServerStorage", ...).
In a worktree or submodule these are plain folders, made on demand when `create` is set.
]]
function Bash.getServiceRoot(name, create)
    local root = Bash.getWorkRoot()
    if root == game then
        local found = game:FindFirstChild(name)
        if not found then
            pcall(function() found = game:GetService(name) end)
        end
        return found
    end
    local found = root:FindFirstChild(name)
    if not found and create then
        found = Instance.new("Folder")
        found.Name = name
        found.Parent = root
    end
    return found
end

--[[
The containers whose contents are tracked: the services for the place, the children of a worktree/submodule folder.
]]
function Bash.getTrackedRoots()
    local root = Bash.getWorkRoot()
    if root == game then
        return Bash.trackingRoot
    end
    local children = root:GetChildren()
    table.sort(children, function(a, b) return a.Name < b.Name end)
    return children
end

--[[
The name used for .rogitignore matching: like GetFullName(), but relative to the work tree.
]]
function Bash.relativeName(instance)
    local root = Bash.getWorkRoot()
    local full = instance:GetFullName()
    if root == game then
        return full
    end
    local prefix = root:GetFullName() .. "."
    if full:sub(1, #prefix) == prefix then
        return full:sub(#prefix + 1)
    end
    return full
end

--[[
Instances that are never part of the work tree: the .git folder, and (for the place) the folder holding other worktrees.
]]
function Bash.isInternal(instance)
    local main = Bash.getMainGitFolder()
    if main and (instance == main or instance:IsDescendantOf(main)) then
        return true
    end
    if Bash.getWorkRoot() == game then
        local worktrees = conf.gitRoot:FindFirstChild(Bash.WORKTREES_FOLDER)
        if worktrees and (instance == worktrees or instance:IsDescendantOf(worktrees)) then
            return true
        end
    end
    return false
end

--[[
Whether an instance is the top of the work tree or a service, which checkouts never delete.
]]
function Bash.isProtected(instance)
    local root = Bash.getWorkRoot()
    return instance == root or instance == game or (root == game and instance.Parent == game)
end

--[[
Does file exist?
]]
function Bash.exists(parent, name)
    parent = redirect(parent, name)
    return parent:FindFirstChild(name) ~= nil
end

--[[
Creates the git root folder in ServerStorage (or .git/modules/<name> for a submodule)
]]
function Bash.createGitFolderRoot()
    local context = Bash.context
    local parent, name = ServerStorage, ".git"
    if context and context.kind == "submodule" then
        parent = Bash.createFolder(Bash.getMainGitFolder(), "modules")
        name = context.name
    end
    local root = Instance.new("Folder")
    root.Name = name
    root.Parent = parent
    return root
end

--[[
Create a "file" using some stringvalues (or folder + stringvalues if too large!)
tbh this is probably a hack sort of thing for now>
]]
function Bash.createFile(parent, name, content)
    assert(typeof(parent) == "Instance", "Parent doesnt exist, or not instance!")
    assert(name, "File name is nil!")
    assert(content, "Content is nil!")
    parent = redirect(parent, name)

    if parent:FindFirstChild(name) then 
        return parent:FindFirstChild(name)
    end

    --// Small content
    if #content <= 199000 then
        local str = Instance.new("StringValue")
        str.Parent = parent
        str.Value = content
        str.Name = name
        return str
    --// Big content, split it up!
    else
        local folder = Instance.new("Folder")
        folder.Name = name
        folder.Parent = parent
        
        local chunks = math.ceil(#content / 199000)
        for i = 1, chunks do
            local chunkStr = Instance.new("StringValue")
            chunkStr.Name = tostring(i)
            chunkStr.Value = string.sub(content, (i-1)*199000 + 1, i*199000)
            chunkStr.Parent = folder
        end
        return folder
    end
end

--[[
Gets the directory/file
]]
function Bash.getDirectoryOrFile(parent, name)
    -- Quick checks
    assert(typeof(parent) == "Instance", "Parent doesnt exist, or not instance!")
    parent = redirect(parent, name)

    for _, rec in string.split(name, "/") do
        if parent:FindFirstChild(rec) then
            parent = parent:FindFirstChild(rec)
        else
            return nil
        end
    end

    return parent
end

--[[
Gets the contents of a file.
if file is split up into folders? we piece chunks together and return that.
]]
function Bash.getFileContents(parent, name)
    assert(typeof(parent) == "Instance", "Parent doesnt exist, or not instance!")
    assert(name, "File name is nil!")
    parent = redirect(parent, name)
    
    local file = parent:FindFirstChild(name)
    
    if not file then return nil end

    if file:IsA("StringValue") then
        return file.Value
    elseif file:IsA("Folder") then
        local result = {}
        local i = 1
        while true do
            local chunk = file:FindFirstChild(tostring(i))
            if chunk and chunk:IsA("StringValue") then
                table.insert(result, chunk.Value)
                i = i + 1
            else
                break
            end
        end
        return table.concat(result, "")
    end

    return nil
end

--[[
Modifies the contents of a file (or split file)
]]
function Bash.modifyFileContents(parent, name, content)
    assert(typeof(parent) == "Instance", "Parent doesnt exist, or not instance!")
    assert(name, "File name is nil!")
    assert(content, "Content is nil!")
    parent = redirect(parent, name)

    local str = parent:FindFirstChild(name)
    if not str then
        warn("Bash: Attempting to modify non-existent file '" .. name .. "' in '" .. parent:GetFullName() .. "'. Creating instead.")
        return Bash.createFile(parent, name, content)
    end
    
    if str:IsA("StringValue") then
        if #content <= 199000 then
            str.Value = content
            return str
        else
            str:Destroy()
            return Bash.createFile(parent, name, content)
        end
    elseif str:IsA("Folder") then
        if #content <= 199000 then
            str:Destroy()
            return Bash.createFile(parent, name, content)
        else
            str:ClearAllChildren()
            local chunks = math.ceil(#content / 199000)
            for i = 1, chunks do
                local chunkStr = Instance.new("StringValue")
                chunkStr.Name = tostring(i)
                chunkStr.Value = string.sub(content, (i-1)*199000 + 1, i*199000)
                chunkStr.Parent = str
            end
            return str
        end
    end
    return nil
end

--[[
Writes a file, creating it when it doesn't exist yet.
]]
function Bash.writeFile(parent, name, content)
    parent = redirect(parent, name)
    if parent:FindFirstChild(name) then
        return Bash.modifyFileContents(parent, name, content)
    end
    return Bash.createFile(parent, name, content)
end

--[[
Creates a folder at specific parent/name
]]
function Bash.createFolder(parent, name)
    assert(typeof(parent) == "Instance", "Parent doesnt exist, or not instance!")
    parent = redirect(parent, name)

    --// Recursive folder creation (hierarchy)
    for _, rec in string.split(name, "/") do
        if parent:FindFirstChild(rec) then
            parent = parent:FindFirstChild(rec)
        else
            --// Create folder
            local fldr = Instance.new("Folder")
            fldr.Parent = parent
            fldr.Name = rec
            parent = fldr
        end
    end

    return parent
end

return Bash