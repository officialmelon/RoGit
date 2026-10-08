
--[[
This is an extremely large file that should be cleaned/split for future reference.
This holds all the commands for `git` & most functionality.

]]
local git = {}

local HttpService = game:GetService("HttpService")

local config = require(script.Parent.config)
local arguments = require(script.Parent.arguments)
local git_remote = require(script.Parent.libs.git_remote)

local bash = require(script.Parent.bash)
local git_proto = require(script.Parent.libs.git_proto)
local ini_parser = require(script.Parent.libs.ini_parser)
local Handlers = require(script.Parent.libs.git_handlers)
local instances = require(script.Parent.libs.instances)
local Utilities = require(script.Parent.libs.utilities)
local Auth = require(script.Parent.libs.localstore)
local Requests = require(script.Parent.libs.requests)
local Remote = require(script.Parent.libs.git_remote)
local merge = require(script.Parent.libs.merge)
local diff = require(script.Parent.libs.diff)


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
    return Handlers.blob_sha(content)
end

--[[
Reads the index as of the last commit (used to tell staged changes apart).
]]
local function read_last_index()
    local raw = bash.getFileContents(bash.getGitFolderRoot(), "last_commit_index")
    if raw and raw ~= "" then
        return HttpService:JSONDecode(raw)
    end
    return {}
end

--[[
Builds the "Name <email>" signature used for commits and tags.
]]
local function make_signature()
    local user_name = Auth.getConfigValue("user_name") or Auth.getConfigValue("user.name") or "roGit"
    local user_email = Auth.getConfigValue("user_email") or Auth.getConfigValue("user.email") or "ro-git@example.com"
    return string.format("%s <%s> %d +0000", user_name, user_email, os.time())
end

--[[
Writes a commit object and moves HEAD (and the branch it points at) to it.
]]
local function create_commit(tree_sha, parents, message)
    local lines = {"tree " .. tree_sha}
    for _, parent in ipairs(parents) do
        table.insert(lines, "parent " .. parent)
    end
    local signature = make_signature()
    table.insert(lines, "author " .. signature)
    table.insert(lines, "committer " .. signature)

    local sha = Handlers.write_object("commit", table.concat(lines, "\n") .. "\n\n" .. message)
    Handlers.update_ref("HEAD", sha)
    return sha
end

--[[
Get all changes in our worktree.
]]
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

--[[
Is ancestor a commit of descendant?
]]
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

--[[
Returns the children of an instance that roGit tracks (ignores .rogitignore'd instances and the .git folder),
in the same deterministic order used when staging. Duplicate names get a stable id so they can be told apart.
]]
local function tracked_children(parent, seen_ids)
    local gitRoot = bash.getGitFolderRoot()
    local children = {}
    local counts = {}
    for _, child in ipairs(parent:GetChildren()) do
        if child ~= gitRoot and not (gitRoot and child:IsDescendantOf(gitRoot)) and not Handlers.is_ignored(child:GetFullName()) then
            table.insert(children, child)
            counts[child.Name] = (counts[child.Name] or 0) + 1
        end
    end

    for _, child in ipairs(children) do
        if counts[child.Name] > 1 then
            local id = child:GetAttribute(ROGIT_ID)
            if not id or id == "" or seen_ids[id] then
                id = HttpService:GenerateGUID(false)
                child:SetAttribute(ROGIT_ID, id)
            end
            seen_ids[id] = true
        end
    end

    table.sort(children, function(a, b)
        if a.Name ~= b.Name then
            return a.Name < b.Name
        end
        return (a:GetAttribute(ROGIT_ID) or "") < (b:GetAttribute(ROGIT_ID) or "")
    end)

    return children, counts
end

--[[
Finds every tracked instance that is not part of the index yet. Returns a set of virtual paths.
]]
local function collect_untracked(index)
    local untracked = {}
    local seen_ids = {}

    local function traverse(children, counts, path_prefix)
        local seen_local = {}

        for _, child in ipairs(children) do
            Utilities.roYield()
            local virtualName = child.Name
            if counts[child.Name] > 1 then
                seen_local[child.Name] = (seen_local[child.Name] or 0) + 1
                virtualName = child.Name .. " [" .. tostring(seen_local[child.Name]) .. "]"
            end

            local my_path = path_prefix == "" and virtualName or (path_prefix .. "/" .. virtualName)
            local grandchildren, grandCounts = tracked_children(child, seen_ids)

            local index_path = #grandchildren > 0 and (my_path .. "/.properties") or my_path
            if not index[index_path] and not index[my_path] then
                untracked[my_path] = true
            end

            traverse(grandchildren, grandCounts, my_path)
        end
    end

    for _, service in ipairs(bash.trackingRoot) do
        local children, counts = tracked_children(service, seen_ids)
        traverse(children, counts, service.Name)
    end

    return untracked
end

--[[
Returns a combined table of all active working tree/index changes for the UI.
]]
function git.get_changes()
    Handlers.load_ignore_patterns()
    local index = Handlers.read_index()
    local last_index = read_last_index()

    local changes = {}
    local seen_paths = {}

    --// STAGED (Compared to last commit)
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

    --// UNSTAGED (Compared to index)
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

    --// UNTRACKED (Files not in index at all)
    for path in pairs(collect_untracked(index)) do
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
            commit = "git-commit - Record changes to the repository.\n\nUsage: git commit [-a] [-m <msg>] [--amend] [--allow-empty]\n\n    -m, --message <msg>   commit message\n    -a, --all             stage all changes first\n    --amend               replace the last commit",
            push = "git-push - Update remote refs along with associated objects.\n\nUsage: git push [<options>] [<repository> [<refspec>...]]\n\n    -u, --set-upstream    set upstream for git pull/status\n    -f, --force           allow non-fast-forward updates\n    --all                 push all branches\n    --tags                push all tags\n    -d, --delete          delete the given remote refs",
            pull = "git-pull - Fetch from and integrate with another repository or a local branch.\n\nUsage: git pull [<options>] [<repository> [<branch>]]\n\n    --ff-only             refuse to merge, only fast-forward\n    -X ours|theirs        settle merge conflicts in favour of one side",
            status = "git-status - Show the working tree status.\n\nUsage: git status",
            branch = "git-branch - List, create, or delete branches.\n\nUsage: git branch [-a | -r] [-v]\n       git branch <branchname> [<start-point>]\n       git branch -d | -D <branchname>\n       git branch -m [<oldbranch>] <newbranch>",
            switch = "git-switch - Switch branches.\n\nUsage: git switch [<options>] <branch>\n\n    -c, --create <branch>  create and switch to a new branch\n    -d, --detach <commit>  switch to a commit in detached HEAD mode",
            clone = "git-clone - Clone a repository into a new directory.\n\nUsage: git clone [<options>] <repository>\n\n    -b, --branch <branch>  checkout <branch> instead of the remote's HEAD\n    --single-branch        only download the history of one branch",
            fetch = "git-fetch - Download objects and refs from another repository.\n\nUsage: git fetch [<repository>]",
            reset = "git-reset - Reset current HEAD to the specified state.\n\nUsage: git reset [--soft | --mixed | --hard] [<commit>]\n\n    --hard       reset HEAD, index and working tree",
            rm = "git-rm - Remove files from the working tree and from the index.\n\nUsage: git rm [-r] <file>...",
            diff = "git-diff - Show what changed in the working tree.\n\nUsage: git diff [--cached] [--name-only] [<path>...]\n\nShows property changes of every modified instance, and a line diff for scripts.",
            show = "git-show - Show a commit and the instances it changed.\n\nUsage: git show [<commit>] [--name-only]",
            merge = "git-merge - Join two or more development histories together.\n\nUsage: git merge [--no-ff] [-m <msg>] [-X ours|theirs] <commit-or-branch>\n\nInstances changed on both sides are merged property by property, scripts line by line.\nIf something can't be merged the merge stops without changing anything.",
            mv = "git-mv - Move or rename a file, a directory, or a symlink.\n\nUsage: git mv <source> <destination>",
            restore = "git-restore - Restore working tree files.\n\nUsage: git restore <pathspec>",
            remote = "git-remote - Manage set of tracked repositories.\n\nUsage: git remote [-v | --verbose]\n       git remote add [-f] <name> <url>\n       git remote remove <name>\n       git remote set-url <name> <newurl>",
            init = "git-init - Create an empty Git repository or reinitialize an existing one.\n\nUsage: git init [-q | --quiet] [-b <branch-name>]",
            log = "git-log - Show commit logs.\n\nUsage: git log [--oneline] [-n <number>] [<revision>]",
            tag = "git-tag - Create, list, delete tags.\n\nUsage: git tag [-l [<pattern>]]\n       git tag [-a -m <msg>] <tagname> [<commit>]\n       git tag -d <tagname>",
            config = "git-config - Get and set repository or global options.\n\nUsage: git config [--global] <name> [<value>]",
            version = "git-version - Show the RoGit version information.\n\nUsage: git version",
            credential = "git-credential - Prompt for and cache user credentials.\n\nUsage: git credential (fill|approve|reject)",
            checkout = "git-checkout - Switch branches or restore working tree files.\n\nUsage: git checkout [-b] <branchname>\n       git checkout <commit-or-tag>   (detached HEAD)\n       git checkout -- <pathspec>..."
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
   show      Show a commit and the instances it changed
   status    Show the working tree status

grow, mark and tweak your common history
   branch    List, create, or delete branches
   checkout  Switch branches or restore working tree files
   commit    Record changes to the repository
   switch    Switch branches
   merge     Join two or more development histories together
   tag       Create, list, delete tags
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
Turns a user supplied path (Workspace/Part, game.Workspace.Part) into an index style path.
]]
local function normalize_user_path(path)
    path = path:gsub("^game[./]", "")
    if not path:find("/", 1, true) then
        path = path:gsub("%.", "/")
    end
    return (path:gsub("/+$", ""))
