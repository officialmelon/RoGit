--[[
Repository helpers shared by every command module: worktree scanning, commits, config,
and the state of operations that can stop half way (merge, cherry-pick, revert, rebase).
]]
local repo = {}

local HttpService = game:GetService("HttpService")

local bash = require(script.Parent.Parent.bash)
local Handlers = require(script.Parent.git_handlers)
local instances = require(script.Parent.instances)
local Utilities = require(script.Parent.utilities)
local Auth = require(script.Parent.localstore)
local Remote = require(script.Parent.git_remote)
local merge = require(script.Parent.merge)
local ini_parser = require(script.Parent.ini_parser)
local output = require(script.Parent.output)

local ROGIT_ID = "_rogit_id"
repo.ZERO_SHA = ("0"):rep(40)

local function print(...)
    output.print(...)
end

--[[
Fails unless the place has a repository.
]]
function repo.require_root()
    local root = bash.getGitFolderRoot()
    if not root then
        error("fatal: not a git repository (or any of the parent directories): .git", 0)
    end
    return root
end

--// ------------------------------------------------------------------ files inside .git

--[[
Reads a file inside .git ("MERGE_HEAD", "logs/refs/heads/main"...). nil when it doesn't exist.
]]
function repo.read_file(path)
    local root = bash.getGitFolderRoot()
    if not root then return nil end
    local file = bash.getDirectoryOrFile(root, path)
    if not file then return nil end
    return bash.getFileContents(file.Parent, file.Name)
end

function repo.write_file(path, content)
    local root = repo.require_root()
    local segments = string.split(path, "/")
    local name = table.remove(segments)
    local folder = #segments > 0 and bash.createFolder(root, table.concat(segments, "/")) or root
    return bash.writeFile(folder, name, content)
end

function repo.delete_file(path)
    local root = bash.getGitFolderRoot()
    local file = root and bash.getDirectoryOrFile(root, path)
    if file then file:Destroy() end
end

--// ------------------------------------------------------------------ config

function repo.read_config()
    local root = repo.require_root()
    return ini_parser.parseIni(bash.getFileContents(root, "config") or "")
end

function repo.write_config(conf)
    local root = repo.require_root()
    bash.writeFile(root, "config", ini_parser.serializeIni(conf))
end

--[[
Splits "branch.main.remote" into the ini section ('branch "main"') and the key ("remote").
]]
function repo.config_section(key)
    local first, middle, last = key:match("^([^.]+)%.(.+)%.([^.]+)$")
    if first then
        return first .. ' "' .. middle .. '"', last
    end
    local section, name = key:match("^([^.]+)%.([^.]+)$")
    return section, name
end

--[[
Reads a config value: the repository's config first, then the plugin (global) settings.
]]
function repo.get_config(key)
    local root = bash.getGitFolderRoot()
    if root then
        local section, name = repo.config_section(key)
        local conf = repo.read_config()
        if section and conf[section] and conf[section][name] ~= nil then
            return conf[section][name]
        end
    end
    return Auth.getConfigValue((key:gsub("%.", "_"))) or Auth.getConfigValue(key)
end

--[[
The remote and remote branch a local branch tracks (falls back to origin/<branch>).
Returns remote name, branch name on the remote, and whether it was configured explicitly.
]]
function repo.get_upstream(branch)
    if not branch then return nil end
    local conf = repo.read_config()
    local section = conf['branch "' .. branch .. '"']
    if section and section.remote and section.merge then
        return section.remote, (section.merge:gsub("^refs/heads/", "")), true
    end
    return "origin", branch, false
end

function repo.set_upstream(branch, remote, remote_branch)
    local conf = repo.read_config()
    conf['branch "' .. branch .. '"'] = {
        remote = remote,
        merge = "refs/heads/" .. remote_branch,
    }
    repo.write_config(conf)
end

function repo.default_branch()
    return repo.get_config("init.defaultBranch") or "master"
end

--// ------------------------------------------------------------------ commits

