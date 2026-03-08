
--[[
This is an extremely large file that should be cleaned/split for future reference.
This holds all the commands for `git` & most functionality.

]]
local git = {}

local HttpService = game:GetService("HttpService")

local config = require(script.Parent.config)
local arguments = require(script.Parent.arguments)
local git_remote = require(script.Parent.libs.git_remote)

local hashlib = require(script.Parent.libs.hashlib)
local _zlib = require(script.Parent.libs.zlib)
local bash = require(script.Parent.bash)
local git_proto = require(script.Parent.libs.git_proto)
local ini_parser = require(script.Parent.libs.ini_parser)
local Handlers = require(script.Parent.libs.git_handlers)
local instances = require(script.Parent.libs.instances)
local Utilities = require(script.Parent.libs.utilities)
local Auth = require(script.Parent.libs.localstore)
local Requests = require(script.Parent.libs.requests)
local Remote = require(script.Parent.libs.git_remote)

local _ignore_patterns = nil
local terminal_prompt_callback = nil

local ROGIT_ID = "_rogit_id"
local ACTIVE_PLUGIN = nil

--[[
Set plugin for module.
]]
function git.setPlugin(plugin)
    ACTIVE_PLUGIN = plugin
    Auth.ACTIVE_PLUGIN = plugin
end

--[[
Replace callback for the prompt
]]
function git.replacePromptCallback(prompt_cb)
    terminal_prompt_callback = prompt_cb
    Requests.setPromptCallback(prompt_cb)
end

--[[
Replace some output commands (print, warn, error) with custom plugin implementatinos
]]
function git.replaceOutputCallback(callback, warncallback, errcallback)
    print = callback
    warn = warncallback
    error = errcallback
end

--[[
Checks if a branch name is valid.
]]
local function is_valid_branch_name(name)
    if not name or name == "" then return false end
    if name:match("^-") then return false end
    if name:match("[%s~^:?*[\\]]") then return false end
    if name:match("%.%.") then return false end
    return true
end