end

local function matches_filters(path, filters)
    if #filters == 0 then return true end
    local entity = path:match("^(.-)/%.properties$") or path
    for _, filter in ipairs(filters) do
        if entity == filter or entity:sub(1, #filter + 1) == filter .. "/" then
            return true
        end
    end
    return false
end

local function read_blob_content(sha)
    local obj = sha and Handlers.read_object(sha)
    return obj and obj.type == "blob" and obj.content or nil
end

--[[
commands:
diff

View what changed in the working tree (or, with --cached, in the staged changes).
Shows property level changes, and a line diff for scripts.
]]
arguments.createArgument("git", "diff", "", function(...)
    assert(bash.getGitFolderRoot(), "fatal: not a git repository")
    Handlers.load_ignore_patterns()

    local cached = false
    local names_only = false
    local filters = {}
    for _, arg in ipairs({...}) do
        if arg == "--cached" or arg == "--staged" then
            cached = true
        elseif arg == "--name-only" or arg == "--stat" or arg == "--name-status" then
            names_only = true
        elseif arg ~= "--" and arg:sub(1, 1) ~= "-" then
            table.insert(filters, normalize_user_path(arg))
        end
    end

    local index = Handlers.read_index()
    local entries = {}

    if cached then
        local last_index = read_last_index()
        for path, data in pairs(index) do
            if not last_index[path] then
                table.insert(entries, {path = path, status = "A", new = data.sha})
            elseif last_index[path].sha ~= data.sha then
                table.insert(entries, {path = path, status = "M", old = last_index[path].sha, new = data.sha})
            end
        end
        for path, data in pairs(last_index) do
            if not index[path] then
                table.insert(entries, {path = path, status = "D", old = data.sha})
            end
        end
    else
        for path, data in pairs(index) do
            Utilities.roYield()
            local currObj = Utilities.parse_path(path:match("^(.-)/%.properties$") or path)
            if not currObj then
                table.insert(entries, {path = path, status = "D", old = data.sha})
            else
                local serialized = instances.serialize_instance(currObj)
                if compute_blob_sha(serialized) ~= data.sha then
                    table.insert(entries, {path = path, status = "M", old = data.sha, live = serialized})
                end
            end
        end
    end

    table.sort(entries, function(x, y) return x.path < y.path end)

    local colors = {A = "\27[32m", M = "\27[33m", D = "\27[31m"}
    local shown = 0
    for _, entry in ipairs(entries) do
        if matches_filters(entry.path, filters) then
            shown += 1
            print(colors[entry.status] .. entry.status .. "\27[0m  " .. entry.path)
            if not names_only and entry.status == "M" then
                for _, line in ipairs(diff.describe(read_blob_content(entry.old), entry.live or read_blob_content(entry.new))) do
                    print(line)
                end
            end
        end
    end

    if not cached then
        local untracked = {}
        for path in pairs(collect_untracked(index)) do
            if matches_filters(path, filters) then
                table.insert(untracked, path)
            end
        end
        table.sort(untracked)
        for _, path in ipairs(untracked) do
            shown += 1
            print("\27[31m??\27[0m " .. path)
        end
    end

    if shown == 0 then
        print(cached and "No staged changes." or "Everything up-to-date with index.")
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

--[[
Lists staged/unstaged changes to tracked instances (untracked ones are ignored, they can't be overwritten).
]]
local function dirty_changes()
    local dirty = {}
    for _, change in ipairs(git.get_changes()) do
        if change.status ~= "U" then
            table.insert(dirty, change.path)
        end
    end
    return dirty
end

local function print_dirty_abort(dirty, action)
    local lines = {"error: Your local changes to the following files would be overwritten by " .. action .. ":"}
    for _, path in ipairs(dirty) do
        table.insert(lines, "\t" .. path)
    end
    table.insert(lines, "Please commit your changes or restore them before you " .. (action == "merge" and "merge" or "switch branches") .. ".")
    table.insert(lines, "Aborting")
    error(table.concat(lines, "\n"))
end

--[[
Merges the commit `target_sha` into the current branch.
Fast-forwards when possible, otherwise performs a three-way merge of the instances and creates a merge commit.
Returns true on success; on conflicts nothing is changed and false is returned.

opts: prefer ("ours" | "theirs"), no_ff, message
]]
local function perform_merge(target_sha, label, opts)
    opts = opts or {}
    local head_sha = Handlers.get_ref("HEAD")
    if head_sha == "" then head_sha = nil end

    local target_commit = Handlers.read_commit(target_sha)
    assert(target_commit and target_commit.tree, "fatal: " .. tostring(target_sha) .. " is not a commit we have locally")

    if head_sha and (head_sha == target_sha or is_ancestor_commit(target_sha, head_sha)) then
        print("Already up to date.")
        return true
    end

    local dirty = dirty_changes()
    if #dirty > 0 then
        print_dirty_abort(dirty, "merge")
        return false
    end

    if not head_sha or (is_ancestor_commit(head_sha, target_sha) and not opts.no_ff) then
        print(string.format("Updating %s..%s", string.sub(head_sha or "0000000", 1, 7), string.sub(target_sha, 1, 7)))
        Handlers.update_ref("HEAD", target_sha)
        local ok, err = Remote.checkout(target_commit.tree)
        assert(ok, err)
        print("Fast-forward")
        return true
    end

    local head_commit = Handlers.read_commit(head_sha)
    local base_sha = Handlers.merge_base(head_sha, target_sha)
    local base_commit = base_sha and Handlers.read_commit(base_sha)

    print("Merging " .. label .. " into " .. (Handlers.get_current_branch() or "HEAD") .. "...")
    local merged_index, conflicts, combined = merge.merge_indexes(
        base_commit and Handlers.tree_to_index(base_commit.tree) or {},
        Handlers.tree_to_index(head_commit.tree),
        Handlers.tree_to_index(target_commit.tree),
        {
            prefer = opts.prefer,
            read_blob = read_blob_content,
            write_blob = function(content) return Handlers.write_blob(content) end,
        }
    )

    if #conflicts > 0 then
        local lines = {}
        for _, conflict in ipairs(conflicts) do
            table.insert(lines, "CONFLICT (" .. conflict.reason .. "): " .. conflict.path)
        end
        table.insert(lines, "Automatic merge failed; nothing was changed.")
        table.insert(lines, "hint: re-run with '-X ours' or '-X theirs' to settle the conflicts in favour of one side.")
        error(table.concat(lines, "\n"))
        return false
    end

    local tree_sha = Handlers.write_tree(merged_index)
    local commit_sha = create_commit(tree_sha, {head_sha, target_sha}, opts.message or ("Merge " .. label))
    local ok, err = Remote.checkout(tree_sha)
    assert(ok, err)

    table.sort(combined)
    for _, path in ipairs(combined) do
        print("Auto-merging " .. path)
    end
    print(string.format("Merge made by the 'roGit' strategy. [%s]", string.sub(commit_sha, 1, 7)))
    return true
end

--[[
commands:
merge

Joins another branch (or commit) into the current branch.
Instances changed on both sides are merged property by property, scripts line by line.
]]
arguments.createArgument("git", "merge", "", function(...)
    assert(bash.getGitFolderRoot(), "fatal: not a git repository (or any of the parent directories): .git")

    local tuple = {...}
    local rev = nil
    local opts = {}

    local i = 1
    while i <= #tuple do
        local arg = tuple[i]
        if arg == "--no-ff" then
            opts.no_ff = true
        elseif arg == "-m" and tuple[i + 1] then
            opts.message = tuple[i + 1]
            i += 1
        elseif arg == "-X" and tuple[i + 1] then
            opts.prefer = tuple[i + 1]
            i += 1
        elseif arg:match("^%-X(%a+)$") then
            opts.prefer = arg:match("^%-X(%a+)$")
        elseif arg:match("^%-%-strategy%-option=(%a+)$") then
            opts.prefer = arg:match("^%-%-strategy%-option=(%a+)$")
        elseif arg:sub(1, 1) ~= "-" then
            rev = arg
        end
        i += 1
    end

    if opts.prefer and opts.prefer ~= "ours" and opts.prefer ~= "theirs" then
        error("fatal: unknown strategy option '" .. opts.prefer .. "' (use ours or theirs)")
        return
    end

    if not rev then
        error("fatal: No commit specified and merge.defaultToUpstream not set.")
        return
    end

    local target_sha = Handlers.resolve_revision(rev)
    if not target_sha then
        print("merge: " .. rev .. " - not something we can merge")
        return
    end

    local label = (rev:find("/", 1, true) and Handlers.get_ref("refs/remotes/" .. rev)) and ("remote-tracking branch '" .. rev .. "'")
        or ("branch '" .. rev .. "'")
    perform_merge(target_sha, label, opts)
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

        for idx_path, data in pairs(index) do
            local clean_path = idx_path:match("^(.-)/%.properties$") or idx_path
            local targetObj = Utilities.parse_path(clean_path)
            
            if not targetObj then
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
    Handlers.load_ignore_patterns()

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

Fetches the latest commits and integrates them: fast-forwards when it can, merges when the branches have diverged.
]]
arguments.createArgument("git", "pull", "", function (...)
    assert(bash.getGitFolderRoot(), "fatal: not a git repository (or any of the parent directories): .git")

    local positional = {}
    local ff_only = false
    local opts = {}
    local tuple = {...}
    local i = 1
    while i <= #tuple do
        local arg = tuple[i]
        if arg == "--ff-only" then
            ff_only = true
        elseif arg == "--no-ff" then
            opts.no_ff = true
        elseif arg == "-X" and tuple[i + 1] then
            opts.prefer = tuple[i + 1]
            i += 1
        elseif arg:match("^%-X(%a+)$") then
            opts.prefer = arg:match("^%-X(%a+)$")
        elseif arg:sub(1, 1) ~= "-" then
            table.insert(positional, arg)
        end
        i += 1
    end

    local remote_name = positional[1] or "origin"
    local current_branch = Handlers.get_current_branch()
    local branch_name = positional[2] or current_branch or "master"

    local refs = Remote.fetch(remote_name)
    local remoteSha = refs["refs/heads/" .. branch_name]
    assert(remoteSha, "fatal: couldn't find remote ref 'refs/heads/" .. branch_name .. "'")

    Handlers.update_ref("refs/remotes/" .. remote_name .. "/" .. branch_name, remoteSha)

    local head_sha = Handlers.get_ref("HEAD")
    local local_branch_sha = Handlers.get_ref("refs/heads/" .. branch_name)
    if not local_branch_sha and current_branch == branch_name then
        local_branch_sha = head_sha
    end

    local remote_commit = Handlers.read_commit(remoteSha)
    assert(remote_commit and remote_commit.tree, "fatal: the remote commit " .. remoteSha .. " was not downloaded")

    if current_branch == branch_name then
        --// If we are already up to date, make sure the instances still match the tree
        if local_branch_sha == remoteSha then
            local index = Handlers.read_index()
            for path, _ in pairs(index) do
                local clean = path:match("^(.-)/%.properties$") or path
                if not Utilities.parse_path(clean) then
                    local dirty = dirty_changes()
                    if #dirty > 0 then
                        print_dirty_abort(dirty, "merge")
                        return
                    end
                    print("Restoring missing instances...")
                    local ok, err = Remote.checkout(remote_commit.tree)
                    assert(ok, err)
                    return
                end
            end
            print("Already up to date.")
            return
        end

        if ff_only and local_branch_sha and not is_ancestor_commit(local_branch_sha, remoteSha) then
            error("fatal: Not possible to fast-forward, aborting.")
            return
        end

        local label = "branch '" .. branch_name .. "' of " .. remote_name
        if perform_merge(remoteSha, label, opts) then
            print("Successfully pulled from " .. branch_name)
        end
        return
    end

    --// Pulling a branch that is not checked out: only fast-forwards are possible
    if local_branch_sha == remoteSha or (local_branch_sha and is_ancestor_commit(remoteSha, local_branch_sha)) then
        print("Already up to date.")
        return
    end
    if local_branch_sha and not is_ancestor_commit(local_branch_sha, remoteSha) then
        error("fatal: Not possible to fast-forward, aborting.")
        print("hint: Switch to '" .. branch_name .. "' and run 'git pull' to merge the remote changes.")
        return
    end

    print("Updating " .. string.sub(local_branch_sha or "0000000", 1, 7) .. ".." .. string.sub(remoteSha, 1, 7))
    Handlers.update_ref("refs/heads/" .. branch_name, remoteSha)
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
    local messages = {}
    local allow_empty = false
    local amend = false
    local stage_all = false

    local i = 1
    while i <= #tuple do
        local arg = tuple[i]
        if (arg == "-m" or arg == "--message") and tuple[i + 1] then
            table.insert(messages, tuple[i + 1])
            i += 1
        elseif arg:match("^%-%-message=") then
            table.insert(messages, arg:match("^%-%-message=(.*)$"))
        elseif (arg == "-am" or arg == "-ma") and tuple[i + 1] then
            stage_all = true
            table.insert(messages, tuple[i + 1])
            i += 1
        elseif arg == "-a" or arg == "--all" then
            stage_all = true
        elseif arg == "--allow-empty" then
            allow_empty = true
        elseif arg == "--amend" then
            amend = true
        end
        i += 1
    end

    local message = table.concat(messages, "\n\n")
    if message == "" and not amend then
        message = "default commit message"
    end

    if stage_all then
        arguments.execute("git", "add", ".")
    end

    local index = Handlers.read_index()
    local last_index = read_last_index()

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
    if parent_sha == "" then parent_sha = nil end

    local parents = {}
    if amend then
        local old_commit = Handlers.read_commit(parent_sha)
        if old_commit then
            parents = old_commit.parents
            if message == "" then
                message = old_commit.message ~= "" and old_commit.message or "default commit message"
            end
        end
    elseif parent_sha then
        parents = {parent_sha}
    end

    local tree_sha = Handlers.write_tree(index)
    local commit_sha = create_commit(tree_sha, parents, message)

    bash.writeFile(bash.getGitFolderRoot(), "last_commit_index", HttpService:JSONEncode(index))

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
    table.sort(output_details)

    local stats_line = ""
    if num_files_changed > 0 then
        stats_line = string.format(" %d file%s changed, %d insertion%s(+), %d deletion%s(-)",
            num_files_changed, num_files_changed == 1 and "" or "s",
            total_insertions, total_insertions == 1 and "" or "s",
            total_deletions, total_deletions == 1 and "" or "s")
    end

    local branch = Handlers.get_current_branch()
    local label = branch or "detached HEAD"
    if #parents == 0 then
        label = label .. " (root-commit)"
    end

    local final_output = string.format("[%s %s] %s", label, string.sub(commit_sha, 1, 7), message:match("^[^\n]*"))
    if num_files_changed > 0 then
        final_output = final_output .. "\n" .. stats_line
    end
    if #output_details > 0 then
        if #output_details > 20 then
            local new_details = {}
            for n = 1, 20 do table.insert(new_details, output_details[n]) end
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
    local single_branch = false
    local url = nil
    local repo_dir = nil

    local i = 1
    while i <= #tuple do
        local arg = tuple[i]
        if (arg == "-b" or arg == "--branch") and tuple[i + 1] then
            branch_override = tuple[i + 1]
            i += 1
        elseif arg == "--single-branch" then
            single_branch = true
        elseif arg == "--depth" or arg == "--origin" or arg == "-o" then
            i += 1 --// accepted for compatibility, roGit always clones full history
        elseif arg:sub(1, 1) ~= "-" then -- Positional argument
            if not url then
                url = arg
            elseif not repo_dir then
                repo_dir = arg
            end
        end
        i += 1
    end

    if not url or url == "" then
        error("fatal: You must specify a repository to clone.")
        print("\nusage: git clone [<options>] [--] <repo> [<dir>]\n\n    -b, --branch <branch>  checkout <branch> instead of the remote's HEAD\n    --single-branch        only download the history of one branch")
        return
    end
    url = Utilities.normalize_url(url)

    local existing_root = bash.getGitFolderRoot()
    if existing_root and Handlers.get_ref("HEAD") then
        error("fatal: this place already contains a repository with commits. Clone into a fresh place instead.")
        return
    end

    local repoName = repo_dir or url:match("/([^/]+)$") or "repository"
    repoName = repoName:gsub("%.git$", "")
    print("Cloning into '" .. repoName .. "'...")

    local created_here = false
    if not existing_root then
        arguments.execute("git", "init", "-q")
        created_here = true
    end
    local existing_config = ini_parser.parseIni(bash.getFileContents(bash.getGitFolderRoot(), "config") or "")
    arguments.execute("git", "remote", existing_config['remote "origin"'] and "set-url" or "add", "origin", url)

    local function abort_clone()
        if created_here then
            local root = bash.getGitFolderRoot()
            if root then root:Destroy() end
        end
    end

    local ok_discover, refs, info = pcall(Remote.discoverRefs, url)
    if not ok_discover then
        abort_clone()
        error(refs, 0)
    end

    --// Work out which branch gets checked out
    local activeBranch = branch_override
    local headSha
    if branch_override then
        headSha = refs["refs/heads/" .. branch_override] or refs["refs/tags/" .. branch_override]
        if not headSha then
            abort_clone()
            error("fatal: Remote branch '" .. branch_override .. "' not found in upstream origin")
            return
        end
    else
        local symref = info.symrefs and info.symrefs["HEAD"]
        activeBranch = symref and symref:match("^refs/heads/(.+)$")
        headSha = activeBranch and refs[symref] or refs["HEAD"]
        if not activeBranch then
            for _, candidate in ipairs({"master", "main"}) do
                if refs["refs/heads/" .. candidate] and (not headSha or refs["refs/heads/" .. candidate] == headSha) then
                    activeBranch = candidate
                    break
                end
            end
            headSha = headSha or (activeBranch and refs["refs/heads/" .. activeBranch])
            if not activeBranch then
                for refName, sha in pairs(refs) do
                    if sha == headSha and refName:match("^refs/heads/") then
                        activeBranch = refName:sub(12)
                        break
                    end
                end
            end
        end
    end

    if not headSha or headSha == "" then
        print("warning: You appear to have cloned an empty repository.")
        return
    end
    activeBranch = activeBranch or "master"

    --// Download everything in one go
    local wants, wantSet = {}, {}
    local function want(sha)
        if not wantSet[sha] then
            wantSet[sha] = true
            table.insert(wants, sha)
        end
    end
    want(headSha)
    if not single_branch then
        for refName, sha in pairs(refs) do
            if refName:match("^refs/heads/") or (refName:match("^refs/tags/") and not refName:match("%^{}$")) then
                want(sha)
            end
        end
    end
    table.sort(wants, function(x, y)
        if x == headSha then return y ~= headSha end
        if y == headSha then return false end
        return x < y
    end)

    local packFile = Remote.fetchPackfile(url, wants)
    local _, objectsBySha = Remote.unpackObjects(packFile)
    Remote.storeObjects(objectsBySha)

    local gitRoot = bash.getGitFolderRoot()
    bash.modifyFileContents(gitRoot, "HEAD", "ref: refs/heads/" .. activeBranch)
    for refName, sha in pairs(refs) do
        if refName:match("^refs/heads/") then
            local bName = refName:sub(12)
            if not single_branch or bName == activeBranch then
                Handlers.update_ref("refs/remotes/origin/" .. bName, sha)
            end
            if bName == activeBranch then
                Handlers.update_ref("refs/heads/" .. bName, sha)
            end
        elseif refName:match("^refs/tags/") and not refName:match("%^{}$") then
            if wantSet[sha] then
                Handlers.update_ref(refName, sha)
            end
        end
    end
    if branch_override and not refs["refs/heads/" .. branch_override] then
        --// cloned a tag: detach HEAD at it
        bash.modifyFileContents(gitRoot, "HEAD", headSha)
        activeBranch = nil
    end

    if activeBranch then
        local config_content = bash.getFileContents(gitRoot, "config")
        local loaded_conf = ini_parser.parseIni(config_content)
        loaded_conf['branch "' .. activeBranch .. '"'] = {
            remote = "origin",
            merge = "refs/heads/" .. activeBranch
        }
        bash.modifyFileContents(gitRoot, "config", ini_parser.serializeIni(loaded_conf))
    end

    local headCommit = objectsBySha[headSha]
    assert(headCommit, "HEAD commit not found in packfile")

    local treeSha = headCommit.content:match("^tree (%x+)")
    assert(treeSha, "Could not parse tree SHA from commit")

    local treeObj = objectsBySha[treeSha]
    assert(treeObj, "Missing root tree: " .. treeSha)

    local function find_rogit_project(current_tree_sha)
        local obj = objectsBySha[current_tree_sha]
        if not obj then return false end

        for _, entry in ipairs(Handlers.parse_tree(obj.content)) do
            Utilities.roYield()
            if entry.name == ".rogit_project" then
                return true
            elseif entry.mode == "40000" and find_rogit_project(entry.sha) then
                return true
            end
        end
        return false
    end

    if not find_rogit_project(treeSha) then
        abort_clone()
        error("fatal: repository does not appear to be a rogit project (missing .rogit_project file).")
        return
    end

    for _, entry in ipairs(Handlers.parse_tree(treeObj.content)) do
        Utilities.roYield()
        if entry.mode == "40000" then
            local serviceParent = game:FindFirstChild(entry.name)
            if not serviceParent then
                pcall(function()
                    serviceParent = game:GetService(entry.name)
                end)
            end
            if serviceParent then
                local childProps = Remote.peekPropertiesBlob(objectsBySha, entry.sha)
                if childProps then
                    Remote.applyProperties(serviceParent, childProps)
                end
                Remote.writeTree(objectsBySha, entry.sha, serviceParent, entry.name)
            end
        end
    end

    Remote.resolve_instance_refs()

    local new_index = Remote.buildIndexFromTree(objectsBySha, treeSha)
    Handlers.write_index(new_index)
    bash.writeFile(gitRoot, "last_commit_index", HttpService:JSONEncode(new_index))

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
        
        local remote_names = {}
        for section_name in pairs(loaded_conf) do
            local remote_name = section_name:match('^remote "(.+)"$')
            if remote_name then
                table.insert(remote_names, remote_name)
            end
        end
        table.sort(remote_names)

        for _, remote_name in ipairs(remote_names) do
            local section_data = loaded_conf['remote "' .. remote_name .. '"']
            if verbose then
                print(remote_name .. "\t" .. (section_data.url or "(no URL)") .. " (fetch)")
                print(remote_name .. "\t" .. (section_data.pushurl or section_data.url or "(no URL)") .. " (push)")
            else
                print(remote_name)
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
        url = Utilities.normalize_url(url)

        local config_content = bash.getFileContents(bash.getGitFolderRoot(), "config")
        local loaded_conf = ini_parser.parseIni(config_content)

        local section_name = 'remote "' .. name .. '"'
        if loaded_conf[section_name] and loaded_conf[section_name].url == url then
            return
        end
        if loaded_conf[section_name] then
            error("error: remote " .. name .. " already exists.")
            return
        end
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
        new_url = Utilities.normalize_url(new_url)

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
Splits the payload of a receive-pack status report ("000eunpack ok\n0019ok refs/heads/main\n0000") into lines.
]]
local function parse_report_lines(payload)
    local lines = {}
    local pos = 1
    while pos <= #payload do
        local len = tonumber(payload:sub(pos, pos + 3), 16)
        if not len then
            --// not framed, treat everything that's left as text
            for line in payload:sub(pos):gmatch("[^\r\n]+") do
                table.insert(lines, line)
            end
            break
        end
        if len == 0 then
            pos += 4
        elseif len < 4 then
            break
        else
            local line = payload:sub(pos + 4, pos + len - 1):gsub("[\r\n]+$", "")
            table.insert(lines, line)
            pos += len
        end
    end
    return lines
end

local ZERO_SHA = ("0"):rep(40)

--[[
commands:
push

pushes git repository commits to branch
Usage: git push [-f] [-u] [--all] [--tags] [-d] <remote> <refspec>...
]]
arguments.createArgument("git", "push", "", function(...)
    local tuple = {...}
    local force_push = false
    local set_upstream = false
    local push_all = false
    local push_tags = false
    local delete = false
    local positional = {}

    for _, arg in ipairs(tuple) do
        if arg == "-f" or arg == "--force" then
            force_push = true
        elseif arg == "-u" or arg == "--set-upstream" then
            set_upstream = true
        elseif arg == "--all" then
            push_all = true
        elseif arg == "--tags" then
            push_tags = true
        elseif arg == "-d" or arg == "--delete" then
            delete = true
        elseif arg:sub(1, 1) ~= "-" or arg == "-" then
            table.insert(positional, arg)
        end
    end

    local root = bash.getGitFolderRoot()
    assert(root, "fatal: not a git repository")

    local remote_name = table.remove(positional, 1) or "origin"
    local current_branch = Handlers.get_current_branch()

    local config_content = bash.getFileContents(root, "config")
    local loaded_conf = ini_parser.parseIni(config_content)

    local section_name = 'remote "' .. remote_name .. '"'
    local remote_section = loaded_conf[section_name]
    assert(remote_section and remote_section.url, "fatal: '" .. remote_name .. "' does not appear to be a git repository")
    local url = remote_section.pushurl or remote_section.url

    --// Work out what to push: a list of {src (local sha), dst (full ref name), force}
    local specs = {}
    local function add_spec(src_name, dst_ref, plus)
        local sha = nil
        if not delete then
            sha = Handlers.resolve_revision(src_name)
            assert(sha, "error: src refspec '" .. tostring(src_name) .. "' does not match any")
        end
        table.insert(specs, {sha = sha, ref = dst_ref, force = plus or force_push, label = (src_name == "HEAD" and current_branch) or src_name})
    end

    local function qualified(name, source_is_tag)
        if name:match("^refs/") then return name end
        if source_is_tag then return "refs/tags/" .. name end
        return "refs/heads/" .. name
    end

    if push_all then
        for _, branch in ipairs(Handlers.get_branches()) do
            add_spec(branch, "refs/heads/" .. branch)
        end
    end
    if push_tags then
        for refName, sha in pairs(Handlers.list_refs()) do
            local tag = refName:match("^refs/tags/(.+)$")
            if tag then
                table.insert(specs, {sha = sha, ref = refName, force = force_push, label = tag})
            end
        end
    end

    if #positional == 0 and #specs == 0 then
        assert(current_branch, "fatal: You are not currently on a branch.\nTo push the history leading to the current (detached HEAD) state, name a ref explicitly.")
        add_spec("HEAD", "refs/heads/" .. current_branch)
    end

    for _, spec in ipairs(positional) do
        local plus = spec:sub(1, 1) == "+"
        spec = plus and spec:sub(2) or spec
        local src, dst = spec:match("^(.-):(.+)$")
        src = src or spec
        dst = dst or spec

        if src == "HEAD" and not spec:find(":", 1, true) then
            assert(current_branch, "fatal: You are not currently on a branch.")
            src, dst = "HEAD", current_branch
        end

        local is_tag = Handlers.get_ref("refs/tags/" .. src) ~= nil and Handlers.get_ref("refs/heads/" .. src) == nil
        if delete then
            add_spec(src, qualified(spec, Handlers.get_ref("refs/tags/" .. spec) ~= nil and Handlers.get_ref("refs/heads/" .. spec) == nil), plus)
        elseif src == "HEAD" then
            add_spec("HEAD", qualified(dst), plus)
        else
            add_spec(src, qualified(dst, is_tag), plus)
        end
    end

    local refs = Remote.discoverRefs(url, "git-receive-pack")

    --// Decide which refs really need updating
    local updates = {}
    for _, spec in ipairs(specs) do
        local remoteSha = refs[spec.ref]
        local newSha = spec.sha or ZERO_SHA

        if delete then
            if remoteSha then
                table.insert(updates, {ref = spec.ref, old = remoteSha, new = ZERO_SHA, label = spec.label, delete = true})
            else
                print("error: unable to delete '" .. spec.ref:gsub("^refs/%a+/", "") .. "': remote ref does not exist")
            end
        elseif remoteSha ~= newSha then
            local rejected = false
            if remoteSha and spec.ref:match("^refs/heads/") and not spec.force then
                rejected = not is_ancestor_commit(remoteSha, newSha)
            elseif remoteSha and spec.ref:match("^refs/tags/") and not spec.force then
                rejected = true
            end

            if rejected then
                local short = spec.ref:gsub("^refs/%a+/", "")
                local lines = {
                    "To " .. url,
                    " ! [rejected]        " .. spec.label .. " -> " .. short .. (spec.ref:match("^refs/tags/") and " (already exists)" or " (non-fast-forward)"),
                    "error: failed to push some refs to '" .. url .. "'",
                }
                if spec.ref:match("^refs/heads/") then
                    table.insert(lines, "hint: Updates were rejected because the tip of your current branch is behind")
                    table.insert(lines, "hint: its remote counterpart. Integrate the remote changes (e.g.")
                    table.insert(lines, "hint: 'git pull') before pushing again, or use '--force' to overwrite.")
                end
                error(table.concat(lines, "\n"))
                return
            end
            table.insert(updates, {ref = spec.ref, old = remoteSha or ZERO_SHA, new = newSha, label = spec.label})
        end
    end

    if #updates == 0 then
        print("Everything up-to-date")
        return
    end

    --// Everything the server already has doesn't need to be sent again
    local known = {}
    for name, sha in pairs(refs) do
        if (name:match("^refs/heads/") or name:match("^refs/tags/")) and Handlers.read_object(sha) then
            table.insert(known, sha)
        end
    end

    local objects = {}
    local objectCount = 0
    local has_pack = false
    for _, update in ipairs(updates) do
        if not update.delete then
            has_pack = true
            for sha, obj in pairs(Handlers.collectObjects(update.new, known)) do
                if not objects[sha] then
                    objects[sha] = obj
                    objectCount += 1
                end
            end
        end
    end

    local packFile = ""
    if has_pack then
        print(string.format("Enumerating objects: %d, done.", objectCount))
        packFile = Handlers.buildPackfile(objects)
        local packSize = #packFile
        print(string.format("Writing objects: 100%% (%d/%d), %.2f KiB, done.", objectCount, objectCount, packSize / 1024))
    end

    local parts = {}
    for i, update in ipairs(updates) do
        local line = update.old .. " " .. update.new .. " " .. update.ref
        if i == 1 then
            line = line .. "\0report-status side-band-64k" .. (delete and " delete-refs" or "")
        end
        table.insert(parts, buffer.tostring(git_proto.encodePkt(buffer.fromstring(line .. "\n"))))
    end
    table.insert(parts, buffer.tostring(git_proto.flush()))
    table.insert(parts, packFile)

    local req = {
        Url = Utilities.return_urls(url, "git-receive-pack")[2],
        Method = "POST",
        Headers = {
            ["Content-Type"] = "application/x-git-receive-pack-request",
            ["Accept"] = "application/x-git-receive-pack-result",
            ["Authorization"] = Auth.getAuthHeader(url:match("^(https?://[^/]+)") or url)
        },
        Body = table.concat(parts),
    }

    local ok, res = Requests.url_request_with_retry(req)
    assert(ok, "Push request error: " .. tostring(res))

    if res.StatusCode ~= 200 then
        local lines = {"error: failed to push some refs to '" .. url .. "'", "remote: HTTP Status Code: " .. res.StatusCode}
        if res.StatusCode == 401 or res.StatusCode == 403 then
            table.insert(lines, "remote: authentication failed, check your username and token (git config --global user.token <token>)")
        end
        for line in string.gmatch(res.Body, "[^\n]+") do
            table.insert(lines, "remote: " .. line)
        end
        error(table.concat(lines, "\n"))
        return
    end

    local remote_messages = {}
    local results = {}
    local report_seen = false

    local response_buffer = buffer.fromstring(res.Body)
    local cursor = 0
    while cursor < buffer.len(response_buffer) do
        local data, next = git_proto.decodePkt(response_buffer, cursor)
        cursor = next
        Utilities.roYield()
        if data then
            local channel = buffer.readu8(data, 0)
            local text = buffer.tostring(data)
            if channel == 1 then
                for _, line in ipairs(parse_report_lines(text:sub(2))) do
                    report_seen = true
                    local okRef = line:match("^ok (.+)$")
                    local ngRef, reason = line:match("^ng (%S+) (.+)$")
                    if okRef then
                        results[okRef] = {ok = true}
                    elseif ngRef then
                        results[ngRef] = {ok = false, reason = reason}
                    elseif line:match("^unpack ") and line ~= "unpack ok" then
                        table.insert(remote_messages, "error: " .. line)
                    end
                end
            elseif channel == 2 then
                for line in text:sub(2):gmatch("[^\r\n]+") do
                    table.insert(remote_messages, "remote: " .. line)
                end
            elseif channel == 3 then
                table.insert(remote_messages, "remote error: " .. text:sub(2))
            else
                for _, line in ipairs(parse_report_lines(text)) do
                    local okRef = line:match("^ok (.+)$")
                    local ngRef, reason = line:match("^ng (%S+) (.+)$")
                    if okRef then
                        report_seen = true
                        results[okRef] = {ok = true}
                    elseif ngRef then
                        report_seen = true
                        results[ngRef] = {ok = false, reason = reason}
                    end
                end
            end
        end
    end

    if #remote_messages > 0 then
        print(table.concat(remote_messages, "\n"))
    end

    local summary = {"To " .. url}
    local failed = false
    for _, update in ipairs(updates) do
        local short = update.ref:gsub("^refs/%a+/", "")
        local result = results[update.ref]
        local accepted = (result and result.ok) or (not result and not report_seen)

        if accepted then
            local isTag = update.ref:match("^refs/tags/") ~= nil
            if update.delete then
                table.insert(summary, " - [deleted]         " .. short)
                Handlers.delete_ref("refs/remotes/" .. remote_name .. "/" .. short)
            elseif update.old == ZERO_SHA then
                table.insert(summary, string.format(" * [new %s]      %s -> %s", isTag and "tag" or "branch", update.label, short))
            else
                table.insert(summary, string.format("   %s..%s  %s -> %s", update.old:sub(1, 7), update.new:sub(1, 7), update.label, short))
            end

            if update.ref:match("^refs/heads/") and not update.delete then
                Handlers.update_ref("refs/remotes/" .. remote_name .. "/" .. short, update.new)
            end
        else
            failed = true
            table.insert(summary, string.format(" ! [remote rejected] %s -> %s (%s)", update.label, short, result and result.reason or "no status reported"))
        end
    end
    if failed then
        table.insert(summary, "error: failed to push some refs to '" .. url .. "'")
        error(table.concat(summary, "\n"))
        return
    end
    print(table.concat(summary, "\n"))

    if set_upstream then
        for _, update in ipairs(updates) do
            local branch = update.ref:match("^refs/heads/(.+)$")
            if branch and not update.delete then
                loaded_conf['branch "' .. branch .. '"'] = {
                    remote = remote_name,
                    merge = "refs/heads/" .. branch
                }
                bash.modifyFileContents(root, "config", ini_parser.serializeIni(loaded_conf))
                print("Branch '" .. branch .. "' set up to track remote branch '" .. branch .. "' from '" .. remote_name .. "'.")
            end
        end
    end
end)

--[[
Counts how many commits `local_sha` is ahead of / behind `other_sha`.
]]
local function count_ahead_behind(local_sha, other_sha)
    local mine, theirs = Handlers.ancestors(local_sha), Handlers.ancestors(other_sha)
    local ahead, behind = 0, 0
    for sha in pairs(mine) do
        if not theirs[sha] then ahead += 1 end
    end
    for sha in pairs(theirs) do
        if not mine[sha] then behind += 1 end
    end
    return ahead, behind
end

--[[
commands:
status
st

gets status of branch/changes
]]
arguments.createArgument("git", "status", "st", function()
    assert(bash.getGitFolderRoot(), "fatal: not a git repository (or any of the parent directories): .git")
    Handlers.load_ignore_patterns()

    local index = Handlers.read_index()
    local headSha = Handlers.get_ref("HEAD")
    local current_branch = Handlers.get_current_branch()
    local last_index = read_last_index()

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
    table.sort(staged_new)
    table.sort(staged_modified)
    table.sort(staged_deleted)

    if current_branch then
        print("On branch " .. current_branch)

        local upstream = Handlers.get_ref("refs/remotes/origin/" .. current_branch)
        if upstream and headSha and headSha ~= "" and Handlers.read_commit(upstream) then
            local ahead, behind = count_ahead_behind(headSha, upstream)
            local name = "origin/" .. current_branch
            if ahead > 0 and behind > 0 then
                print(string.format("Your branch and '%s' have diverged,\nand have %d and %d different commits each, respectively.", name, ahead, behind))
            elseif ahead > 0 then
                print(string.format("Your branch is ahead of '%s' by %d commit%s.", name, ahead, ahead == 1 and "" or "s"))
            elseif behind > 0 then
                print(string.format("Your branch is behind '%s' by %d commit%s, and can be fast-forwarded.", name, behind, behind == 1 and "" or "s"))
            else
                print(string.format("Your branch is up to date with '%s'.", name))
            end
        end
    else
        print("HEAD detached at " .. string.sub(headSha or "", 1, 7))
    end

    if not headSha or headSha == "" then
        print("\nNo commits yet\n")
    end

    local unstaged_modified, unstaged_deleted = collect_worktree_changes(index)
    local has_unstaged = #unstaged_modified + #unstaged_deleted > 0

    local has_staged = #staged_new + #staged_modified + #staged_deleted > 0
    if has_staged then
        print("Changes to be committed:")
        for _, path in ipairs(staged_new) do
            print("\t\27[32mnew file:   " .. path .. "\27[0m")
        end
        for _, path in ipairs(staged_modified) do
            print("\t\27[32mmodified:   " .. path .. "\27[0m")
        end
        for _, path in ipairs(staged_deleted) do
            print("\t\27[32mdeleted:    " .. path .. "\27[0m")
        end
    end

    if has_unstaged then
        print("Changes not staged for commit:")
        for _, path in ipairs(unstaged_modified) do
            print("\t\27[31mmodified:   " .. path .. "\27[0m")
        end
        for _, path in ipairs(unstaged_deleted) do
            print("\t\27[31mdeleted:    " .. path .. "\27[0m")
        end
    end

    local untracked = {}
    for path in pairs(collect_untracked(index)) do
        table.insert(untracked, path)
    end
    table.sort(untracked)
    if #untracked > 0 then
        print("Untracked files:")
        local limit = 50
        for i, path in ipairs(untracked) do
            if i > limit then
                print(string.format("\t... and %d more", #untracked - limit))
                break
            end
            print("\t\27[31m" .. path .. "\27[0m")
        end
        print("(use \"git add .\" to track them)")
    end

    if not has_staged and not has_unstaged then
        print(#untracked > 0 and "nothing added to commit but untracked files present" or "nothing to commit, working tree clean")
    end
end)

--[[
Parses the committer timestamp of a commit object.
]]
local function commit_time(commit)
    local line = commit.committer or commit.author or ""
    return tonumber(line:match("(%d+) [+-]%d+$")) or 0
end

--[[
Builds a map of sha -> list of decorations ("HEAD -> main", "origin/main", "tag: v1") for log output.
]]
local function collect_decorations()
    local decorations = {}
    local head_sha = Handlers.get_ref("HEAD")
    local current_branch = Handlers.get_current_branch()

    local function add(sha, text)
        decorations[sha] = decorations[sha] or {}
        table.insert(decorations[sha], text)
    end

    if head_sha and head_sha ~= "" then
        add(head_sha, current_branch and ("HEAD -> " .. current_branch) or "HEAD")
    end

    local names = {}
    for refName, sha in pairs(Handlers.list_refs()) do
        table.insert(names, {name = refName, sha = sha})
    end
    table.sort(names, function(x, y) return x.name < y.name end)

    for _, ref in ipairs(names) do
        local branch = ref.name:match("^refs/heads/(.+)$")
        local remote = ref.name:match("^refs/remotes/(.+)$")
        local tag = ref.name:match("^refs/tags/(.+)$")
        if branch and branch ~= current_branch then
            add(ref.sha, branch)
        elseif remote and not remote:match("/HEAD$") then
            add(ref.sha, remote)
        elseif tag then
            --// annotated tags point at the tag object, show them on the commit
            local obj = Handlers.read_object(ref.sha)
            local target = ref.sha
            if obj and obj.type == "tag" then
                target = obj.content:match("^object (%x+)") or ref.sha
            end
            add(target, "tag: " .. tag)
        end
    end

    return decorations
end

--[[
Walks the history reachable from `start_sha`, newest first (by commit time).
Calls `visit(sha, commit)` for every commit, return false from it to stop.
]]
local function walk_history(start_sha, visit)
    local frontier = {start_sha}
    local seen = {[start_sha] = true}
    local times = {}

    while #frontier > 0 do
        local best = 1
        for i = 1, #frontier do
            local sha = frontier[i]
            if not times[sha] then
                local commit = Handlers.read_commit(sha)
                times[sha] = commit and commit_time(commit) or 0
            end
            if times[sha] > times[frontier[best]] then
                best = i
            end
        end

        local sha = table.remove(frontier, best)
        local commit = Handlers.read_commit(sha)
        if not commit then return end

        if visit(sha, commit) == false then return end

        for _, parent in ipairs(commit.parents) do
            if not seen[parent] then
                seen[parent] = true
                table.insert(frontier, parent)
            end
        end
        Utilities.roYield()
    end
end

local function print_commit_header(sha, commit, decoration_list)
    local decoration = (decoration_list and #decoration_list > 0) and (" (" .. table.concat(decoration_list, ", ") .. ")") or ""
    print("\27[33mcommit " .. sha .. "\27[0m" .. decoration)
    if #commit.parents > 1 then
        local short = {}
        for _, parent in ipairs(commit.parents) do table.insert(short, parent:sub(1, 7)) end
        print("Merge: " .. table.concat(short, " "))
    end

    local author_line = commit.author or ""
    local who, time, tz = author_line:match("^(.-) (%d+) ([+%-]%d+)$")
    if who then
        print("Author: " .. who)
        print("Date:   " .. os.date("%a %b %d %H:%M:%S %Y", tonumber(time)) .. " " .. tz)
    else
        print("Author: " .. author_line)
    end
end

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
    local rev = nil

    local i = 1
    while i <= #tuple do
        local arg = tuple[i]
        if arg == "--oneline" then
            oneline = true
        elseif (arg == "-n" or arg == "--max-count") and tuple[i + 1] then
            max_count = tonumber(tuple[i + 1])
            i += 1
        elseif arg:match("^%-%-max%-count=(%d+)$") then
            max_count = tonumber(arg:match("^%-%-max%-count=(%d+)$"))
        elseif arg:match("^%-(%d+)$") then
            max_count = tonumber(arg:match("^%-(%d+)$"))
        elseif arg:sub(1, 1) ~= "-" then
            rev = arg
        end
        i += 1
    end

    local sha
    if rev then
        sha = Handlers.resolve_revision(rev)
        if not sha then
            error("fatal: ambiguous argument '" .. rev .. "': unknown revision or path not in the working tree.")
            return
        end
    else
        sha = Handlers.get_ref("HEAD")
        if not sha or sha == "" then
            error("fatal: your current branch '" .. (Handlers.get_current_branch() or "master") .. "' does not have any commits yet")
            return
        end
    end

    local decorations = collect_decorations()
    local count = 0

    walk_history(sha, function(commit_sha, commit)
        if max_count and count >= max_count then return false end

        local msg = commit.message:gsub("\n+$", "")
        if oneline then
            local decoration = decorations[commit_sha] and (" (" .. table.concat(decorations[commit_sha], ", ") .. ")") or ""
            print(commit_sha:sub(1, 7) .. decoration .. " " .. (msg:match("^[^\n]*") or msg))
        else
            print_commit_header(commit_sha, commit, decorations[commit_sha])
            print("")
            for line in (msg .. "\n"):gmatch("([^\n]*)\n") do
                print("    " .. line)
            end
            print("")
        end

        count += 1
        return true
    end)
end)

--[[
commands:
show

Shows one commit (HEAD by default): its message and which instances changed.
]]
arguments.createArgument("git", "show", "", function(...)
    assert(bash.getGitFolderRoot(), "fatal: not a git repository (or any of the parent directories): .git")

    local rev = nil
    local names_only = false
    for _, arg in ipairs({...}) do
        if arg == "--name-only" or arg == "--stat" or arg == "--name-status" then
            names_only = true
        elseif arg:sub(1, 1) ~= "-" then
            rev = arg
        end
    end

    local sha = Handlers.resolve_revision(rev or "HEAD")
    local commit = sha and Handlers.read_commit(sha)
    if not commit then
        error("fatal: ambiguous argument '" .. tostring(rev or "HEAD") .. "': unknown revision or path not in the working tree.")
        return
    end

    print_commit_header(sha, commit, collect_decorations()[sha])
    print("")
    for line in (commit.message:gsub("\n+$", "") .. "\n"):gmatch("([^\n]*)\n") do
        print("    " .. line)
    end
    print("")

    local parent = commit.parents[1] and Handlers.read_commit(commit.parents[1])
    local old_index = parent and Handlers.tree_to_index(parent.tree) or {}
    local new_index = Handlers.tree_to_index(commit.tree)

    local paths, seen = {}, {}
    for path in pairs(old_index) do seen[path] = true; table.insert(paths, path) end
    for path in pairs(new_index) do if not seen[path] then table.insert(paths, path) end end
    table.sort(paths)

    local colors = {A = "\27[32m", M = "\27[33m", D = "\27[31m"}
    for _, path in ipairs(paths) do
        local old, new = old_index[path], new_index[path]
        if not old or not new or old.sha ~= new.sha then
            local status = (not old and "A") or (not new and "D") or "M"
            print(colors[status] .. status .. "\27[0m  " .. path)
            if status == "M" and not names_only then
                for _, line in ipairs(diff.describe(read_blob_content(old.sha), read_blob_content(new.sha))) do
                    print(line)
                end
            end
        end
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

    local tuple = {...}
    local mode = "list"
    local show_remotes, only_remotes, verbose, force = false, false, false, false
    local positional = {}

    for _, arg in ipairs(tuple) do
        if arg == "-a" or arg == "--all" then
            show_remotes = true
        elseif arg == "-r" or arg == "--remotes" then
            show_remotes, only_remotes = true, true
        elseif arg == "-v" or arg == "-vv" or arg == "--verbose" then
            verbose = true
        elseif arg == "-d" or arg == "--delete" then
            mode = "delete"
        elseif arg == "-D" then
            mode, force = "delete", true
        elseif arg == "-m" or arg == "--move" or arg == "-M" then
            mode = "move"
        elseif arg == "--show-current" then
            mode = "current"
        elseif arg == "-f" or arg == "--force" then
            force = true
        elseif arg:sub(1, 1) ~= "-" then
            table.insert(positional, arg)
        end
    end

    local current_branch = Handlers.get_current_branch()

    if mode == "current" then
        if current_branch then print(current_branch) end
        return
    end

    if mode == "list" and #positional == 0 then
        local entries = {}
        if not only_remotes then
            for _, name in ipairs(Handlers.get_branches()) do
                table.insert(entries, {name = name, display = name, sha = Handlers.get_ref("refs/heads/" .. name), is_current = name == current_branch})
            end
        end
        if show_remotes then
            for refName, sha in pairs(Handlers.list_refs()) do
                local remote = refName:match("^refs/remotes/(.+)$")
                if remote and not remote:match("/HEAD$") then
                    table.insert(entries, {name = "remotes/" .. remote, display = "\27[31mremotes/" .. remote .. "\27[0m", sha = sha})
                end
            end
        end
        table.sort(entries, function(x, y) return x.name < y.name end)

        for _, entry in ipairs(entries) do
            local line = (entry.is_current and "* " or "  ") .. (entry.is_current and ("\27[32m" .. entry.display .. "\27[0m") or entry.display)
            if verbose and entry.sha then
                local commit = Handlers.read_commit(entry.sha)
                line = line .. " " .. entry.sha:sub(1, 7) .. " " .. (commit and commit.message:match("^[^\n]*") or "")
            end
            print(line)
        end

        if #entries == 0 and current_branch then
            print("* " .. current_branch)
        end
        return
    end

    if mode == "delete" then
        assert(#positional > 0, "fatal: branch name required")
        for _, branch in ipairs(positional) do
            if current_branch == branch then
                print("error: Cannot delete branch '" .. branch .. "' checked out at '" .. bash.getGitFolderRoot().Parent:GetFullName() .. "'")
            else
                local sha = Handlers.get_ref("refs/heads/" .. branch)
                if not sha then
                    print("error: branch '" .. branch .. "' not found.")
                else
                    local head_sha = Handlers.get_ref("HEAD")
                    if not force and head_sha and not is_ancestor_commit(sha, head_sha) then
                        print("error: The branch '" .. branch .. "' is not fully merged.")
                        print("If you are sure you want to delete it, run 'git branch -D " .. branch .. "'")
                    else
                        Handlers.delete_ref("refs/heads/" .. branch)
                        print("Deleted branch " .. branch .. " (was " .. sha:sub(1, 7) .. ").")
                    end
                end
            end
        end
        return
    end

    if mode == "move" then
        local old_branch, new_branch = positional[1], positional[2]
        if not new_branch then
            new_branch = old_branch
            old_branch = current_branch
        end
        assert(old_branch and new_branch, "usage: git branch -m [<old>] <new>")
        assert(is_valid_branch_name(new_branch), "fatal: '" .. new_branch .. "' is not a valid branch name.")

        local sha = Handlers.get_ref("refs/heads/" .. old_branch)
        assert(sha, "error: refname refs/heads/" .. old_branch .. " not found")
        assert(force or old_branch == new_branch or not Handlers.get_ref("refs/heads/" .. new_branch), "fatal: a branch named '" .. new_branch .. "' already exists")

        if old_branch ~= new_branch then
            Handlers.update_ref("refs/heads/" .. new_branch, sha)
            Handlers.delete_ref("refs/heads/" .. old_branch)
            if current_branch == old_branch then
                bash.modifyFileContents(bash.getGitFolderRoot(), "HEAD", "ref: refs/heads/" .. new_branch)
            end
        end
        return
    end

    local branch_name = positional[1]
    assert(is_valid_branch_name(branch_name), "fatal: '" .. tostring(branch_name) .. "' is not a valid branch name.")
    assert(force or not Handlers.get_ref("refs/heads/" .. branch_name), "fatal: a branch named '" .. branch_name .. "' already exists")

    local start_point = positional[2]
    local sha = Handlers.resolve_revision(start_point or "HEAD")
    if not sha or sha == "" then
        if not start_point then
            error("fatal: cannot create branch '" .. branch_name .. "' because there are no commits yet")
            print("hint: create your first commit, then run 'git branch " .. branch_name .. "'")
            return
        end
        error("fatal: Not a valid object name: '" .. start_point .. "'.")
        return
    end

    Handlers.update_ref("refs/heads/" .. branch_name, sha)
    print("Created branch '" .. branch_name .. "'")
end)

--[[
commands:
tag

create, list or delete tags
]]
arguments.createArgument("git", "tag", "", function(...)
    assert(bash.getGitFolderRoot(), "fatal: not a git repository (or any of the parent directories): .git")

    local tuple = {...}
    local annotated, delete, list = false, false, false
    local message = nil
    local force = false
    local positional = {}

    local i = 1
    while i <= #tuple do
        local arg = tuple[i]
        if arg == "-a" or arg == "--annotate" then
            annotated = true
        elseif arg == "-d" or arg == "--delete" then
            delete = true
        elseif arg == "-l" or arg == "--list" then
            list = true
        elseif arg == "-f" or arg == "--force" then
            force = true
        elseif (arg == "-m" or arg == "--message") and tuple[i + 1] then
            message = tuple[i + 1]
            annotated = true
            i += 1
        elseif arg:sub(1, 1) ~= "-" then
            table.insert(positional, arg)
        end
        i += 1
    end

    if list or (#positional == 0 and not delete) then
        local pattern = positional[1]
        local names = {}
        for refName in pairs(Handlers.list_refs()) do
            local tag = refName:match("^refs/tags/(.+)$")
            if tag and not tag:match("%^{}$") then
                if not pattern then
                    table.insert(names, tag)
                else
                    local lua_pattern = "^" .. pattern:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"):gsub("%*", ".*") .. "$"
                    if tag:match(lua_pattern) then table.insert(names, tag) end
                end
            end
        end
        table.sort(names)
        for _, tag in ipairs(names) do print(tag) end
        return
    end

    if delete then
        assert(#positional > 0, "fatal: tag name required")
        for _, tag in ipairs(positional) do
            local sha = Handlers.get_ref("refs/tags/" .. tag)
            if sha and Handlers.delete_ref("refs/tags/" .. tag) then
                print("Deleted tag '" .. tag .. "' (was " .. sha:sub(1, 7) .. ")")
            else
                print("error: tag '" .. tag .. "' not found.")
            end
        end
        return
    end

    local name = positional[1]
    assert(is_valid_branch_name(name), "fatal: '" .. tostring(name) .. "' is not a valid tag name.")
    assert(force or not Handlers.get_ref("refs/tags/" .. name), "fatal: tag '" .. name .. "' already exists")

    local target = Handlers.resolve_revision(positional[2] or "HEAD")
    if not target then
        error("fatal: Failed to resolve '" .. (positional[2] or "HEAD") .. "' as a valid ref.")
        return
    end

    local ref_sha = target
    if annotated then
        local tag_message = message or "Tag " .. name
        local content = string.format("object %s\ntype commit\ntag %s\ntagger %s\n\n%s\n", target, name, make_signature(), tag_message)
        ref_sha = Handlers.write_object("tag", content)
    end
    Handlers.update_ref("refs/tags/" .. name, ref_sha)
end)

--[[
Moves HEAD/the working tree to `target_sha`. `branch` is the branch to attach HEAD to (nil = detached).
Downloads the commit first if we only know it from the remote.
]]
local function switch_to(target_sha, branch, create)
    local commit = Handlers.read_commit(target_sha)
    if not commit then
        print("Branch data not found locally. Fetching from origin...")
        local ok = pcall(Remote.fetch, "origin", true)
        commit = ok and Handlers.read_commit(target_sha)
    end
    assert(commit and commit.tree, "fatal: unable to read commit " .. target_sha .. " (try 'git fetch')")

    local current_sha = Handlers.get_ref("HEAD")
    if target_sha ~= current_sha then
        local dirty = dirty_changes()
        if #dirty > 0 then
            print_dirty_abort(dirty, "checkout")
            return false
        end
    end

    if create then
        Handlers.update_ref("refs/heads/" .. branch, target_sha)
    end
    bash.modifyFileContents(bash.getGitFolderRoot(), "HEAD", branch and ("ref: refs/heads/" .. branch) or target_sha)

    if target_sha ~= current_sha then
        print("Checking out files: 100% done.")
        local ok, err = Remote.checkout(commit.tree)
        assert(ok, err)
    end
    return true
end

--[[
commands:
switch

switch branches in repository
]]
arguments.createArgument("git", "switch", "", function(...)
    assert(bash.getGitFolderRoot(), "fatal: not a git repository (or any of the parent directories): .git")

    local tuple = {...}
    local create_branch, detach, force_create = false, false, false
    local positional = {}
    for _, arg in ipairs(tuple) do
        if arg == "-c" or arg == "--create" then
            create_branch = true
        elseif arg == "-C" then
            create_branch, force_create = true, true
        elseif arg == "-d" or arg == "--detach" then
            detach = true
        elseif arg:sub(1, 1) ~= "-" or arg == "-" then
            table.insert(positional, arg)
        end
    end

    local name = positional[1]
    if not name or name == "" then
        error("fatal: missing branch or commit argument")
        print("usage: git switch [-c | --create] <branch> [<start-point>]")
        return
    end

    local current_branch = Handlers.get_current_branch()

    if detach then
        local sha = Handlers.resolve_revision(name)
        assert(sha, "fatal: invalid reference: " .. name)
        if switch_to(sha, nil, false) then
            print("HEAD is now at " .. sha:sub(1, 7) .. " (detached)")
        end
        return
    end

    assert(is_valid_branch_name(name), "fatal: invalid reference: " .. tostring(name))

    if create_branch then
        assert(force_create or not Handlers.get_ref("refs/heads/" .. name), "fatal: a branch named '" .. name .. "' already exists")
        local start_sha = Handlers.resolve_revision(positional[2] or "HEAD")
        assert(start_sha and start_sha ~= "", positional[2] and ("fatal: invalid reference: " .. positional[2]) or "fatal: you are on a branch with no commits yet")
        if switch_to(start_sha, name, true) then
            print("Switched to a new branch '" .. name .. "'")
        end
        return
    end

    if current_branch == name then
        print("Already on '" .. name .. "'")
        return
    end

    local target_sha = Handlers.get_ref("refs/heads/" .. name)
    local created_tracking = false
    if not target_sha or target_sha == "" then
        --// like git: `git switch feature` creates a local branch that tracks origin/feature
        for _, remote_ref in ipairs({"origin/" .. name}) do
            local remote_sha = Handlers.get_ref("refs/remotes/" .. remote_ref)
            if remote_sha and remote_sha ~= "" then
                target_sha = remote_sha
                created_tracking = true
            end
        end
    end
    assert(target_sha and target_sha ~= "", "fatal: invalid reference: " .. name)

    if switch_to(target_sha, name, created_tracking) then
        if created_tracking then
            print("branch '" .. name .. "' set up to track 'origin/" .. name .. "'.")
        end
        print("Switched to branch '" .. name .. "'")
    end
end)

--[[
commands:
checkout
ck

checkout branch or files
]]
arguments.createArgument("git", "checkout", "ck", function(...)
    local tuple = {...}
    if #tuple == 0 then
        error("fatal: you must specify a branch or path to checkout")
        return
    end

    local first = tuple[1]

    if first == "-b" or first == "-B" then
        local branch = tuple[2]
        if not branch then
            error("fatal: branch name required for -b")
            return
        end
        arguments.execute("git", "switch", first == "-b" and "-c" or "-C", table.unpack(tuple, 2))
        return
    end

    if first == "--detach" or first == "-d" then
        arguments.execute("git", "switch", "--detach", table.unpack(tuple, 2))
        return
    end

    if first == "--" then
        arguments.execute("git", "restore", table.unpack(tuple, 2))
        return
    end

    local root = bash.getGitFolderRoot()
    if not root then
        error("fatal: not a git repository")
        return
    end

    if Handlers.get_ref("refs/heads/" .. first) or Handlers.get_ref("refs/remotes/origin/" .. first) then
        arguments.execute("git", "switch", first)
        return
    end

    --// A tag, commit hash or remote branch: detach HEAD there (unless it's really a path to an instance)
    if not Utilities.parse_path(first) and Handlers.resolve_revision(first) then
        arguments.execute("git", "switch", "--detach", first)
        return
    end

    arguments.execute("git", "restore", table.unpack(tuple))
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
        local is_commit = Handlers.resolve_revision(first) ~= nil and not Utilities.parse_path(first)
        
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

    local target_sha = Handlers.resolve_revision(commit_target)
    if not target_sha or target_sha == "" then
        error("fatal: ambiguous argument '" .. commit_target .. "': unknown revision or path not in the working tree.")
        return
    end

    local target_commit = Handlers.read_commit(target_sha)
    if not target_commit or not target_commit.tree then
        error("fatal: Could not parse object '" .. commit_target .. "'.")
        return
    end

    local current_branch = Handlers.get_current_branch()
    if current_branch then
        Handlers.update_ref("refs/heads/" .. current_branch, target_sha)
    else
        bash.modifyFileContents(bash.getGitFolderRoot(), "HEAD", target_sha)
    end

    if mode == "--hard" then
        --// discards everything: instances are rebuilt from the target tree
        local ok, err = Remote.checkout(target_commit.tree)
        assert(ok, err)
        print("HEAD is now at " .. target_sha:sub(1, 7) .. " " .. (target_commit.message:match("^[^\n]*") or ""))
        return
    end

    --// --soft keeps the index (so the undone changes show up as staged), --mixed resets it as well
    local new_index = Handlers.tree_to_index(target_commit.tree)
    if mode == "--mixed" then
        Handlers.write_index(new_index)
    end
    bash.writeFile(bash.getGitFolderRoot(), "last_commit_index", HttpService:JSONEncode(new_index))

    if mode == "--mixed" then
        local unstaged = {}
        for _, change in ipairs(git.get_changes()) do
            if change.status ~= "U" then
                table.insert(unstaged, change.status .. "\t" .. change.path)
            end
        end
        if #unstaged > 0 then
            print("Unstaged changes after reset:")
            for _, line in ipairs(unstaged) do print(line) end
        end
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