--[[
Builds the "Name <email> <time> <tz>" signature used for commits and tags.
]]
function repo.make_signature()
    local user_name = Auth.getConfigValue("user_name") or Auth.getConfigValue("user.name") or "roGit"
    local user_email = Auth.getConfigValue("user_email") or Auth.getConfigValue("user.email") or "ro-git@example.com"
    return string.format("%s <%s> %d +0000", user_name, user_email, os.time())
end

--[[
Writes a commit object without moving any ref. Returns its sha.
]]
function repo.write_commit_object(tree_sha, parents, message, author)
    local lines = {"tree " .. tree_sha}
    for _, parent in ipairs(parents) do
        table.insert(lines, "parent " .. parent)
    end
    local signature = repo.make_signature()
    table.insert(lines, "author " .. (author or signature))
    table.insert(lines, "committer " .. signature)
    if message:sub(-1) ~= "\n" then
        message ..= "\n"
    end
    return Handlers.write_object("commit", table.concat(lines, "\n") .. "\n\n" .. message)
end

--[[
Writes a commit object and moves HEAD (and the branch it points at) to it.
opts.author keeps the original author (cherry-pick/rebase), opts.reflog is the reflog message.
]]
function repo.create_commit(tree_sha, parents, message, opts)
    opts = opts or {}
    local lines = {"tree " .. tree_sha}
    for _, parent in ipairs(parents) do
        table.insert(lines, "parent " .. parent)
    end
    local signature = repo.make_signature()
    table.insert(lines, "author " .. (opts.author or signature))
    table.insert(lines, "committer " .. signature)

    if message:sub(-1) ~= "\n" then
        message ..= "\n"
    end

    local sha = Handlers.write_object("commit", table.concat(lines, "\n") .. "\n\n" .. message)
    local subject = message:match("^[^\n]*")
    Handlers.update_ref("HEAD", sha, (opts.reflog or (#parents == 0 and "commit (initial)" or "commit")) .. ": " .. subject)
    return sha
end

--[[
Is ancestor a commit of descendant?
]]
function repo.is_ancestor(ancestor_sha, descendant_sha)
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
            local commit = Handlers.read_commit(sha)
            if commit then
                for _, parent in ipairs(commit.parents) do
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

function repo.head_sha()
    local sha = Handlers.get_ref("HEAD")
    if sha == "" then return nil end
    return sha
end

function repo.head_tree()
    local commit = Handlers.read_commit(repo.head_sha())
    return commit and commit.tree or nil
end

--// Trees never change, so their flattened form is remembered.
local tree_index_cache = {}

--[[
Flattens a tree into an index (copied, safe to modify). Empty for nil.
]]
function repo.tree_index(tree_sha)
    if not tree_sha then return {} end
    local cached = tree_index_cache[tree_sha]
    if not cached then
        cached = Handlers.tree_to_index(tree_sha)
        tree_index_cache[tree_sha] = cached
    end
    local copy = {}
    for path, data in pairs(cached) do
        copy[path] = {sha = data.sha, mode = data.mode}
    end
    return copy
end

--[[
The index as of HEAD (what "staged" changes are compared against).
]]
function repo.read_last_index()
    return repo.tree_index(repo.head_tree())
end

function repo.read_blob_content(sha)
    local obj = sha and Handlers.read_object(sha)
    return obj and obj.type == "blob" and obj.content or nil
end

--// ------------------------------------------------------------------ paths

--[[
Turns a user supplied path (Workspace/Part, game.Workspace.Part) into an index style path.
]]
function repo.normalize_user_path(path)
    path = path:gsub("^game[./]", "")
    if not path:find("/", 1, true) then
        path = path:gsub("%.", "/")
    end
    return (path:gsub("/+$", ""))
end

function repo.entity_of(path)
    return path:match("^(.-)/%.properties$") or path
end

function repo.matches_filters(path, filters)
    if not filters or #filters == 0 then return true end
    local entity = repo.entity_of(path)
    for _, filter in ipairs(filters) do
        if filter == "." or entity == filter or entity:sub(1, #filter + 1) == filter .. "/" then
            return true
        end
    end
    return false
end

--// ------------------------------------------------------------------ worktree scanning

--[[
Compares the live instances against an index. Returns sorted lists of modified and deleted paths.
]]
function repo.collect_worktree_changes(index)
    local modified = {}
    local deleted = {}

    for path, data in pairs(index) do
        Utilities.roYield()
        local currObj = Utilities.parse_path(repo.entity_of(path))

        if not currObj then
            table.insert(deleted, path)
        else
            local serialized = instances.serialize_instance(currObj)
            if Handlers.blob_sha(serialized) ~= data.sha then
                table.insert(modified, path)
            end
        end
    end

    table.sort(modified)
    table.sort(deleted)
    return modified, deleted
end

--[[
Returns the children of an instance that roGit tracks (ignores .rogitignore'd instances and the .git folder),
in the same deterministic order used when staging. Duplicate names get a stable id so they can be told apart.
]]
function repo.tracked_children(parent, seen_ids)
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
Finds every tracked instance that is not part of the index yet. Returns {virtual path = instance}.
]]
function repo.collect_untracked(index)
    local untracked = {}
    local seen_ids = {}

    local function traverse(children, counts, path_prefix)
        local seen_local = {}

        for _, child in ipairs(children) do
            Utilities.roYield()
            local virtualName = Utilities.escape_name(child.Name)
            if counts[child.Name] > 1 then
                seen_local[child.Name] = (seen_local[child.Name] or 0) + 1
                virtualName = virtualName .. " [" .. tostring(seen_local[child.Name]) .. "]"
            end

            local my_path = path_prefix == "" and virtualName or (path_prefix .. "/" .. virtualName)
            local grandchildren, grandCounts = repo.tracked_children(child, seen_ids)

            local index_path = #grandchildren > 0 and (my_path .. "/.properties") or my_path
            if not index[index_path] and not index[my_path] then
                untracked[my_path] = child
            end

            traverse(grandchildren, grandCounts, my_path)
        end
    end

    for _, service in ipairs(bash.trackingRoot) do
        local children, counts = repo.tracked_children(service, seen_ids)
        traverse(children, counts, service.Name)
    end

    return untracked
end

--[[
Stages the whole place into a fresh index table (what `git add .` would produce).
]]
function repo.snapshot_worktree()
    Handlers.load_ignore_patterns()
    local index = {}
    local seen_ids = {}
    for _, service in ipairs(bash.trackingRoot) do
        if not Handlers.is_ignored(service:GetFullName()) then
            instances.stage_recursive(service, index, seen_ids)
        end
    end
    return index
end

--[[
Every change in the working tree and index, {path, status = A/M/D/U}. Used by the GUI and to refuse unsafe operations.
]]
function repo.get_changes()
    Handlers.load_ignore_patterns()
    local index = Handlers.read_index()
    local last_index = repo.read_last_index()

    local changes = {}
    local seen_paths = {}

    --// STAGED (Compared to last commit)
    for path, data in pairs(index) do
        if not last_index[path] then
            table.insert(changes, {path = path, status = "A", staged = true})
            seen_paths[path] = true
        elseif last_index[path].sha ~= data.sha then
            table.insert(changes, {path = path, status = "M", staged = true})
            seen_paths[path] = true
        end
    end
    for path, _ in pairs(last_index) do
        if not index[path] then
            table.insert(changes, {path = path, status = "D", staged = true})
            seen_paths[path] = true
        end
    end

    --// UNSTAGED (Compared to index)
    local unstaged_modified, unstaged_deleted = repo.collect_worktree_changes(index)
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
    for path in pairs(repo.collect_untracked(index)) do
        if not seen_paths[path] then
            table.insert(changes, {path = path, status = "U"})
        end
    end

    --// unresolved conflicts show up as "C" (and win over anything else for that path)
    local conflicted = {}
    for _, conflict in ipairs(repo.read_conflicts()) do
        conflicted[conflict.path] = true
    end
    if next(conflicted) then
        local filtered = {}
        for _, change in ipairs(changes) do
            if not conflicted[repo.entity_of(change.path)] then table.insert(filtered, change) end
        end
        for path in pairs(conflicted) do
            table.insert(filtered, {path = path, status = "C"})
        end
        changes = filtered
    end

    table.sort(changes, function(a, b)
        return a.path < b.path
    end)
    return changes
end

--[[
Changes to tracked instances (untracked ones are ignored, they can't be overwritten).
]]
function repo.dirty_changes()
    local dirty = {}
    for _, change in ipairs(repo.get_changes()) do
        if change.status ~= "U" then
            table.insert(dirty, change.path)
        end
    end
    return dirty
end

--[[
Refuses to continue while tracked instances have uncommitted changes.
]]
function repo.ensure_clean(action)
    local dirty = repo.dirty_changes()
    if #dirty == 0 then return end

    local lines = {"error: Your local changes to the following files would be overwritten by " .. action .. ":"}
    for _, path in ipairs(dirty) do
        table.insert(lines, "\t" .. path)
    end
    table.insert(lines, "Please commit your changes or stash them before you " .. action .. ".")
    table.insert(lines, "Aborting")
    error(table.concat(lines, "\n"), 0)
end

--// ------------------------------------------------------------------ applying trees

--[[
Moves the working tree, index (and with it the staged state) to `tree_sha`.
]]
function repo.checkout_tree(tree_sha)
    local ok, err = Remote.checkout(tree_sha)
    if not ok then
        error("fatal: " .. tostring(err), 0)
    end
end

--[[
Writes ORIG_HEAD like git does before operations that move HEAD a long way.
]]
function repo.save_orig_head()
    local head = repo.head_sha()
    if head then
        repo.write_file("ORIG_HEAD", head)
    end
end

--[[
Makes the instances under `filters` match `source` (an index), creating, updating and destroying as needed.
`known` is the index of what is currently tracked: tracked instances missing from `source` are destroyed.
Untracked instances are never touched. Returns the number of entries that matched.
]]
function repo.restore_worktree(source, known, filters)
    local entities = {}
    for path, data in pairs(source) do
        if repo.matches_filters(path, filters) then
            entities[repo.entity_of(path)] = data
        end
    end
    local doomed = {}
    for path in pairs(known) do
        local entity = repo.entity_of(path)
        if repo.matches_filters(path, filters) and not entities[entity] then
            table.insert(doomed, entity)
        end
    end

    local ordered = {}
    local matched = 0
    for entity in pairs(entities) do
        table.insert(ordered, entity)
        matched += 1
    end
    table.sort(ordered, function(a, b)
        local da, db = select(2, a:gsub("/", "")), select(2, b:gsub("/", ""))
        if da ~= db then return da < db end
        return a < b
    end)

    for _, entity in ipairs(ordered) do
        Utilities.roYield()
        local content = repo.read_blob_content(entities[entity].sha)
        local ok, props = pcall(function() return HttpService:JSONDecode(content) end)
        if ok and type(props) == "table" then
            local target = Utilities.parse_path(entity)
            if target then
                Remote.applyProperties(target, props)
            else
                local parentPath, name = entity:match("^(.*)/([^/]+)$")
                local parent = parentPath and Utilities.parse_path(parentPath)
                if parent then
                    local className = "Folder"
                    for _, prop in ipairs(props) do
                        if prop.name == "ClassName" then className = prop.value break end
                    end
                    local created = instances.create_instance(className, props)
                    if created then
                        created.Name = Utilities.unescape_name((name:gsub(" %[%d+%]$", "")))
                        Remote.applyProperties(created, props)
                        created.Parent = parent
                    end
                end
            end
        end
    end

    --// deepest first, so children go before their parents
    table.sort(doomed, function(a, b) return #a > #b end)
    for _, entity in ipairs(doomed) do
        local target = Utilities.parse_path(entity)
        if target and target.Parent ~= game then
            pcall(function() target:Destroy() end)
        end
        matched += 1
    end

    Remote.resolve_instance_refs()
    return matched
end

--// ------------------------------------------------------------------ conflicts

--[[
Unmerged paths left behind by a stopped merge/cherry-pick/revert/rebase/stash apply.
Returns a sorted list of {path, reason}.
]]
function repo.read_conflicts()
    local raw = repo.read_file("ROGIT_CONFLICTS")
    if not raw or raw == "" then return {} end
    local ok, list = pcall(function() return HttpService:JSONDecode(raw) end)
    if not ok or type(list) ~= "table" then return {} end
    table.sort(list, function(a, b) return a.path < b.path end)
    return list
end

function repo.write_conflicts(list)
    if #list == 0 then
        repo.delete_file("ROGIT_CONFLICTS")
    else
        repo.write_file("ROGIT_CONFLICTS", HttpService:JSONEncode(list))
    end
end

--[[
Marks every conflict at or below one of the paths as resolved (`git add`/`git rm` do this).
]]
function repo.resolve_conflicts(paths)
    local list = repo.read_conflicts()
    if #list == 0 then return end
    local remaining = {}
    for _, conflict in ipairs(list) do
        if not repo.matches_filters(conflict.path, paths) then
            table.insert(remaining, conflict)
        end
    end
    repo.write_conflicts(remaining)
end

--[[
Which operation is in progress, if any: "merge", "cherry-pick", "revert", "rebase".
]]
function repo.operation_in_progress()
    if repo.read_file("ROGIT_SEQUENCER") then
        local ok, state = pcall(function() return HttpService:JSONDecode(repo.read_file("ROGIT_SEQUENCER")) end)
        if ok and state then return state.kind, state end
    end
    if repo.read_file("MERGE_HEAD") then return "merge" end
    if repo.read_file("CHERRY_PICK_HEAD") then return "cherry-pick" end
    if repo.read_file("REVERT_HEAD") then return "revert" end
    return nil
end

--[[
Forgets everything about a stopped operation.
]]
function repo.clear_operation_state()
    for _, name in ipairs({"MERGE_HEAD", "MERGE_MSG", "CHERRY_PICK_HEAD", "REVERT_HEAD", "ROGIT_CONFLICTS", "ROGIT_SEQUENCER", "ROGIT_PICK_AUTHOR"}) do
        repo.delete_file(name)
    end
end

--[[
Three-way merges `theirs_tree` into the current HEAD, using `base_tree` as the common ancestor.

On success returns the merged tree sha (nothing in the place changes yet, unless opts.apply).
On conflicts the place is updated anyway (clean parts merged, conflicting scripts get <<<<<<< markers,
other conflicting instances keep our version), the conflicts are recorded and nil + the conflict list is returned.

opts: prefer ("ours"/"theirs"), ours_label, theirs_label, apply (also update the place on success)
]]
function repo.three_way(base_tree, theirs_tree, opts)
    opts = opts or {}
    local ours_tree = repo.head_tree()

    local merged_index, conflicts, combined, worktree_index = merge.merge_indexes(
        repo.tree_index(base_tree),
        repo.tree_index(ours_tree),
        repo.tree_index(theirs_tree),
        {
            prefer = opts.prefer,
            labels = {ours = opts.ours_label or "HEAD", theirs = opts.theirs_label or "theirs"},
            read_blob = repo.read_blob_content,
            write_blob = function(content) return Handlers.write_blob(content) end,
        }
    )

    table.sort(combined)
    for _, path in ipairs(combined) do
        print("Auto-merging " .. path)
    end

    if #conflicts == 0 then
        local tree_sha = Handlers.write_tree(merged_index)
        if opts.apply then
            repo.checkout_tree(tree_sha)
        end
        return tree_sha, {}
    end

    --// Put the half merged result in the place: conflicting entries get their "worktree" version
    local list = {}
    for _, conflict in ipairs(conflicts) do
        table.insert(list, {path = conflict.path, reason = conflict.reason})
        print("CONFLICT (" .. conflict.reason .. "): " .. conflict.path)
    end

    local tree_sha = Handlers.write_tree(worktree_index)
    repo.checkout_tree(tree_sha)
    repo.write_conflicts(list)
    return nil, list
end

return repo