local function compute_blob_sha(content)
    return hashlib.sha1("blob " .. tostring(#content) .. "\0" .. content)
end

-- Returns tracked files that differ between index and current workspace.
local function collect_worktree_changes(index)
    local modified = {}
    local deleted = {}

    for path, data in pairs(index) do
        Utilities.roYield()
        local clean_path = path:match("^(.-)/%.properties$") or path
        local currObj = Utilities.parse_path(clean_path)

        if not currObj then
            table.insert(deleted, path)
        else
            local serialized = instances.serialize_instance(currObj)
            local current_sha = compute_blob_sha(serialized)
            if current_sha ~= data.sha then
                table.insert(modified, path)
            end
        end
    end

    table.sort(modified)
    table.sort(deleted)
    return modified, deleted
end

-- Returns true when ancestor_sha is reachable from descendant_sha.
local function is_ancestor_commit(ancestor_sha, descendant_sha)
    if not ancestor_sha or not descendant_sha then
        return false
    end
    if ancestor_sha == descendant_sha then
        return true
    end

    local queue = {descendant_sha}
    local visited = {}
    local cursor = 1

    while cursor <= #queue do
        local sha = queue[cursor]
        cursor += 1

        if not visited[sha] then
            visited[sha] = true
            local obj = Handlers.read_object(sha)
            if obj and obj.type == "commit" then
                for parent in obj.content:gmatch("\nparent (%x+)") do
                    if parent == ancestor_sha then
                        return true
                    end
                    table.insert(queue, parent)
                end
            end
        end
        Utilities.roYield()
    end

    return false
end

-- Returns a combined table of all active working tree/index changes for the UI.
function git.get_changes()
    local index = Handlers.read_index()

    local last_index = {}
    local last_index_str = bash.getFileContents(bash.getGitFolderRoot(), "last_commit_index")
    if last_index_str and last_index_str ~= "" then
        last_index = HttpService:JSONDecode(last_index_str)
    end

    local changes = {}
    local seen_paths = {}

    -- STAGED (Compared to last commit)
    for path, data in pairs(index) do
        if not last_index[path] then
            table.insert(changes, {path = path, status = "A"})
            seen_paths[path] = true
        elseif last_index[path].sha ~= data.sha then
            table.insert(changes, {path = path, status = "M"})
            seen_paths[path] = true
        end
    end
    for path, _ in pairs(last_index) do
        if not index[path] then
            table.insert(changes, {path = path, status = "D"})
            seen_paths[path] = true
        end
    end

    -- UNSTAGED (Compared to index)
    local unstaged_modified, unstaged_deleted = collect_worktree_changes(index)
    for _, path in ipairs(unstaged_modified) do
         if not seen_paths[path] then
             table.insert(changes, {path = path, status = "M"})
             seen_paths[path] = true
         end
    end
    for _, path in ipairs(unstaged_deleted) do
         if not seen_paths[path] then
             table.insert(changes, {path = path, status = "D"})
             seen_paths[path] = true
         end
    end

    -- UNTRACKED (Files not in index at all)
    local untracked = {}
    local function traverse_untracked_for_changes(parent, path_prefix, seen_ids)
        local child_counts = {}
        for _, child in ipairs(parent:GetChildren()) do
            if not Handlers.is_ignored(child:GetFullName()) and child ~= bash.getGitFolderRoot() and not child:IsDescendantOf(bash.getGitFolderRoot()) then
                child_counts[child.Name] = (child_counts[child.Name] or 0) + 1
            end
        end

        local seen_local = {}
        for _, child in ipairs(parent:GetChildren()) do
            Utilities.roYield()
            if not Handlers.is_ignored(child:GetFullName()) and child ~= bash.getGitFolderRoot() and not child:IsDescendantOf(bash.getGitFolderRoot()) then
                local rogit_id = child:GetAttribute(ROGIT_ID)
                local collisionBase = child.Name
                local virtualName = child.Name
                
                if child_counts[child.Name] > 1 then
                    local id_to_use = rogit_id
                    if not id_to_use or id_to_use == "" or seen_ids[id_to_use] then
                        id_to_use = HttpService:GenerateGUID(false)
                        child:SetAttribute(ROGIT_ID, id_to_use)
                    end
                    seen_ids[id_to_use] = true
                    
                    seen_local[child.Name] = (seen_local[child.Name] or 0) + 1
                    virtualName = collisionBase .. " [" .. tostring(seen_local[child.Name]) .. "]"
                end
                
                local my_path = path_prefix == "" and virtualName or (path_prefix .. "/" .. virtualName)
                
                local hasValidChildren = false
                for _, sub in ipairs(child:GetChildren()) do
                    if sub ~= bash.getGitFolderRoot() and not Handlers.is_ignored(sub:GetFullName()) and not sub:IsDescendantOf(bash.getGitFolderRoot()) then
                        hasValidChildren = true
                        break
                    end
                end
                
                local index_path = hasValidChildren and (my_path .. "/.properties") or my_path
                if not index[index_path] and not index[my_path] then
                    untracked[my_path] = true
                end
                
                traverse_untracked_for_changes(child, my_path, seen_ids)
            end
        end
    end

    local global_seen = {}
    for _, child in ipairs(bash.trackingRoot) do
        local child_path = child.Name
        traverse_untracked_for_changes(child, child_path, global_seen)
    end
    
    for path, _ in pairs(untracked) do
        if not seen_paths[path] then
            table.insert(changes, {path = path, status = "U"})
        end
    end

    table.sort(changes, function(a, b)
        return a.path < b.path
    end)
    return changes
end


-- Create command
arguments.createCommand("git", function(...)
    arguments.execute("git", "help", ...)
end)

--[[
Commands:
version
v

Outputs the version to the console.
]]
arguments.createArgument("git", "version", "v", function ()
    print(config.version)
end)

--[[
Commands:
help
h

Outputs all possible commands.
]]
arguments.createArgument("git", "help", "h", function (...)
    local args = {...}
    if #args > 0 then
        local cmd = args[1]
        local help_messages = {
            add = "git-add - Add file contents to the index.\n\nUsage: git add [options] [--] <pathspec>...\n\n    -n, --dry-run     dry run\n    -f, --force       allow adding otherwise ignored files",
            commit = "git-commit - Record changes to the repository.\n\nUsage: git commit [-m <msg>]\n\n    -m, --message <msg>   commit message",
            push = "git-push - Update remote refs along with associated objects.\n\nUsage: git push [<options>] [<repository> [<refspec>...]]\n\n    -u, --set-upstream    set upstream for git pull/status",
            pull = "git-pull - Fetch from and integrate with another repository or a local branch.\n\nUsage: git pull [<options>] [<repository> [<refspec>...]]",
            status = "git-status - Show the working tree status.\n\nUsage: git status",
            -- branch = "git-branch - List, create, or delete branches.\n\nUsage: git branch [<branchname>]\n       git branch -d <branchname>\n       git branch -m <oldbranch> <newbranch>",
            -- switch = "git-switch - Switch branches.\n\nUsage: git switch [<options>] <branch>\n\n    -c, --create <branch>  create and switch to a new branch",
            clone = "git-clone - Clone a repository into a new directory.\n\nUsage: git clone <repository>",
            fetch = "git-fetch - Download objects and refs from another repository.\n\nUsage: git fetch [<options>] [<repository>]",
            reset = "git-reset - Reset current HEAD to the specified state.\n\nUsage: git reset [--soft | --mixed | --hard] [<commit>]\n\n    --hard       reset HEAD, index and working tree",
            rm = "git-rm - Remove files from the working tree and from the index.\n\nUsage: git rm [-r] <file>...",
            diff = "git-diff - Show changes between commits, commit and working tree, etc.\n\nUsage: git diff",
            merge = "git-merge - Join two or more development histories together.\n\nUsage: git merge <commit-or-branch>",
            mv = "git-mv - Move or rename a file, a directory, or a symlink.\n\nUsage: git mv <source> <destination>",
            restore = "git-restore - Restore working tree files.\n\nUsage: git restore <pathspec>",
            remote = "git-remote - Manage set of tracked repositories.\n\nUsage: git remote [-v | --verbose]\n       git remote add [-f] <name> <url>\n       git remote remove <name>\n       git remote set-url <name> <newurl>",
            init = "git-init - Create an empty Git repository or reinitialize an existing one.\n\nUsage: git init [-q | --quiet] [-b <branch-name>]",
            log = "git-log - Show commit logs.\n\nUsage: git log [<options>]",
            config = "git-config - Get and set repository or global options.\n\nUsage: git config [--global] <name> [<value>]",
            version = "git-version - Show the RoGit version information.\n\nUsage: git version",
            credential = "git-credential - Prompt for and cache user credentials.\n\nUsage: git credential (fill|approve|reject)",
            checkout = "git-checkout - Switch branches or restore working tree files.\n\nUsage: git checkout [-b] <branchname>\n       git checkout <pathspec>..."
        }

        if cmd == "-a" or cmd == "--all" then
            local cmds = {}
            for k, _ in pairs(arguments.returnAllArguments()) do
                table.insert(cmds, k)
            end
            table.sort(cmds)
            print("available subcommands:\n  " .. table.concat(cmds, "\n  "))
            return
        elseif cmd == "-g" or cmd == "--guides" then
            print("RoGit concept guides are not yet implemented.")
            return
        elseif cmd == "git" then
            -- Fall through to main help message!
        elseif help_messages[cmd] then
            print(help_messages[cmd])
            return
        else
            print("No manual entry for git-" .. cmd)
            return
        end
    end

    print([=[usage: git [--version] [--help] [-C <path>] [-c <name>=<value>]
           [--exec-path[=<path>]] [--html-path] [--man-path] [--info-path]
           [-p | --paginate | -P | --no-pager] [--no-replace-objects] [--bare]
           [--git-dir=<path>] [--work-tree=<path>] [--namespace=<name>]
           <command> [<args>]

These are common Git commands used in various situations:

start a working area (see also: git help tutorial)
   clone     Clone a repository into a new directory
work on the current change (see also: git help everyday)
   add       Add file contents to the index
   mv        Move or rename a file, a directory, or a symlink
   restore   Restore working tree files
   rm        Remove files from the working tree and from the index

examine the history and state (see also: git help revisions)
   diff      Show changes between commits, commit and working tree, etc
   log       Show commit logs
   status    Show the working tree status

grow, mark and tweak your common history
   branch    List, create, or delete branches
   checkout  Switch branches or restore working tree files
   commit    Record changes to the repository
   switch    Switch branches
   merge     Join two or more development histories together
   rebase    Reapply commits on top of another base tip (NOT IMPLEMENTED YET)
   reset     Reset current HEAD to the specified state

collaborate (see also: git help workflows)
   fetch     Download objects and refs from another repository
   pull      Fetch from and integrate with another repository or a local branch
   push      Update remote refs along with associated objects
   remote    Manage set of tracked repositories

Other commands:
   init      Create an empty Git repository or reinitialize an existing one
   config    Get and set repository or global options

'git help -a' and 'git help -g' list available subcommands and some
concept guides. See 'git help <command>' or 'git help <concept>'
to read about a specific subcommand or concept.
See 'git help git' for an overview of the system.]=])
end)

--[[
commands:
diff

View diff throughout commits.
]]
arguments.createArgument("git", "diff", "", function()
    assert(bash.getGitFolderRoot(), "fatal: not a git repository")
    local index = Handlers.read_index()
    
    local has_diff = false
    for path, data in pairs(index) do
        local target_path = path:match("^(.-)/%.properties$") or path
        local currObj = Utilities.parse_path(target_path)

        if not currObj then
            print("\27[31mD\27[0m  " .. path)
            has_diff = true
        else
            local serialized = instances.serialize_instance(currObj)
            local current_sha = compute_blob_sha(serialized)
            if current_sha ~= data.sha then
                print("\27[33mM\27[0m  " .. path)
                print("--- a/" .. path)
                print("+++ b/" .. path)
                print("@@ -1 +1 @@")
                print("- " .. data.sha:sub(1,7) .. " (Index state)")
                print("+ " .. current_sha:sub(1,7) .. " (Workspace state)")
                has_diff = true
            end
        end
    end

    local untracked = {}
    local function traverse_untracked_for_diff(parent, path_prefix, seen_ids)
        local child_counts = {}
        for _, child in ipairs(parent:GetChildren()) do
            if not Handlers.is_ignored(child:GetFullName()) and child ~= bash.getGitFolderRoot() and not child:IsDescendantOf(bash.getGitFolderRoot()) then
                child_counts[child.Name] = (child_counts[child.Name] or 0) + 1
            end
        end

        local seen_local = {}
        for _, child in ipairs(parent:GetChildren()) do
            Utilities.roYield()
            if not Handlers.is_ignored(child:GetFullName()) and child ~= bash.getGitFolderRoot() and not child:IsDescendantOf(bash.getGitFolderRoot()) then
                local rogit_id = child:GetAttribute(ROGIT_ID)
                local collisionBase = child.Name
                local virtualName = child.Name
                
                if child_counts[child.Name] > 1 then
                    local id_to_use = rogit_id
                    if not id_to_use or id_to_use == "" or seen_ids[id_to_use] then
                        id_to_use = HttpService:GenerateGUID(false)
                        child:SetAttribute(ROGIT_ID, id_to_use)
                    end
                    seen_ids[id_to_use] = true
                    
                    seen_local[child.Name] = (seen_local[child.Name] or 0) + 1
                    virtualName = collisionBase .. " [" .. tostring(seen_local[child.Name]) .. "]"
                end
                
                local my_path = path_prefix == "" and virtualName or (path_prefix .. "/" .. virtualName)
                
                local hasValidChildren = false
                for _, sub in ipairs(child:GetChildren()) do
                    if sub ~= bash.getGitFolderRoot() and not Handlers.is_ignored(sub:GetFullName()) and not sub:IsDescendantOf(bash.getGitFolderRoot()) then
                        hasValidChildren = true
                        break
                    end
                end
                
                local index_path = hasValidChildren and (my_path .. "/.properties") or my_path
                if not index[index_path] and not index[my_path] then
                    untracked[my_path] = true
                end
                
                traverse_untracked_for_diff(child, my_path, seen_ids)
            end
        end
    end

    local global_seen = {}
    for _, child in ipairs(bash.trackingRoot) do
        local child_path = child.Name
        traverse_untracked_for_diff(child, child_path, global_seen)
    end
    
    for path, _ in pairs(untracked) do
        print("\27[31m??\27[0m " .. path)
        has_diff = true
    end
    if not has_diff then
        print("Everything up-to-date with index.")
    end
end)

--[[
commands:
rebase

stubbed.
]]
arguments.createArgument("git", "rebase", "", function()
    error("fatal: 'rebase' requires interactive graph rewrites which are complex in Luau. Please use 'git merge' instead.")
end)

arguments.createArgument("git", "merge", "", function(...)
    local tuple = {...}
    local branch = tuple[1]

    if not branch then
        error("fatal: No commit specified and merge.defaultToUpstream not set.")
        return
    end

    local root = bash.getGitFolderRoot()
    if not root then
        error("fatal: not a git repository (or any of the parent directories): .git")
        return
    end
    
    local target_sha = Handlers.get_ref("refs/heads/" .. branch) or Handlers.get_ref("refs/remotes/origin/" .. branch)
    if not target_sha or target_sha == "" then
        print("merge: " .. branch .. " - not something we can merge")
        return
    end
    
    local head_sha = Handlers.get_ref("HEAD")
    if head_sha == target_sha then
        print("Already up to date.")
        return
    end
    
    warn("roGit does not fully support automatic branch merging yet.")
    print("If you want to overwrite your current branch with '" .. branch .. "', run: git reset --hard " .. branch)
end)

--[[
commands:
mv

moves instance path
]]
arguments.createArgument("git", "mv", "", function(...)
    local tuple = {...}
    local source = tuple[1]
    local destination = tuple[2]

    if not source or not destination then
        error("fatal: bad source, source=")
        return
    end

    assert(bash.getGitFolderRoot(), "fatal: not a git repository")
    
    local source_path_cleaned = source:gsub("^game[./]", ""):gsub("%.", "/")
    local dest_path_cleaned = destination:gsub("^game[./]", ""):gsub("%.", "/")
    
    local sourceObj = Utilities.parse_path(source_path_cleaned)
    assert(sourceObj, "fatal: bad source, source=" .. source_path_cleaned)
    
    local destObj, destName, destSegments = Utilities.parse_path(dest_path_cleaned)
    if destObj then
        sourceObj.Parent = destObj
    else
        local parentPath = table.concat(destSegments, "/", 1, #destSegments - 1)
        local parentObj = Utilities.parse_path(parentPath)
        assert(parentObj, "fatal: destination parent does not exist")
        sourceObj.Parent = parentObj
        sourceObj.Name = destName
    end
    
    print("Moved '" .. source_path_cleaned .. "' to '" .. dest_path_cleaned .. "'")
    arguments.execute("git", "add", ".")
end)

--[[
commands:
restore

restores removed file
]]
arguments.createArgument("git", "restore", "", function(...)
    local tuple = {...}
    if #tuple == 0 then
        error("fatal: you must specify path(s) to restore")
        return
    end

    assert(bash.getGitFolderRoot(), "fatal: not a git repository")
    local index = Handlers.read_index()
    local path = tuple[1]
    
    local is_all = (path == ".")
    
    if is_all then
        -- Full destructive restore
        local objectsByShaFallback = setmetatable({}, {
            __index = function(_, key)
                local obj = Handlers.read_object(key)
                if not obj then return nil end
                return {
                    objType = ({commit=1, tree=2, blob=3, tag=4})[obj.type],
                    content = obj.content
                }
            end
        })

        -- 1. Remove untracked items
        local to_destroy = {}
        local function check_untracked(parent, prefix)
            local child_counts = {}
            for _, child in ipairs(parent:GetChildren()) do
                if not Handlers.is_ignored(child:GetFullName()) and child ~= bash.getGitFolderRoot() then
                    child_counts[child.Name] = (child_counts[child.Name] or 0) + 1
                end
            end

            local seen = {}
            for _, child in ipairs(parent:GetChildren()) do
                if not Handlers.is_ignored(child:GetFullName()) and child ~= bash.getGitFolderRoot() then
                    local virtualName = child.Name
                    if child_counts[child.Name] > 1 then
                        seen[child.Name] = (seen[child.Name] or 0) + 1
                        virtualName = child.Name .. " [" .. tostring(seen[child.Name]) .. "]"
                    end
                    local my_path = prefix == "" and virtualName or (prefix .. "/" .. virtualName)
                    
                    local hasValidChildren = false
                    for _, sub in ipairs(child:GetChildren()) do
                        if not Handlers.is_ignored(sub:GetFullName()) and sub ~= bash.getGitFolderRoot() then
                            hasValidChildren = true; break
                        end
                    end
                    
                    local idx_p = hasValidChildren and (my_path .. "/.properties") or my_path
                    if not index[idx_p] and not index[my_path] then
                        table.insert(to_destroy, child)
                    else
                        check_untracked(child, my_path)
                    end
                end
            end
        end

        for _, service in ipairs(bash.trackingRoot) do
            check_untracked(service, service.Name)
        end
        for _, obj in ipairs(to_destroy) do pcall(function() obj:Destroy() end) end

        -- 2. Restore/Create tracked items
        for idx_path, data in pairs(index) do
            local clean_path = idx_path:match("^(.-)/%.properties$") or idx_path
            local targetObj = Utilities.parse_path(clean_path)
            
            if not targetObj then
                -- Create missing
                local segments = string.split(clean_path, "/")
                local name = table.remove(segments)
                local parentPath = table.concat(segments, "/")
                local parentObj = Utilities.parse_path(parentPath)
                if parentObj then
                    local obj = Handlers.read_object(data.sha)
                    if obj and obj.type == "blob" then
                        local ok, props = pcall(function() return HttpService:JSONDecode(obj.content) end)
                        if ok then
                            local className = "Folder"
                            for _, p in ipairs(props) do if p.name == "ClassName" then className = p.value; break end end
                            local ok2, inst = pcall(Instance.new, className)
                            if ok2 then
                                inst.Name = name
                                Remote.applyProperties(inst, props)
                                inst.Parent = parentObj
                            end
                        end
                    end
                end
            else
                -- Update existing
                local obj = Handlers.read_object(data.sha)
                if obj and obj.type == "blob" then
                    local ok, props = pcall(function() return HttpService:JSONDecode(obj.content) end)
                    if ok then
                        Remote.applyProperties(targetObj, props)
                    end
                end
            end
        end
        Remote.resolve_instance_refs()
        print("Restored working tree from index")
    else
        -- Single path restore (current logic enhanced)
        local _, _, segments = Utilities.parse_path(path)
        local target_path_base = table.concat(segments or {}, "/")
        local found = false
        for idx_path, data in pairs(index) do
            local entry_path = idx_path:match("^(.-)/%.properties$") or idx_path
            if entry_path == target_path_base or entry_path:sub(1, #target_path_base + 1) == target_path_base .. "/" then
                found = true
                local targetObj = Utilities.parse_path(entry_path)
                if targetObj then
                    local obj = Handlers.read_object(data.sha)
                    if obj and obj.type == "blob" then
                        local ok, props = pcall(function() return HttpService:JSONDecode(obj.content) end)
                        if ok then Remote.applyProperties(targetObj, props) end
                    end
                end
            end
        end
        Remote.resolve_instance_refs()
        if found then print("Restored " .. path) else print("error: pathspec '" .. path .. "' did not match any files") end
    end
end)

--[[
Commands:
add
a

Adds files to be commited
]]
arguments.createArgument("git", "add", "a", function (...)
    assert(bash.getGitFolderRoot(),
        "fatal: not a git repository (or any of the parent directories): .git")

    local args = {...}
    local force = false
    local dry_run = false
    local paths = {}

    for _, arg in ipairs(args) do
        if arg == "-f" or arg == "--force" then
            force = true
        elseif arg == "-n" or arg == "--dry-run" then
            dry_run = true
        elseif arg == "-A" or arg == "--all" then
            table.insert(paths, ".")
        else
            table.insert(paths, arg)
        end
    end

    if #paths == 0 then
        print("Nothing specified, nothing added.")
        print("hint: Maybe you wanted to say 'git add .'?")
        return
    end

    local has_dot = false
    for _, p in ipairs(paths) do
        if p == "." then
            has_dot = true
            break
        end
    end

    if has_dot then
        local index = Handlers.read_index()
        
        -- Clear existing index entries for our tracking roots to reflect deletions/renames
        for path, _ in pairs(index) do
            for _, service in ipairs(bash.trackingRoot) do
                if path == service.Name or path:sub(1, #service.Name + 1) == service.Name .. "/" then
                    index[path] = nil
                    break
                end
            end
        end

        local seen_ids = {}
        for _, service in ipairs(bash.trackingRoot) do
            if force or not Handlers.is_ignored(service:GetFullName()) then
                if dry_run then
                    print("add '" .. service:GetFullName() .. "'")
                    for _, desc in ipairs(service:GetDescendants()) do
                        if desc ~= bash.getGitFolderRoot() and not desc:IsDescendantOf(bash.getGitFolderRoot()) then
                            print("add '" .. desc:GetFullName() .. "'")
                        end
                    end
                else
                    instances.stage_recursive(service, index, seen_ids)
                end
            end
        end
        if not dry_run then
            Handlers.write_index(index)
        end
        return
    end

    local index = Handlers.read_index()
    local seen_ids = {}

    for _, target in ipairs(paths) do
        local currObj, _, segments = Utilities.parse_path(target)

        if not currObj then
            error("fatal: pathspec '" .. target .. "' did not match any files")
            return
        end

        if dry_run then
            print("add '" .. currObj:GetFullName() .. "'")
        else
            local parentPath = table.concat(segments, "/", 1, #segments - 1)
            if parentPath == "" then parentPath = nil end
            instances.stage_recursive(currObj, index, seen_ids, nil, parentPath)
        end
    end

    if not dry_run then
        Handlers.write_index(index)
    end
end)


--[[
commands:
pull

pulls latest commit.
]]
arguments.createArgument("git", "pull", "", function (...)
    assert(bash.getGitFolderRoot(), "fatal: not a git repository (or any of the parent directories): .git")

    local tuple = {...}
    local remote_name = tuple[1] or "origin"
    local branch_name = tuple[2] or Handlers.get_current_branch() or "master"

    local config_content = bash.getFileContents(bash.getGitFolderRoot(), "config")
    local loaded_conf = ini_parser.parseIni(config_content)
    local section_name = 'remote "' .. remote_name .. '"'
    local remote_section = loaded_conf[section_name]
    assert(remote_section and remote_section.url, "fatal: '" .. remote_name .. "' does not appear to be a git repository")
    local url = remote_section.url

    local refs = Remote.discoverRefs(url)
    local remoteSha = refs["refs/heads/" .. branch_name] or refs["HEAD"]
    assert(remoteSha, "fatal: couldn't find remote ref 'refs/heads/" .. branch_name .. "'")

    local current_branch = Handlers.get_current_branch()
    local head_sha = Handlers.get_ref("HEAD")
    local local_branch_sha = Handlers.get_ref("refs/heads/" .. branch_name)
    if not local_branch_sha and current_branch == branch_name then
        local_branch_sha = head_sha
    end

    local index = Handlers.read_index()
    
    -- If we are already up to date, check if our local parts match the tree
    if local_branch_sha == remoteSha then
        local current_tree_matches = true
        for path, _ in pairs(index) do
            local clean = path:match("^(.-)/%.properties$") or path
            if not Utilities.parse_path(clean) then
                current_tree_matches = false; break
            end
        end

        if current_tree_matches then
            print("Already up to date.")
            return
        end
    end

    if local_branch_sha and remoteSha and local_branch_sha ~= remoteSha then
        if is_ancestor_commit(remoteSha, local_branch_sha) then
            print("Already up to date.")
            return
        end

        if not is_ancestor_commit(local_branch_sha, remoteSha) then
            error("fatal: Not possible to fast-forward, aborting.")
            print("hint: Local and remote branches have diverged.")
            print("hint: Use 'git merge', or manually move refs if you intend to overwrite history.")
            return
        end
    end

    if current_branch == branch_name and local_branch_sha and local_branch_sha ~= remoteSha then
        local modified, deleted = collect_worktree_changes(index)
        if #modified + #deleted > 0 then
            print("error: Your local changes to the following files would be overwritten by merge:")
            for _, path in ipairs(modified) do
                print("\t" .. path)
            end
            for _, path in ipairs(deleted) do
                print("\t" .. path)
            end
            print("Please commit your changes or restore them before you merge.")
            print("Aborting")
            return
        end
    end

    print("Updating " .. string.sub(local_branch_sha or "0000000", 1, 7) .. ".." .. string.sub(remoteSha, 1, 7))
    local fullPack = Remote.fetchPackfile(url, remoteSha)
    local _, objectsBySha = Remote.unpackObjects(fullPack)
    
    for oSha, obj in pairs(objectsBySha) do
        local typeName = ({[1]="commit", [2]="tree", [3]="blob", [4]="tag"})[obj.objType]
        if typeName then
            Handlers.write_object_with_sha(typeName, obj.content, oSha)
        end
    end

    Handlers.update_ref("refs/heads/" .. branch_name, remoteSha)
    Handlers.update_ref("refs/remotes/" .. remote_name .. "/" .. branch_name, remoteSha)
    
    if current_branch == branch_name then
        local remote_commit_obj = Handlers.read_object(remoteSha)
        local treeSha = remote_commit_obj and remote_commit_obj.content:match("^tree (%x+)")
        if treeSha then
            print("Syncing workspace...")
            Remote.checkout(treeSha)
        end
    end
    print("Successfully pulled from " .. branch_name)
end)


--[[
commands:
rm

Removes file from staged
]]
arguments.createArgument("git", "rm", "", function (...)
    assert(bash.getGitFolderRoot(), "fatal: not a git repository (or any of the parent directories): .git")

    local tuple = {...}
    local is_cached = false
    local recursive = false
    local _force = false
    local paths = {}

    for _, arg in ipairs(tuple) do
        if arg == "--cached" then
            is_cached = true
        elseif arg == "-r" then
            recursive = true
        elseif arg == "-f" or arg == "--force" then
            _force = true
        else
            table.insert(paths, arg)
        end
    end

    if #paths == 0 then
        error("fatal: No pathspec was given. Which files should I remove?")
        return
    end

    local index = Handlers.read_index()
    local removed = {}

    for _, path_to_remove in ipairs(paths) do
        if path_to_remove:sub(1, 5) == "game." or path_to_remove:sub(1, 5) == "game/" then
            path_to_remove = path_to_remove:sub(6)
        end
        path_to_remove = path_to_remove:gsub("%.", "/")

        if recursive then
            for path, _ in pairs(index) do
                if path == path_to_remove or path:sub(1, #path_to_remove + 1) == path_to_remove .. "/" then
                    index[path] = nil
                    table.insert(removed, path)
                end
            end
        else
            if index[path_to_remove] then
                index[path_to_remove] = nil
                table.insert(removed, path_to_remove)
            elseif index[path_to_remove .. "/.properties"] then
                index[path_to_remove .. "/.properties"] = nil
                table.insert(removed, path_to_remove .. "/.properties")
            else
                error("fatal: pathspec '" .. path_to_remove .. "' did not match any files")
            end
        end
    end

    Handlers.write_index(index)

    if not is_cached then
        for _, path in ipairs(removed) do
            local clean_path = path:match("^(.-)/%.properties$") or path
            local currObj = Utilities.parse_path(clean_path)
            if currObj and currObj ~= game then
                currObj:Destroy()
            end
        end
    end

    for _, path in ipairs(removed) do
        print("rm '" .. path .. "'")
    end
end)

--[[
commands:
commit

commit staged changes
]]
arguments.createArgument("git", "commit", "", function(...)
    assert(bash.getGitFolderRoot(), "fatal: not a git repository (or any of the parent directories): .git")

    local tuple = { ... }
    local message = ""
    local allow_empty = false
    local amend = false

    local i = 1
    while i <= #tuple do
        if tuple[i] == "-m" and tuple[i + 1] then
            message = tuple[i + 1]
            i += 1
        elseif tuple[i] == "--allow-empty" then
            allow_empty = true
        elseif tuple[i] == "--amend" then
            amend = true
        end
        i += 1
    end

    if message == "" and not amend then
        message = "default commit message"
    end

    local index = Handlers.read_index()

    local last_index = {}
    local last_index_str = bash.getFileContents(bash.getGitFolderRoot(), "last_commit_index")
    if last_index_str and last_index_str ~= "" then
        last_index = HttpService:JSONDecode(last_index_str)
    end

    local old_paths = {}
    local new_paths = {}
    local old_sha_to_path = {}
    local new_sha_to_path = {}

    for path, data in pairs(last_index) do
        old_paths[path] = data.sha
        old_sha_to_path[data.sha] = path
    end
    for path, data in pairs(index) do
        new_paths[path] = data.sha
        new_sha_to_path[data.sha] = path
    end

    local files_added = {}
    local files_deleted = {}
    local files_modified = {}
    local files_renamed = {}

    local total_insertions = 0
    local total_deletions = 0

    for path, old_sha in pairs(old_paths) do
        Utilities.roYield()
        local new_sha = new_paths[path]

        if not new_sha then
            if new_sha_to_path[old_sha] then
                local new_path_for_sha = new_sha_to_path[old_sha]
                if new_path_for_sha ~= path then
                    new_paths[new_path_for_sha] = "RENAMED_PLACEHOLDER"
                    table.insert(files_renamed, {old_path = path, new_path = new_path_for_sha, similarity = 100})
                end
            else
                table.insert(files_deleted, {path = path, mode = last_index[path].mode})
                total_deletions = total_deletions + Handlers.get_content_lines(old_sha)
            end
        elseif old_sha ~= new_sha then
            table.insert(files_modified, {path = path, old_sha = old_sha, new_sha = new_sha})
            total_deletions = total_deletions + Handlers.get_content_lines(old_sha)
            total_insertions = total_insertions + Handlers.get_content_lines(new_sha)
        end
    end

    for path, new_sha in pairs(new_paths) do
        Utilities.roYield()
        if not old_paths[path] and new_sha ~= "RENAMED_PLACEHOLDER" then
            table.insert(files_added, {path = path, mode = index[path].mode})
            total_insertions = total_insertions + Handlers.get_content_lines(new_sha)
        end
    end

    local num_files_changed = #files_added + #files_deleted + #files_modified + #files_renamed

    if not allow_empty and num_files_changed == 0 and not amend then
        print("nothing to commit, working tree clean")
        return
    end

    if message == "default commit message" then
        warn("hint: It's recommended to provide a descriptive commit message with -m")
    end

    local parent_sha = Handlers.get_ref("HEAD")
    local tree_sha = Handlers.write_tree(index)
    local commit_content = "tree " .. tree_sha .. "\n"

    if amend then
        if parent_sha and parent_sha ~= "" then
            local old_commit = Handlers.read_object(parent_sha)
            if old_commit then
                for old_parent in old_commit.content:gmatch("\nparent (%x+)") do
                    commit_content = commit_content .. "parent " .. old_parent .. "\n"
                end
                if message == "" then
                    message = old_commit.content:match("\n\n(.+)$") or "default commit message"
                end
            end
        end
    else
        if parent_sha and parent_sha ~= "" then
            commit_content = commit_content .. "parent " .. parent_sha .. "\n"
        end
    end

    local timestamp = os.time()
    local user_name = Auth.getConfigValue("user_name") or Auth.getConfigValue("user.name") or "roGit"
    local user_email = Auth.getConfigValue("user_email") or Auth.getConfigValue("user.email") or "ro-git@example.com"
    commit_content = commit_content .. string.format("author %s <%s> %d +0000\n", user_name, user_email, timestamp)
    commit_content = commit_content .. string.format("committer %s <%s> %d +0000\n", user_name, user_email, timestamp)
    commit_content = commit_content .. "\n" .. message
    local commit_sha = Handlers.write_object("commit", commit_content)
    Handlers.update_ref("HEAD", commit_sha)

    if bash.getGitFolderRoot():FindFirstChild("last_commit_index") then
        bash.modifyFileContents(bash.getGitFolderRoot(), "last_commit_index", HttpService:JSONEncode(index))
    else
        bash.createFile(bash.getGitFolderRoot(), "last_commit_index", HttpService:JSONEncode(index))
    end

    local output_details = {}
    for _, entry in ipairs(files_renamed) do
        table.insert(output_details, string.format(" rename %s => %s (%d%%)", entry.old_path, entry.new_path, entry.similarity))
    end
    for _, entry in ipairs(files_added) do
        table.insert(output_details, string.format(" create mode %s %s", entry.mode, entry.path))
    end
    for _, entry in ipairs(files_deleted) do
        table.insert(output_details, string.format(" delete mode %s %s", entry.mode, entry.path))
    end

    local stats_line = ""
    if num_files_changed > 0 then
        stats_line = string.format(" %d files changed, %d insertions(+), %d deletions(-)", num_files_changed, total_insertions, total_deletions)
    end

    local short_sha = string.sub(commit_sha, 1, 7)
    local final_output = string.format("[master %s] %s", short_sha, message)
    if num_files_changed > 0 then
        final_output = final_output .. "\n" .. stats_line
    end
    if #output_details > 0 then
        if #output_details > 20 then
            local new_details = {}
            for i = 1, 20 do table.insert(new_details, output_details[i]) end
            table.insert(new_details, string.format(" ... and %d more files", #output_details - 20))
            output_details = new_details
        end
        final_output = final_output .. "\n" .. table.concat(output_details, "\n")
    end
    print(final_output)
end)

--[[
commands:
init

initializes new repository
]]
arguments.createArgument("git", "init", "", function (...)
    _ignore_patterns = nil

    local tuple = {...}
    local quiet = false
    local initial_branch = "master"

    local i = 1
    while i <= #tuple do
        if tuple[i] == "-q" or tuple[i] == "--quiet" then
            quiet = true
        elseif tuple[i] == "-b" and tuple[i + 1] then
            initial_branch = tuple[i + 1]
            i += 1
        end
        i += 1
    end

    local root = bash.getGitFolderRoot()
    if not root then 
        root = bash.createGitFolderRoot()
        if not quiet then
            print("Initialized empty Git repository")
        end
    else 
        if not quiet then
            print("Reinitialized existing Git repository in " .. game.Name)
        end
        local _reinit_required = true
    end

    bash.createFolder(root, "hooks")
    local info = bash.createFolder(root, "info")

    bash.createFolder(root, "objects/info")
    bash.createFolder(root, "objects/pack")

    bash.createFolder(root, "refs/heads")
    bash.createFolder(root, "refs/tags")

    bash.createFile(root, "config", [[
    [core]
        repositoryformatversion = 0
        filemode = false
        bare = false
        logallrefupdates = true
        symlinks = false
        ignorecase = true
    ]])
    bash.createFile(root, "description", "Unnamed repository; edit this file 'description' to name the repository.")
    bash.createFile(root, "HEAD", "ref: refs/heads/" .. initial_branch)

    bash.createFile(info, "exclude", [[
    # git ls-files --others --exclude-from=.git/info/exclude
    # Lines that start with '#' are comments.
    # For a project mostly in C, the following would be a good set of
    # exclude patterns (uncomment them if you want to use them):
    # *.[oa]
    # *~
    ]])

    bash.createFile(bash.getGitFolderRoot(), "index", "")
    bash.createFile(bash.getGitFolderRoot().Parent, ".rogit_project", "This repository is recognized as a valid roGit project.")
    bash.createFile(bash.getGitFolderRoot().Parent, ".rogitignore", [[
    # Instances to ignore in ro-git
    .rogitignore
    Camera
     ]])
end)

--[[
commands:
clone

clones a git repository
]]
arguments.createArgument("git", "clone", "", function(...)
    local tuple = {...}
    local branch_override = nil
    local url = nil
    local repo_dir = nil

    local i = 1
    while i <= #tuple do
        if (tuple[i] == "-b" or tuple[i] == "--branch") and tuple[i + 1] then
            branch_override = tuple[i + 1]
            i += 1
        elseif tuple[i]:sub(1,1) ~= "-" then -- Positional argument
            if not url then
                url = tuple[i]
            elseif not repo_dir then
                repo_dir = tuple[i]
            end
        end
        i += 1
    end

    if not url or url == "" then
        error("fatal: You must specify a repository to clone.")
        print("\nusage: git clone [<options>] [--] <repo> [<dir>]\n\n    -v, --verbose         be more verbose\n    -q, --quiet           be more quiet\n    --progress            force progress reporting\n    -n, --no-checkout     don't create a checkout")
        return
    end

    local repoName = url:match("/([^/]+)$") or "repository"
    if repo_dir then
        repoName = repo_dir
    end
    print("Cloning into '" .. repoName .. "'...")

    if not bash.getGitFolderRoot() then
        arguments.execute("git", "init", "-q")
    end
    arguments.execute("git", "remote", "add", "origin", url)

    local refs = Remote.discoverRefs(url)
    local headSha
    if branch_override then 
        headSha = refs["refs/heads/" .. branch_override]
        assert(headSha, "fatal: Remote branch '" .. branch_override .. "' not found in upstream origin")
    else
       headSha = refs["HEAD"] or refs["refs/heads/master"] or refs["refs/heads/main"]
    end
    
    if not headSha or headSha == "" then
        print("warning: You appear to have cloned an empty repository.")
        return
    end

    local _t0 = os.clock()

    local _t1 = os.clock()
    local packFile = Remote.fetchPackfile(url, headSha)

    _t1 = os.clock()
    local _, objectsBySha = Remote.unpackObjects(packFile)
    local _objCount = 0
    for _ in pairs(objectsBySha) do _objCount += 1 end

    _t1 = os.clock()
    local _needed = {}
    local function _collectNeeded(sha)
        if not sha or _needed[sha] then return end
        local obj = objectsBySha[sha]
        if not obj then return end
        _needed[sha] = true
        if obj.objType == 1 then
            local treeSha = obj.content:match("^tree (%x+)")
            if treeSha then _collectNeeded(treeSha) end
        elseif obj.objType == 2 then
            local c = obj.content
            local p = 1
            while p <= #c do
                local sp = c:find(" ", p, true)
                local np = c:find("\0", sp, true)
                local rs = c:sub(np + 1, np + 20)
                local es = ("%02x"):rep(20):format(rs:byte(1, 20))
                p = np + 21
                _collectNeeded(es)
            end
        end
    end

    for _, branchSha in pairs(refs) do
        _collectNeeded(branchSha)
    end

    local _writeCount = 0
    for sha, obj in pairs(objectsBySha) do
        if _needed[sha] then
            Utilities.roYield()
            local typeName = ({[1]="commit", [2]="tree", [3]="blob", [4]="tag"})[obj.objType]
            if typeName then
                Handlers.write_object_with_sha(typeName, obj.content, sha)
                _writeCount += 1
            end
        end
    end

    local activeBranch = branch_override
    if not activeBranch then
        for refName, sha in pairs(refs) do
            if sha == headSha and refName:match("^refs/heads/") then
                activeBranch = refName:sub(12)
                break
            end
        end
        activeBranch = activeBranch or "master"
    end
    
    local gitRoot = bash.getGitFolderRoot()
    bash.modifyFileContents(gitRoot, "HEAD", "ref: refs/heads/" .. activeBranch)
    for refName, sha in pairs(refs) do
        if refName:match("^refs/heads/") then
            local bName = refName:sub(12)
            Handlers.update_ref("refs/remotes/origin/" .. bName, sha)
            if bName == activeBranch then
                Handlers.update_ref("refs/heads/" .. bName, sha)
            end
        elseif refName:match("^refs/tags/") then
            Handlers.update_ref(refName, sha)
        end
    end

    local config_content = bash.getFileContents(gitRoot, "config")
    local loaded_conf = ini_parser.parseIni(config_content)
    loaded_conf['branch "' .. activeBranch .. '"'] = {
        remote = "origin",
        merge = "refs/heads/" .. activeBranch
    }
    bash.modifyFileContents(gitRoot, "config", ini_parser.serializeIni(loaded_conf))

    local headCommit = objectsBySha[headSha]
    assert(headCommit, "HEAD commit not found in packfile")

    local treeSha = headCommit.content:match("^tree (%x+)")
    assert(treeSha, "Could not parse tree SHA from commit")

    local treeObj = objectsBySha[treeSha]
    assert(treeObj, "Missing root tree: " .. treeSha)

    local content = treeObj.content
    
    _t1 = os.clock()
    local function find_rogit_project(current_tree_sha)
        local obj = objectsBySha[current_tree_sha]
        if not obj then return false end
        
        local c_content = obj.content
        local c_pos = 1
        while c_pos <= #c_content do
            Utilities.roYield()
            local spacePos = c_content:find(" ", c_pos, true)
            local mode = c_content:sub(c_pos, spacePos - 1)
            local nullPos = c_content:find("\0", spacePos, true)
            local name = c_content:sub(spacePos + 1, nullPos - 1)
            local rawSha = c_content:sub(nullPos + 1, nullPos + 20)
            local child_sha = ("%02x"):rep(20):format(rawSha:byte(1, 20))
            c_pos = nullPos + 21
            
            if name == ".rogit_project" then
                return true
            elseif mode == "40000" then
                if find_rogit_project(child_sha) then
                    return true
                end
            end
        end
        return false
    end
    
    local is_rogit_project = find_rogit_project(treeSha)
    
    if not is_rogit_project then
        error("fatal: repository does not appear to be a rogit project (missing .rogit_project file).")
        local gitRoot_to_destroy = bash.getGitFolderRoot()
        if gitRoot_to_destroy then gitRoot_to_destroy:Destroy() end
        return
    end

    _t1 = os.clock()
    local _instanceCount = 0
    local pos = 1
    while pos <= #content do
        Utilities.roYield()
        local spacePos = content:find(" ", pos, true)
        local mode = content:sub(pos, spacePos - 1)
        local nullPos = content:find("\0", spacePos, true)
        local name = content:sub(spacePos + 1, nullPos - 1)
        local rawSha = content:sub(nullPos + 1, nullPos + 20)
        local sha = ("%02x"):rep(20):format(rawSha:byte(1, 20))
        pos = nullPos + 21

        if mode == "40000" then
            local serviceParent = game:FindFirstChild(name)
            if not serviceParent then
                pcall(function()
                    serviceParent = game:GetService(name)
                end)
            end
            if serviceParent then
                local childProps = Remote.peekPropertiesBlob(objectsBySha, sha)
                if childProps then
                    Remote.applyProperties(serviceParent, childProps)
                end
                Remote.writeTree(objectsBySha, sha, serviceParent, name)
                _instanceCount += 1
            end
        end
    end

    _t1 = os.clock()
    Remote.resolve_instance_refs()

    _t1 = os.clock()
    local new_index = Remote.buildIndexFromTree(objectsBySha, treeSha)
    local _indexCount = 0
    for _ in pairs(new_index) do _indexCount += 1 end

    _t1 = os.clock()
    Handlers.write_index(new_index)
    bash.modifyFileContents(gitRoot, "last_commit_index", HttpService:JSONEncode(new_index))

    print("Done. '" .. repoName .. "' cloned.")
end)

--[[
commands:
remote

manages remotes of repository
]]
arguments.createArgument("git", "remote", "", function(...)
    assert(bash.getGitFolderRoot(), "fatal: not a git repository (or any of the parent directories): .git")

    local tuple = {...}

    if #tuple == 0 or tuple[1] == "-v" or tuple[1] == "--verbose" then
        local verbose = #tuple > 0 and (tuple[1] == "-v" or tuple[1] == "--verbose")
        
        local config_content = bash.getFileContents(bash.getGitFolderRoot(), "config")
        local loaded_conf = ini_parser.parseIni(config_content)
        
        for section_name, section_data in pairs(loaded_conf) do
            local remote_name = section_name:match('^remote "(.+)"$')
            if remote_name then
                if verbose then
                    print(remote_name .. "\t" .. (section_data.url or "(no URL)"))
                else
                    print(remote_name)
                end
            end
        end
        return
    end

    local accepted_args = {
        ["add"] = true,
        ["set-url"] = true,
        ["remove"] = true,
        ["rm"] = true,
        ["get-url"] = true,
        ["rename"] = true,
        ["show"] = true
    }
    local subcommand = tuple[1]
    if not accepted_args[subcommand] then
        print("error: unknown subcommand: " .. tostring(subcommand))
        print("usage: git remote [-v | --verbose]")
        print("   or: git remote add [-f] <name> <url>")
        print("   or: git remote remove <name>")
        print("   or: git remote set-url <name> <newurl>")
        return
    end
    
    if subcommand == "add" then
        local do_fetch = false
        local name, url
        local args = {}
        for i=2, #tuple do
            local arg = tuple[i]
            if arg == "-f" or arg == "--fetch" then
                do_fetch = true
            else
                table.insert(args, arg)
            end
        end
        
        name = args[1]
        url = args[2]
        assert(name and url, "usage: git remote add [-f] <name> <url>")

        local config_content = bash.getFileContents(bash.getGitFolderRoot(), "config")
        local loaded_conf = ini_parser.parseIni(config_content)

        local section_name = 'remote "' .. name .. '"'
        loaded_conf[section_name] = {
            url = url,
            fetch = "+refs/heads/*:refs/remotes/" .. name .. "/*"
        }
        
        bash.modifyFileContents(bash.getGitFolderRoot(), "config", ini_parser.serializeIni(
            loaded_conf
        ))

        if do_fetch then
            git_remote.fetch(name)
        end
    
    elseif subcommand == "set-url" then
        local config_content = bash.getFileContents(bash.getGitFolderRoot(), "config")
        local loaded_conf = ini_parser.parseIni(config_content)
        
        local push_mode = false
        local name, new_url

        if tuple[2] == "--push" then
            push_mode = true
            name = tuple[3]
            new_url = tuple[4]
        else
            name = tuple[2]
            new_url = tuple[3]
        end

        assert(name and new_url, "usage: git remote set-url [--push] <name> <newurl>")

        local section_name = 'remote "' .. name .. '"'
        local remote_section = loaded_conf[section_name]
        assert(remote_section, "fatal: No such remote '" .. name .. "'")

        local url_key = push_mode and "pushurl" or "url"
        remote_section[url_key] = new_url

        bash.modifyFileContents(bash.getGitFolderRoot(), "config", ini_parser.serializeIni(
            loaded_conf
        ))
    
    elseif subcommand == "remove" or subcommand == "rm" then
        local name = tuple[2]
        assert(name, "usage: git remote remove <name>")

        local config_content = bash.getFileContents(bash.getGitFolderRoot(), "config")
        local loaded_conf = ini_parser.parseIni(config_content)

        local section_name = 'remote "' .. name .. '"'
        if loaded_conf[section_name] then
            loaded_conf[section_name] = nil
            bash.modifyFileContents(bash.getGitFolderRoot(), "config", ini_parser.serializeIni(
                loaded_conf
            ))
        else
            error("fatal: No such remote: '" .. name .. "'")
        end

    elseif subcommand == "get-url" then
        local push_mode = false
        local name

        if tuple[2] == "--push" then
            push_mode = true
            name = tuple[3]
        else
            name = tuple[2]
        end

        assert(name, "usage: git remote get-url [--push] <name>")

        local config_content = bash.getFileContents(bash.getGitFolderRoot(), "config")
        local loaded_conf = ini_parser.parseIni(config_content)
        
        local section_name = 'remote "' .. name .. '"'
        local remote_section = loaded_conf[section_name]
        assert(remote_section, "fatal: No such remote: '" .. name .. "'")

        local url
        if push_mode then
            url = remote_section.pushurl or remote_section.url
        else
            url = remote_section.url
        end

        assert(url, "fatal: URL not found for remote '" .. name .. "'")
        print(url)
        
    elseif subcommand == "rename" then
        local old_name = tuple[2]
        local new_name = tuple[3]
        assert(old_name and new_name, "usage: git remote rename <old> <new>")

        local config_content = bash.getFileContents(bash.getGitFolderRoot(), "config")
        local loaded_conf = ini_parser.parseIni(config_content)

        local old_section_name = 'remote "' .. old_name .. '"'
        local new_section_name = 'remote "' .. new_name .. '"'

        local remote_data = loaded_conf[old_section_name]
        assert(remote_data, "fatal: No such remote: '" .. old_name .. "'")
        assert(not loaded_conf[new_section_name], "fatal: remote " .. new_name .. " already exists.")

        if remote_data.fetch and remote_data.fetch:find(old_name, 1, true) then
            remote_data.fetch = remote_data.fetch:gsub(old_name, new_name)
        end
        
        loaded_conf[new_section_name] = remote_data
        loaded_conf[old_section_name] = nil

        bash.modifyFileContents(bash.getGitFolderRoot(), "config", ini_parser.serializeIni(
            loaded_conf
        ))
        
    elseif subcommand == "show" then
        local name = tuple[2]
        assert(name, "usage: git remote show <name>")

        local config_content = bash.getFileContents(bash.getGitFolderRoot(), "config")
        local loaded_conf = ini_parser.parseIni(config_content)

        local section_name = 'remote "' .. name .. '"'
        local remote_section = loaded_conf[section_name]
        assert(remote_section, "fatal: No such remote: '" .. name .. "'")

        print("* remote " .. name)
        print("  Fetch URL: " .. (remote_section.url or "(no URL configured)"))
        print("  Push  URL: " .. (remote_section.pushurl or remote_section.url or "(no URL configured)"))
    end
end)

--[[
commands:
push

pushes git repository commits to branch
]]
arguments.createArgument("git", "push", "", function(...)
    local tuple = {...}
    local remote_name = "origin"
    local branch_name = "master"
    local force_push = false
    local set_upstream = false
    local positional = {}

    for _, arg in ipairs(tuple) do
        if arg == "-f" or arg == "--force" then
            force_push = true
        elseif arg == "-u" or arg == "--set-upstream" then
            set_upstream = true
        else
            table.insert(positional, arg)
        end
    end

    if positional[1] then remote_name = positional[1] end
    if positional[2] then 
        branch_name = positional[2] 
    else
        branch_name = Handlers.get_current_branch() or "master"
    end

    local root = bash.getGitFolderRoot()
    assert(root, "fatal: not a git repository")

    local config_content = bash.getFileContents(root, "config")
    local loaded_conf = ini_parser.parseIni(config_content)

    local section_name = 'remote "' .. remote_name .. '"'
    local remote_section = loaded_conf[section_name]
    assert(remote_section and remote_section.url, "fatal: '" .. remote_name .. "' does not appear to be a git repository")
    
    local url = remote_section.url

    local refs = Remote.discoverRefs(url, "git-receive-pack")
    local remoteSha = refs["refs/heads/" .. branch_name]

    local localSha = nil
    if positional[2] then
        localSha = Handlers.get_ref("refs/heads/" .. branch_name)
        assert(localSha, "error: src refspec '" .. branch_name .. "' does not match any")
    else
        localSha = Handlers.get_ref("HEAD")
    end
    assert(localSha, "Nothing to push (no commits)")

    if localSha == remoteSha then
        print("Everything up-to-date")
        return
    end

    if remoteSha and not force_push then
        local is_ff = false
        local current = localSha
        local q = {current}
        local visited = {}
        
        while #q > 0 do
            local sha = table.remove(q, 1)
            if sha == remoteSha then
                is_ff = true
                break
            end
            if not visited[sha] then
                visited[sha] = true
                local obj = Handlers.read_object(sha)
                if obj and obj.type == "commit" then
                    for parent in obj.content:gmatch("\nparent (%x+)") do
                        table.insert(q, parent)
                    end
                end
            end
        end
        
        if not is_ff then
            print("To " .. url)
            print(" ! [rejected]        " .. branch_name .. " -> " .. branch_name .. " (non-fast-forward)")
            print("error: failed to push some refs to '" .. url .. "'")
            print("hint: Updates were rejected because the tip of your current branch is behind")
            print("hint: its remote counterpart. Integrate the remote changes (e.g.")
            print("hint: 'git pull' before pushing again.")
            return
        end
    end

    local local_tracking = Handlers.get_ref("refs/remotes/" .. remote_name .. "/" .. branch_name)
    local common_ancestor = remoteSha
    if remoteSha and not Handlers.read_object(remoteSha) then
        common_ancestor = local_tracking
    end

    local objects = Handlers.collectObjects(localSha, common_ancestor)

    local objectCount = 0
    for _ in pairs(objects) do
        objectCount = objectCount + 1
    end

    print(string.format("Enumerating objects: %d, done.", objectCount))
    print(string.format("Counting objects: 100%% (%d/%d), done.", objectCount, objectCount))

    local packFile = Handlers.buildPackfile(objects)
    local packSize = #packFile

    print(string.format("Compressing objects: 100%% (%d/%d), done.", objectCount, objectCount))
    print(string.format("Writing objects: 100%% (%d/%d), %d bytes | %.2f KiB/s, done.", objectCount, objectCount, packSize, packSize / 1024))
    print(string.format("Total %d (delta 0), reused 0 (delta 0), pack-reused 0", objectCount))

    local oldSha = remoteSha or ("0"):rep(40)
    local refLine = oldSha.." "..localSha.." refs/heads/"..branch_name.."\0report-status side-band-64k\n"
    local refPkt = buffer.tostring(git_proto.encodePkt(buffer.fromstring(refLine)))
    local flushStr = buffer.tostring(git_proto.flush())

    local body = refPkt .. flushStr .. packFile

    local req = {
        Url = Utilities.return_urls(url, "git-receive-pack")[2],
        Method = "POST",
        Headers = {
            ["Content-Type"] = "application/x-git-receive-pack-request",
            ["Accept"] = "application/x-git-receive-pack-result",
            ["Authorization"] = Auth.getAuthHeader(url:match("^(https?://[^/]+)") or url)
        },
        Body = body,
    }

    local ok, res = Requests.url_request_with_retry(req)
    assert(ok, "Push request error")

    if res.StatusCode == 200 then
        local remote_messages = {}
        local success_message = "To " .. url .. "\n"

        local response_buffer = buffer.fromstring(res.Body)
        local cursor = 0
        while cursor < buffer.len(response_buffer) do
            local data, next = git_proto.decodePkt(response_buffer, cursor)
            cursor = next
            Utilities.roYield()
            if data then
                local channel = buffer.readu8(data, 0)
                local line = buffer.tostring(data)
                line = line:sub(2)
                
                line = line:gsub("[\r\n]+", "")

                if channel == 2 then 
                    if line:find("^Resolving deltas") then
                        table.insert(remote_messages, "remote: " .. line)
                    else
                        table.insert(remote_messages, line)
                    end
                elseif channel == 1 then
                    if line:find("^unpack ") then
                    elseif line:find("^ok ") then
                        if not remoteSha or remoteSha == "" then
                            success_message = success_message .. " * [new branch]      " .. branch_name .. " -> " .. branch_name .. "\n"
                        else
                            success_message = success_message .. "   " .. string.sub(oldSha, 1, 7) .. ".." .. string.sub(localSha, 1, 7) .. "  " .. branch_name .. " -> " .. branch_name .. "\n"
                        end
                    elseif line:find("^ng ") then
                        local _ref, reason = line:match("^ng (.-) (.+)$")
                        success_message = success_message .. " ! [rejected]        " .. branch_name .. " -> " .. branch_name .. " (" .. (reason or "unknown") .. ")\n"
                    elseif line ~= "" and not line:find("0000") then
                    end
                else
                    local full_line = buffer.tostring(data)
                    full_line = full_line:gsub("[\r\n]+", "")
                    if full_line:find("^unpack ") then
                    elseif full_line:find("^ok ") then
                        if not remoteSha or remoteSha == "" then
                            success_message = success_message .. " * [new branch]      " .. branch_name .. " -> " .. branch_name .. "\n"
                        else
                            success_message = success_message .. "   " .. string.sub(oldSha, 1, 7) .. ".." .. string.sub(localSha, 1, 7) .. "  " .. branch_name .. " -> " .. branch_name .. "\n"
                        end
                    elseif full_line:find("^ng ") then
                        local _ref, reason = full_line:match("^ng (.-) (.+)$")
                        success_message = success_message .. " ! [rejected]        " .. branch_name .. " -> " .. branch_name .. " (" .. (reason or "unknown") .. ")\n"
                    end
                end
            end
        end

        if #remote_messages > 0 then
            print(table.concat(remote_messages, "\n"))
        end
        
        print(success_message:gsub("\n$", ""))

        if set_upstream then
            local branch_section = 'branch "' .. branch_name .. '"'
            loaded_conf[branch_section] = {
                remote = remote_name,
                merge = "refs/heads/" .. branch_name
            }
            bash.modifyFileContents(root, "config", ini_parser.serializeIni(loaded_conf))
            print("Branch '" .. branch_name .. "' set up to track remote branch '" .. branch_name .. "' from '" .. remote_name .. "'.")
        end
    else
        print("error: failed to push some refs to '" .. url .. "'")
        print("remote: HTTP Status Code: " .. res.StatusCode)
        for line in string.gmatch(res.Body, "[^\n]+") do
            print("remote: " .. line)
        end
    end
end)

--[[
commands:
status

gets status of branch/changes
]]
arguments.createArgument("git", "status", "st", function()
    assert(bash.getGitFolderRoot(), "fatal: not a git repository (or any of the parent directories): .git")

    local index = Handlers.read_index()
    local headSha = Handlers.get_ref("HEAD")
    local current_branch = Handlers.get_current_branch() or "master"

    local last_index = {}
    local last_index_str = bash.getFileContents(bash.getGitFolderRoot(), "last_commit_index")
    if last_index_str and last_index_str ~= "" then
        last_index = HttpService:JSONDecode(last_index_str)
    end

    local staged_new = {}
    local staged_modified = {}
    local staged_deleted = {}

    for path, data in pairs(index) do
        Utilities.roYield()
        if not last_index[path] then
            table.insert(staged_new, path)
        elseif last_index[path].sha ~= data.sha then
            table.insert(staged_modified, path)
        end
    end
    for path, _ in pairs(last_index) do
        if not index[path] then
            table.insert(staged_deleted, path)
        end
    end

    if not headSha or headSha == "" then
        print("On branch " .. current_branch)
        print("\nNo commits yet\n")
    else
        print("On branch " .. current_branch)
    end

    local unstaged_modified, unstaged_deleted = collect_worktree_changes(index)
    local has_unstaged = #unstaged_modified + #unstaged_deleted > 0

    local has_staged = #staged_new + #staged_modified + #staged_deleted > 0
    if has_staged then
        print("Changes to be committed:")
        for _, path in ipairs(staged_new) do
            print("\tnew file:   " .. path)
        end
        for _, path in ipairs(staged_modified) do
            print("\tmodified:   " .. path)
        end
        for _, path in ipairs(staged_deleted) do
            print("\tdeleted:    " .. path)
        end
    end

    if has_unstaged then
        print("Changes not staged for commit:")
        for _, path in ipairs(unstaged_modified) do
            print("\tmodified:   " .. path)
        end
        for _, path in ipairs(unstaged_deleted) do
            print("\tdeleted:    " .. path)
        end
    end

    if not has_staged and not has_unstaged then
        print("nothing to commit, working tree clean")
    end
end)

--[[
commands:
log

logs commits
]]
arguments.createArgument("git", "log", "", function(...)
    assert(bash.getGitFolderRoot(), "fatal: not a git repository (or any of the parent directories): .git")

    local tuple = {...}
    local max_count = nil
    local oneline = false

    local i = 1
    while i <= #tuple do
        if tuple[i] == "--oneline" then
            oneline = true
        elseif (tuple[i] == "-n" or tuple[i]:match("^%-%-max%-count")) and tuple[i + 1] then
            max_count = tonumber(tuple[i + 1])
            i += 1
        elseif tuple[i]:match("^%-(%d+)$") then
            max_count = tonumber(tuple[i]:match("^%-(%d+)$"))
        end
        i += 1
    end

    local sha = Handlers.get_ref("HEAD")
    if not sha or sha == "" then
        error("fatal: your current branch 'master' does not have any commits yet")
        return
    end

    local refs_map = {}
    local function scan_refs(dir, prefix)
        for _, child in ipairs(dir:GetChildren()) do
            if child:IsA("Folder") then
                scan_refs(child, prefix .. child.Name .. "/")
            else
                local sha = Handlers.get_ref(prefix .. child.Name)
                if sha then
                    refs_map[sha] = refs_map[sha] or {}
                    table.insert(refs_map[sha], prefix .. child.Name)
                end
            end
        end
    end
    local git_root = bash.getGitFolderRoot()
    local refs_folder = git_root:FindFirstChild("refs")
    if refs_folder then scan_refs(refs_folder, "refs/") end
    
    local head_sha = Handlers.get_ref("HEAD")
    local current_branch = Handlers.get_current_branch()
    
    local count = 0
    while sha do
        if max_count and count >= max_count then break end

        local obj = Handlers.read_object(sha)
        if not obj then break end

        local body = obj.content
        local msg = body:match("\n\n(.+)$") or ""
        
        local decoration = ""
        local local_refs = refs_map[sha]
        if local_refs or sha == head_sha then
            local items = {}
            if sha == head_sha then
                if current_branch then
                    table.insert(items, "HEAD -> " .. current_branch)
                else
                    table.insert(items, "HEAD")
                end
            end
            if local_refs then
                for _, r in ipairs(local_refs) do
                    local name = r:match("refs/heads/(.+)") or r:match("refs/remotes/(.+)") or r:match("refs/tags/(.+)")
                    if name and name ~= current_branch then
                        if r:match("tags/") then
                            table.insert(items, "tag: " .. name)
                        else
                            table.insert(items, name)
                        end
                    end
                end
            end
            if #items > 0 then
                decoration = " (" .. table.concat(items, ", ") .. ")"
            end
        end

        if oneline then
            print(sha:sub(1, 7) .. decoration .. " " .. (msg:match("^[^\n]+") or msg))
        else
            local author_line = body:match("\nauthor ([^\n]+)") or ""
            local author_name_email, author_time, author_tz = author_line:match("(.-) (%d+) ([+%-%d]+)")
            
            print("commit " .. sha .. decoration)
            if author_name_email and author_time then
                print("Author: " .. author_name_email)
                print("Date:   " .. os.date("%a %b %d %H:%M:%S %Y", tonumber(author_time)) .. " " .. author_tz)
            else
                print("Author: " .. author_line)
            end
            print("")
            print("    " .. msg)
            print("")
        end

        count += 1
        sha = body:match("\nparent (%x+)")
    end
end)

--[[
commands:
branch
br

manage your branches
]]
arguments.createArgument("git", "branch", "br", function(...)
    assert(bash.getGitFolderRoot(), "fatal: not a git repository (or any of the parent directories): .git")
    assert(nil, "this command has been disabled as it has yet not been complete.")

    local tuple = {...}

    if #tuple == 0 or (tuple[1] == "-a" or tuple[1] == "--all" or tuple[1] == "-r" or tuple[1] == "--remotes") then
        local show_remotes = tuple[1] == "-a" or tuple[1] == "--all" or tuple[1] == "-r" or tuple[1] == "--remotes"
        local only_remotes = tuple[1] == "-r" or tuple[1] == "--remotes"
        
        local root = bash.getGitFolderRoot()
        local current_branch = Handlers.get_current_branch()
        local branches = {}
        
        if not only_remotes then
            local heads = root:FindFirstChild("refs")
            if heads then heads = heads:FindFirstChild("heads") end
            if heads then
                for _, child in ipairs(heads:GetChildren()) do
                    branches[child.Name] = { is_current = (child.Name == current_branch), is_remote = false }
                end
            end
        end
        
        if show_remotes or only_remotes then
            local remotes = root:FindFirstChild("refs")
            if remotes then remotes = remotes:FindFirstChild("remotes") end
            if remotes then
                for _, remote_node in ipairs(remotes:GetChildren()) do
                    for _, branch_node in ipairs(remote_node:GetChildren()) do
                        local name = remote_node.Name .. "/" .. branch_node.Name
                        if not branches[name] then
                            branches[name] = { is_current = false, is_remote = true }
                        end
                    end
                end
            end
        end

        local names = {}
        for name in pairs(branches) do table.insert(names, name) end
        table.sort(names)

        for _, name in ipairs(names) do
            local data = branches[name]
            -- Filter out HEAD symbolic refs from listing
            if name:match("/HEAD$") then continue end

            local prefix = data.is_current and "* " or "  "
            if data.is_remote then
                print(prefix .. "remotes/" .. name)
            else
                print(prefix .. name)
            end
        end
        
        if not next(branches) and current_branch then
            print("* " .. current_branch)
        end
        return
    end

    if tuple[1] == "-d" or tuple[1] == "--delete" or tuple[1] == "-D" then
        local branch = tuple[2]
        assert(branch, "fatal: branch name required")

        local current_ref = bash.getFileContents(bash.getGitFolderRoot(), "HEAD") or ""
        local current_branch = current_ref:match("ref: refs/heads/(.+)")
        if current_branch == branch then
            print("error: Cannot delete branch '" .. branch .. "' checked out at '" .. bash.getGitFolderRoot().Parent:GetFullName() .. "'")
            return
        end

        local heads = bash.getGitFolderRoot():FindFirstChild("refs")
        if heads then heads = heads:FindFirstChild("heads") end
        if heads then
            local ref = heads:FindFirstChild(branch)
            if ref then
                ref:Destroy()
                print("Deleted branch " .. branch)
            else
                print("error: branch '" .. branch .. "' not found.")
            end
        end
        return
    end

    if tuple[1] == "-m" or tuple[1] == "--move" then
        local old_branch = tuple[2]
        local new_branch = tuple[3]
        if not new_branch then
            new_branch = old_branch
            local current_ref = bash.getFileContents(bash.getGitFolderRoot(), "HEAD") or ""
            old_branch = current_ref:match("ref: refs/heads/(.+)")
        end
        assert(old_branch and new_branch, "usage: git branch -m [<old>] <new>")

        local sha = Handlers.get_ref("refs/heads/" .. old_branch)
        assert(sha, "error: refname refs/heads/" .. old_branch .. " not found")

        Handlers.update_ref("refs/heads/" .. new_branch, sha)

        local heads = bash.getGitFolderRoot():FindFirstChild("refs")
        if heads then heads = heads:FindFirstChild("heads") end
        if heads then
            local old_ref = heads:FindFirstChild(old_branch)
            if old_ref then old_ref:Destroy() end
        end

        local current_ref = bash.getFileContents(bash.getGitFolderRoot(), "HEAD") or ""
        if current_ref:match("ref: refs/heads/(.+)") == old_branch then
            bash.modifyFileContents(bash.getGitFolderRoot(), "HEAD", "ref: refs/heads/" .. new_branch)
        end
        return
    end

    local branch_name = tuple[1]
    assert(is_valid_branch_name(branch_name), "fatal: '" .. tostring(branch_name) .. "' is not a valid branch name.")
    
    local start_point = tuple[2]
    if not start_point then
        local head_sha = Handlers.get_ref("HEAD")
        if not head_sha or head_sha == "" then
            error("fatal: cannot create branch '" .. branch_name .. "' because there are no commits yet")
            print("hint: create your first commit, then run 'git branch " .. branch_name .. "'")
            return
        end
    end

    local sha = start_point and Handlers.get_ref("refs/heads/" .. start_point) or Handlers.get_ref("HEAD")
    assert(sha and sha ~= "", "fatal: Not a valid object name: '" .. (start_point or "HEAD") .. "'.")
    Handlers.update_ref("refs/heads/" .. branch_name, sha)
    print("Created branch '" .. branch_name .. "'")
end)

--[[
commands:
switch

switch branches in repository
]]
arguments.createArgument("git", "switch", "", function(...)
    assert(bash.getGitFolderRoot(), "fatal: not a git repository (or any of the parent directories): .git")

    assert(nil, "this command has been disabled as it has yet not been complete.")

    local tuple = {...}
    
    local create_branch = false
    local branch_name = ""
    
    if tuple[1] == "-c" or tuple[1] == "--create" then
        create_branch = true
        branch_name = tuple[2]
    else
        branch_name = tuple[1]
    end
    
    if not branch_name or branch_name == "" then
        error("fatal: branch name required")
        print("usage: git switch [-c | --create] <branch>")
        return
    end
    
    assert(is_valid_branch_name(branch_name), "fatal: invalid reference: " .. tostring(branch_name))

    local current_branch = Handlers.get_current_branch()
    if not create_branch and current_branch == branch_name then
        print("Already on '" .. branch_name .. "'")
        return
    end

    local current_sha = Handlers.get_ref("HEAD")
    local target_sha = nil

    if create_branch then
        assert(current_sha and current_sha ~= "", "fatal: you are on a branch with no commits yet")
        target_sha = current_sha
    else
        local heads = bash.getGitFolderRoot():FindFirstChild("refs")
        if heads then heads = heads:FindFirstChild("heads") end
        local branch_exists = heads and heads:FindFirstChild(branch_name)
        assert(branch_exists, "fatal: invalid reference: " .. branch_name)
        target_sha = Handlers.get_ref("refs/heads/" .. branch_name)
        assert(target_sha and target_sha ~= "", "fatal: invalid reference: " .. branch_name)
    end

    if target_sha ~= current_sha then
        local index = Handlers.read_index()
        local modified, deleted = collect_worktree_changes(index)
        if #modified + #deleted > 0 then
            print("error: Your local changes to the following files would be overwritten by checkout:")
            for _, path in ipairs(modified) do
                print("\t" .. path)
            end
            for _, path in ipairs(deleted) do
                print("\t" .. path)
            end
            print("Please commit your changes or restore them before you switch branches.")
            print("Aborting")
            return
        end
    end

    if create_branch then
        Handlers.update_ref("refs/heads/" .. branch_name, target_sha)
    end
    
    bash.modifyFileContents(bash.getGitFolderRoot(), "HEAD", "ref: refs/heads/" .. branch_name)
    
    target_sha = Handlers.get_ref("HEAD")
    local tree_sha = ""
    if target_sha then
        local commit_obj = Handlers.read_object(target_sha)
        if commit_obj then
            tree_sha = commit_obj.content:match("^tree (%x+)") or ""
        end
    end

    if tree_sha ~= "" then
        print("Checking out files: 100% done.")
        Remote.checkout(tree_sha)
    else
        print("Branch data not found locally. Fetching and pulling from origin...")
        local status, err = pcall(function()
            arguments.execute("git", "pull")
        end)
        if not status then warn("Pull failed: " .. tostring(err)) end
    end
    print("Switched to " .. (create_branch and "a new branch '" or "branch '") .. branch_name .. "'")
end)

--[[
commands:
checkout
ck

checkout branch or files
]]
arguments.createArgument("git", "checkout", "ck", function(...)
    
    assert(nil, "this command has been disabled as it has yet not been complete.")

    local tuple = {...}
    if #tuple == 0 then
        error("fatal: you must specify a branch or path to checkout")
        return
    end

    local first = tuple[1]
    
    if first == "-b" then
        local branch = tuple[2]
        if not branch then
            error("fatal: branch name required for -b")
            return
        end
        arguments.execute("git", "switch", "-c", branch)
        return
    end

    local root = bash.getGitFolderRoot()
    if not root then
        error("fatal: not a git repository")
        return
    end
    
    local heads = root:FindFirstChild("refs")
    if heads then heads = heads:FindFirstChild("heads") end
    local remotes = root:FindFirstChild("refs")
    if remotes then remotes = remotes:FindFirstChild("remotes") end
    
    local is_branch = (heads and heads:FindFirstChild(first))
    if not is_branch and remotes then
        for _, r in ipairs(remotes:GetChildren()) do
            if r:FindFirstChild(first) then
                local remote_sha = Handlers.get_ref("refs/remotes/" .. r.Name .. "/" .. first)
                Handlers.update_ref("refs/heads/" .. first, remote_sha)
                print("Branch '" .. first .. "' set up to track remote branch '" .. first .. "' from '" .. r.Name .. "'.")
                arguments.execute("git", "switch", first)
                return
            end
        end
    end

    if is_branch then
        arguments.execute("git", "switch", first)
    else
        arguments.execute("git", "restore", ...)
    end
end)

--[[
commands:
fetch

fetches from repository.
]]
arguments.createArgument("git", "fetch", "", function(...)
    assert(bash.getGitFolderRoot(), "fatal: not a git repository (or any of the parent directories): .git")

    local tuple = {...}
    local remote_name = tuple[1] or "origin"
    git_remote.fetch(remote_name)
end)

--[[
commands:
reset

resets repository change/s
]]
arguments.createArgument("git", "reset", "", function(...)
    assert(bash.getGitFolderRoot(), "fatal: not a git repository (or any of the parent directories): .git")

    local tuple = {...}
    local mode = "--mixed"
    local commit_target = "HEAD"
    local paths = {}

    local i = 1
    local positional = {}
    while i <= #tuple do
        local arg = tuple[i]
        if arg == "--soft" or arg == "--mixed" or arg == "--hard" then
            mode = arg
        elseif arg:sub(1, 1) ~= "-" then
            table.insert(positional, arg)
        end
        i += 1
    end

    if #positional > 0 then
        local first = positional[1]
        local is_commit = false
        if first == "HEAD" or Handlers.get_ref("refs/heads/" .. first) then
            is_commit = true
        elseif #first >= 7 and first:match("^%x+$") then
            is_commit = true
        end
        
        if is_commit then
            commit_target = table.remove(positional, 1)
        end
        
        for _, p in ipairs(positional) do
            table.insert(paths, p)
        end
    end

    if #paths > 0 then
        local index = Handlers.read_index()
        local tree_sha = ""
        local head_commit = Handlers.get_ref("HEAD")
        
        if head_commit and head_commit ~= "" then
            local commit_obj = Handlers.read_object(head_commit)
            if commit_obj then
                tree_sha = commit_obj.content:match("^tree (%x+)") or ""
            end
        end

        local tree_objects = {}
        if tree_sha ~= "" then
            local function recurse_tree(current_sha, prefix)
                local obj = Handlers.read_object(current_sha)
                if not obj then return end
                
                local content = obj.content
                local pos = 1
                while pos <= #content do
                    local spacePos = content:find(" ", pos, true)
                    local mode_str = content:sub(pos, spacePos - 1)
                    local nullPos = content:find("\0", spacePos, true)
                    local name = content:sub(spacePos + 1, nullPos - 1)
                    local rawSha = content:sub(nullPos + 1, nullPos + 20)
                    local child_sha = ("%02x"):rep(20):format(rawSha:byte(1, 20))
                    pos = nullPos + 21
                    
                    local full_path = prefix == "" and name or (prefix .. "/" .. name)
                    if mode_str == "40000" then
                        recurse_tree(child_sha, full_path)
                    else
                        tree_objects[full_path] = {sha = child_sha, mode = mode_str}
                    end
                end
            end
            pcall(recurse_tree, tree_sha, "")
        end

        for _, target_path in ipairs(paths) do
            if target_path:sub(1, 5) == "game." or target_path:sub(1, 5) == "game/" then
                target_path = target_path:sub(6)
            end
            target_path = target_path:gsub("%.", "/")

            local found = false
            for path, _ in pairs(index) do
                if path == target_path or path:sub(1, #target_path + 1) == target_path .. "/" then
                    found = true
                    if tree_objects[path] then
                        index[path] = {sha = tree_objects[path].sha, mode = tree_objects[path].mode}
                    else
                        index[path] = nil
                    end
                end
            end
            if not found then
                error("fatal: pathspec '" .. target_path .. "' did not match any files")
            end
        end
        
        Handlers.write_index(index)
        -- We only print this if not doing a broad switch checkout
        if not (mode == "--hard" and commit_target == "HEAD" and #paths == 0) then
            print("Unstaged changes after reset:")
        end
        return
    end

    local target_sha = commit_target
    if target_sha == "HEAD" then
        target_sha = Handlers.get_ref("HEAD")
    else
        local potential_ref = Handlers.get_ref("refs/heads/" .. commit_target)
        if potential_ref then
            target_sha = potential_ref
        elseif #target_sha >= 7 then
            local found_full = false
            local objects_dir = bash.getGitFolderRoot():FindFirstChild("objects")
            if objects_dir then
                local prefix = target_sha:sub(1, 2)
                local rem = target_sha:sub(3)
                local prefix_dir = objects_dir:FindFirstChild(prefix)
                if prefix_dir then
                    for _, child in ipairs(prefix_dir:GetChildren()) do
                        if child.Name:sub(1, #rem) == rem then
                            target_sha = prefix .. child.Name
                            found_full = true
                            break
                        end
                    end
                end
            end
            if not found_full then
                local obj = Handlers.read_object(target_sha) 
                if not obj then
                   error("fatal: ambiguous argument '" .. commit_target .. "': unknown revision or path not in the working tree.")
                end
            end
        end
    end

    assert(target_sha and target_sha ~= "", "fatal: Not a valid object name: '" .. commit_target .. "'.")

    local current_ref = bash.getFileContents(bash.getGitFolderRoot(), "HEAD") or ""
    local current_branch = current_ref:match("ref: refs/heads/(.+)")
    
    if current_branch then
        Handlers.update_ref("refs/heads/" .. current_branch, target_sha)
    else
        bash.modifyFileContents(bash.getGitFolderRoot(), "HEAD", target_sha)
    end

    if mode == "--soft" then
        return
    end

    local target_commit = Handlers.read_object(target_sha)
    local target_tree_sha = target_commit.content:match("^tree (%x+)")

    local fake_remote_map = {}
    if mode == "--hard" then
        local function collect_tree(current_sha)
            if not current_sha or fake_remote_map[current_sha] then return end
            local obj = Handlers.read_object(current_sha)
            if not obj then return end
            fake_remote_map[current_sha] = obj
            
            if obj.type == "tree" then
                local content = obj.content
                local pos = 1
                while pos <= #content do
                    local spacePos = content:find(" ", pos, true)
                    local _entry_mode = content:sub(pos, spacePos - 1)
                    local nullPos = content:find("\0", spacePos, true)
                    local rawSha = content:sub(nullPos + 1, nullPos + 20)
                    local child_sha = ("%02x"):rep(20):format(rawSha:byte(1, 20))
                    pos = nullPos + 21
                    collect_tree(child_sha)
                end
            end
        end
        collect_tree(target_tree_sha)
    end

    local function build_index_from_tree(tree_sha, prefix, new_index)
        if not tree_sha or tree_sha == "" then return end
        local obj = Handlers.read_object(tree_sha)
        if not obj then return end
        
        local content = obj.content
        local pos = 1
        while pos <= #content do
            local spacePos = content:find(" ", pos, true)
            local entry_mode = content:sub(pos, spacePos - 1)
            local nullPos = content:find("\0", spacePos, true)
            local name = content:sub(spacePos + 1, nullPos - 1)
            local rawSha = content:sub(nullPos + 1, nullPos + 20)
            local child_sha = ("%02x"):rep(20):format(rawSha:byte(1, 20))
            pos = nullPos + 21
            
            local full_path = prefix == "" and name or (prefix .. "/" .. name)
            
            if entry_mode == "40000" then
                build_index_from_tree(child_sha, full_path, new_index)
                if mode == "--hard" then
                    local segments = string.split(full_path, "/")
                    local currObj = game
                    for _, segment in ipairs(segments) do
                        if currObj and currObj:FindFirstChild(segment) then
                            currObj = currObj:FindFirstChild(segment)
                        elseif currObj then
                            pcall(function() currObj = game:GetService(segment) end)
                        end
                    end
                    if not currObj or (currObj.Name ~= name) then
                    end
                end
            else
                new_index[full_path] = {sha = child_sha, mode = entry_mode}
            end
        end
    end

    local new_index = {}
    build_index_from_tree(target_tree_sha, "", new_index)
    
    local old_index = nil
    if mode == "--hard" then
        old_index = Handlers.read_index()
    end

    Handlers.write_index(new_index)
    bash.modifyFileContents(bash.getGitFolderRoot(), "last_commit_index", HttpService:JSONEncode(new_index))

    if mode == "--hard" then
        local to_destroy = {}
        for path, _ in pairs(old_index) do
            if not new_index[path] then
                local clean_path = path:match("^(.-)/%.properties$") or path
                local currObj = Utilities.parse_path(clean_path)
                if currObj and currObj ~= game and currObj.Parent ~= game then
                    table.insert(to_destroy, currObj)
                end
            end
        end
        for _, obj in ipairs(to_destroy) do
            pcall(function() obj:Destroy() end)
        end

        for _, service in ipairs(bash.trackingRoot) do
            local obj = Handlers.read_object(target_tree_sha)
            if obj then
                local content = obj.content
                local pos = 1
                while pos <= #content do
                    local spacePos = content:find(" ", pos, true)
                    local entry_mode = content:sub(pos, spacePos - 1)
                    local nullPos = content:find("\0", spacePos, true)
                    local name = content:sub(spacePos + 1, nullPos - 1)
                    local rawSha = content:sub(nullPos + 1, nullPos + 20)
                    local child_sha = ("%02x"):rep(20):format(rawSha:byte(1, 20))
                    pos = nullPos + 21
                    
                    if entry_mode == "40000" and service.Name == name then
                        local objectsByShaFallback = setmetatable({}, {
                            __index = function(_, key)
                                local obj = Handlers.read_object(key)
                                if not obj then return nil end
                                return {
                                    objType = ({commit=1, tree=2, blob=3, tag=4})[obj.type],
                                    content = obj.content
                                }
                            end
                        })
                        Remote.writeTree(objectsByShaFallback, child_sha, service, name)
                    end
                end
            end
        end
        
        Remote.resolve_instance_refs()
        print("HEAD is now at " .. target_sha:sub(1, 7))
    elseif mode == "--mixed" or mode == "--soft" then
        print("Unstaged changes after reset:")
    end
end)

--[[
commands:
config

change/set configurations for repository/global
]]
arguments.createArgument("git", "config", "", function(...)
    local tuple = {...}
    local is_global = false
    local args_start = 1
    
    if tuple[1] == "--global" then
        is_global = true
        args_start = 2
    end
    
    local key = tuple[args_start]
    local value = tuple[args_start + 1]
    
    if not key or key == "" then
        print("usage: git config [<options>]")
        return
    end
    
    local key_parts = string.split(key, ".")
    local section = key_parts[1]
    local property = key_parts[2]
    
    local sensitive_keys = {
        ["user.name"] = true,
        ["user.email"] = true,
        ["user.token"] = true,
        ["user.password"] = true,
        ["user_name"] = true,
        ["user_email"] = true,
        ["user_token"] = true,
        ["user_password"] = true
    }

    if value then
        if (is_global or sensitive_keys[key]) and ACTIVE_PLUGIN then
            local sanitized_key = key:gsub("%.", "_")
            ACTIVE_PLUGIN:SetSetting(sanitized_key, value)
            print("Set '" .. sanitized_key .. "' in plugin settings")
            return
        end
    end

    local root = bash.getGitFolderRoot()
    if not root then
        error("fatal: not in a git directory")
        return
    end
    
    local config_content = bash.getFileContents(root, "config")
    local loaded_conf = ini_parser.parseIni(config_content)
    
    if value then
        if not loaded_conf[section] then
            loaded_conf[section] = {}
        end
        loaded_conf[section][property] = value
        bash.modifyFileContents(root, "config", ini_parser.serializeIni(loaded_conf))
    else
        local val = Auth.getConfigValue(key)
        if val then
            print(val)
        end
    end
end)

--[[
commands:
credential

manage credentials
]]
arguments.createArgument("git", "credential", "", function(...)
    local tuple = {...}
    local cmd = tuple[1]
    if cmd == "reject" then
        local url = tuple[2]
        if not url then
            print("usage: git credential (fill|approve|reject)")
            return
        end
        local base_url = url:match("^(https?://[^/]+)") or url
        if Auth.memory_credentials[base_url] then
            Auth.memory_credentials[base_url] = nil
            print("Cleared cached credentials for '" .. base_url .. "'")
        else
            print("No cached credentials to clear for '" .. base_url .. "'")
        end
    elseif cmd == "fill" or cmd == "approve" then
        -- roGit handles these implicitly during fetch/push via Auth.memory_credentials
        return
    else
        print("usage: git credential (fill|approve|reject)")
    end
end)

return git
