--[[
Plumbing and inspection commands: cat-file, ls-files, ls-tree, rev-parse, rev-list, show-ref, merge-base,
symbolic-ref, update-ref, grep, blame, describe, shortlog, count-objects.
]]
local HttpService = game:GetService("HttpService")

local arguments = require(script.Parent.Parent.arguments)
local bash = require(script.Parent.Parent.bash)
local Handlers = require(script.Parent.Parent.libs.git_handlers)
local repo = require(script.Parent.Parent.libs.repo)
local output = require(script.Parent.Parent.libs.output)
local merge = require(script.Parent.Parent.libs.merge)
local Utilities = require(script.Parent.Parent.libs.utilities)
local instances = require(script.Parent.Parent.libs.instances)

local inspect = {}

local function print(...)
    output.print(...)
end

local function short(sha)
    return string.sub(sha or "", 1, 7)
end

--[[
Finds the entry for `path` inside a tree: returns {sha, mode, type} (directories are trees).
An instance path also finds its ".properties" blob when it has children.
]]
function inspect.tree_entry(tree_sha, path)
    if path == "" or path == "." then
        return {sha = tree_sha, mode = "40000", type = "tree"}
    end
    local current = {sha = tree_sha, mode = "40000", type = "tree"}
    for segment in path:gmatch("[^/]+") do
        if current.type ~= "tree" then return nil end
        local obj = Handlers.read_object(current.sha)
        if not obj then return nil end
        local found = nil
        for _, entry in ipairs(Handlers.parse_tree(obj.content)) do
            if entry.name == segment then
                found = {sha = entry.sha, mode = entry.mode, type = entry.mode == "40000" and "tree" or (entry.mode == "160000" and "commit" or "blob")}
                break
            end
        end
        if not found then return nil end
        current = found
    end
    return current
end

--[[
Resolves "<rev>", "<rev>:<path>" or ":<path>" (index) to an object sha.
]]
function inspect.resolve_object(spec)
    local rev, path = spec:match("^([^:]*):(.*)$")
    if rev then
        if rev == "" then
            local index = Handlers.read_index()
            local data = index[path] or index[path .. "/.properties"]
            return data and data.sha or nil
        end
        local commit = Handlers.read_commit(Handlers.resolve_revision(rev))
        if not commit then return nil end
        local entry = inspect.tree_entry(commit.tree, path)
        return entry and entry.sha or nil
    end
    local sha = Handlers.resolve_revision(spec)
    if sha then return sha end
    if #spec == 40 and Handlers.read_object(spec) then return spec end
    return nil
end

--[[
A readable listing of a serialized instance (used by cat-file -p and show <rev>:<path>).
]]
function inspect.pretty_blob(content)
    local ok, props = pcall(function() return HttpService:JSONDecode(content) end)
    if not ok or type(props) ~= "table" then
        return content
    end
    local lines = {}
    local source = nil
    for _, prop in ipairs(props) do
        if prop.name == "Source" and type(prop.value) == "string" then
            source = prop.value
        else
            local value = prop.value
            if type(value) == "table" then
                local encoded = HttpService:JSONEncode(value)
                value = #encoded > 120 and (encoded:sub(1, 117) .. "...") or encoded
            elseif type(value) == "string" then
                value = string.format("%q", value)
            end
            table.insert(lines, prop.name .. " = " .. tostring(value))
        end
    end
    if source then
        table.insert(lines, "Source =")
        table.insert(lines, source)
    end
    return table.concat(lines, "\n")
end

local function require_root()
    repo.require_root()
end

--// ------------------------------------------------------------------ cat-file
arguments.createArgument("git", "cat-file", "", function(...)
    require_root()
    local tuple = {...}
    local mode, spec = tuple[1], tuple[2]
    if not spec then
        mode, spec = "-p", tuple[1]
    end
    if not spec then
        error("usage: git cat-file (-t | -s | -e | -p) <object>", 0)
    end

    local sha = inspect.resolve_object(spec)
    local obj = sha and Handlers.read_object(sha)
    if mode == "-e" then
        if not obj then error("", 0) end
        return
    end
    if not obj then
        error("fatal: Not a valid object name " .. spec, 0)
    end

    if mode == "-t" then
        print(obj.type)
    elseif mode == "-s" then
        print(tostring(#obj.content))
    elseif obj.type == "tree" then
        for _, entry in ipairs(Handlers.parse_tree(obj.content)) do
            local mode_text = entry.mode == "40000" and "040000" or entry.mode
            print(string.format("%s %s %s\t%s", mode_text, entry.mode == "40000" and "tree" or (entry.mode == "160000" and "commit" or "blob"), entry.sha, entry.name))
        end
    elseif obj.type == "blob" and mode == "-p" then
        print(inspect.pretty_blob(obj.content))
    else
        print((obj.content:gsub("\n$", "")))
    end
end)

--// ------------------------------------------------------------------ ls-files
arguments.createArgument("git", "ls-files", "", function(...)
    require_root()
    local stage, others, modified, deleted, unmerged = false, false, false, false, false
    local filters = {}
    for _, arg in ipairs({...}) do
        if arg == "-s" or arg == "--stage" then stage = true
        elseif arg == "-o" or arg == "--others" then others = true
        elseif arg == "-m" or arg == "--modified" then modified = true
        elseif arg == "-d" or arg == "--deleted" then deleted = true
        elseif arg == "-u" or arg == "--unmerged" then unmerged = true
        elseif arg:sub(1, 1) ~= "-" then table.insert(filters, repo.normalize_user_path(arg))
        end
    end

    local index = Handlers.read_index()
    local lines = {}

    if others then
        for path in pairs(repo.collect_untracked(index)) do
            if repo.matches_filters(path, filters) then table.insert(lines, path) end
        end
    elseif unmerged then
        for _, conflict in ipairs(repo.read_conflicts()) do
            table.insert(lines, conflict.path)
        end
    elseif modified or deleted then
        local mod, del = repo.collect_worktree_changes(index)
        if modified then
            for _, path in ipairs(mod) do table.insert(lines, path) end
            for _, path in ipairs(del) do table.insert(lines, path) end
        else
            for _, path in ipairs(del) do table.insert(lines, path) end
        end
    else
        for path, data in pairs(index) do
            if repo.matches_filters(path, filters) then
                table.insert(lines, stage and string.format("%s %s 0\t%s", data.mode, data.sha, path) or path)
            end
        end
    end

    table.sort(lines, function(a, b)
        return (a:match("\t(.*)$") or a) < (b:match("\t(.*)$") or b)
    end)
    for _, line in ipairs(lines) do print(line) end
end)

--// ------------------------------------------------------------------ ls-tree
arguments.createArgument("git", "ls-tree", "", function(...)
    require_root()
    local recursive, name_only = false, false
    local positional = {}
    for _, arg in ipairs({...}) do
        if arg == "-r" then recursive = true
        elseif arg == "--name-only" or arg == "--name-status" then name_only = true
        elseif arg:sub(1, 1) ~= "-" then table.insert(positional, arg)
        end
    end
    if not positional[1] then
        error("usage: git ls-tree [<options>] <tree-ish> [<path>...]", 0)
    end

    local sha = inspect.resolve_object(positional[1])
    local obj = sha and Handlers.read_object(sha)
    if obj and obj.type == "commit" then
        sha = obj.content:match("^tree (%x+)")
    end
    local prefix = positional[2] and repo.normalize_user_path(positional[2]) or ""
    if prefix ~= "" then
        local entry = inspect.tree_entry(sha, prefix)
        if not entry then return end
        if entry.type ~= "tree" then
            print(name_only and prefix or string.format("%s blob %s\t%s", entry.mode, entry.sha, prefix))
            return
        end
        sha = entry.sha
    end

    local function list(tree_sha, base)
        local tree = Handlers.read_object(tree_sha)
        if not tree then error("fatal: not a tree object", 0) end
        for _, entry in ipairs(Handlers.parse_tree(tree.content)) do
            local path = base == "" and entry.name or (base .. "/" .. entry.name)
            if entry.mode == "40000" and recursive then
                list(entry.sha, path)
            elseif name_only then
                print(path)
            else
                print(string.format("%s %s %s\t%s", entry.mode == "40000" and "040000" or entry.mode, entry.mode == "40000" and "tree" or (entry.mode == "160000" and "commit" or "blob"), entry.sha, path))
            end
        end
    end
    list(sha, prefix)
end)

--// ------------------------------------------------------------------ rev-parse
arguments.createArgument("git", "rev-parse", "", function(...)
    local tuple = {...}
    local abbrev_ref, short_mode, verify = false, false, false
    for _, arg in ipairs(tuple) do
        if arg == "--abbrev-ref" then
            abbrev_ref = true
        elseif arg == "--short" or arg:match("^%-%-short=") then
            short_mode = tonumber(arg:match("^%-%-short=(%d+)$") or "7")
        elseif arg == "--verify" or arg == "-q" or arg == "--quiet" then
            verify = true
        elseif arg == "--git-dir" then
            print(".git")
        elseif arg == "--show-toplevel" then
            print(game.Name)
        elseif arg == "--is-inside-work-tree" then
            print(bash.getGitFolderRoot() and "true" or "false")
        elseif arg == "--is-bare-repository" then
            print("false")
        elseif arg:sub(1, 1) ~= "-" then
            require_root()
            if abbrev_ref then
                if arg == "HEAD" or arg == "@" then
                    print(Handlers.get_current_branch() or "HEAD")
                elseif arg:match("@{u") or arg:match("@{upstream}") then
                    local branch = arg:match("^(.-)@")
                    branch = (branch == "" or branch == "HEAD") and Handlers.get_current_branch() or branch
                    local remote, remote_branch = repo.get_upstream(branch)
                    print(remote .. "/" .. remote_branch)
                else
                    print(arg)
                end
            else
                local sha = inspect.resolve_object(arg)
                if not sha then
                    if verify then error("fatal: Needed a single revision", 0) end
                    error("fatal: ambiguous argument '" .. arg .. "': unknown revision or path not in the working tree.", 0)
                end
                print(short_mode and sha:sub(1, short_mode) or sha)
            end
        end
    end
end)

--// ------------------------------------------------------------------ rev-list
--[[
Commits reachable from the positive revisions but not from the ^negative ones (A..B works too), newest first.
]]
function inspect.rev_list(specs)
    local include, exclude = {}, {}
    for _, spec in ipairs(specs) do
        local from, to = spec:match("^(.-)%.%.(.+)$")
        if from then
            table.insert(exclude, Handlers.resolve_revision(from == "" and "HEAD" or from))
            table.insert(include, Handlers.resolve_revision(to))
        elseif spec:sub(1, 1) == "^" then
            table.insert(exclude, Handlers.resolve_revision(spec:sub(2)))
        else
            local sha = Handlers.resolve_revision(spec)
            if not sha then error("fatal: bad revision '" .. spec .. "'", 0) end
            table.insert(include, sha)
        end
    end
    if #include == 0 then table.insert(include, repo.head_sha()) end

    local excluded = {}
    for _, sha in ipairs(exclude) do
        for ancestor in pairs(Handlers.ancestors(sha)) do excluded[ancestor] = true end
    end

    local list, seen = {}, {}
    local queue = {}
    for _, sha in ipairs(include) do table.insert(queue, sha) end
    while #queue > 0 do
        local sha = table.remove(queue, 1)
        if sha and not seen[sha] and not excluded[sha] then
            seen[sha] = true
            local commit = Handlers.read_commit(sha)
            if commit then
                table.insert(list, {sha = sha, commit = commit})
                for _, parent in ipairs(commit.parents) do table.insert(queue, parent) end
            end
            Utilities.roYield()
        end
    end
    table.sort(list, function(a, b)
        local ta = tonumber((a.commit.committer or ""):match("(%d+) [+-]%d+$")) or 0
        local tb = tonumber((b.commit.committer or ""):match("(%d+) [+-]%d+$")) or 0
        return ta > tb
    end)
    return list
end

arguments.createArgument("git", "rev-list", "", function(...)
    require_root()
    local count, max = false, nil
    local specs = {}
    local tuple = {...}
    local i = 1
    while i <= #tuple do
        local arg = tuple[i]
        if arg == "--count" then count = true
        elseif (arg == "-n" or arg == "--max-count") and tuple[i + 1] then max = tonumber(tuple[i + 1]) i += 1
        elseif arg == "--all" then
            for _, sha in pairs(Handlers.list_refs()) do table.insert(specs, sha) end
        elseif arg:sub(1, 1) ~= "-" then table.insert(specs, arg)
        end
        i += 1
    end
    local list = inspect.rev_list(specs)
    if count then
        print(tostring(#list))
        return
    end
    for n, item in ipairs(list) do
        if max and n > max then break end
        print(item.sha)
    end
end)

--// ------------------------------------------------------------------ show-ref / symbolic-ref / update-ref / merge-base
arguments.createArgument("git", "show-ref", "", function(...)
    require_root()
    local heads, tags = false, false
    for _, arg in ipairs({...}) do
        if arg == "--heads" or arg == "--branches" then heads = true end
        if arg == "--tags" then tags = true end
    end
    local names = {}
    for name in pairs(Handlers.list_refs()) do table.insert(names, name) end
    table.sort(names)
    local refs = Handlers.list_refs()
    for _, name in ipairs(names) do
        if (not heads and not tags) or (heads and name:match("^refs/heads/")) or (tags and name:match("^refs/tags/")) then
            print(refs[name] .. " " .. name)
        end
    end
end)

arguments.createArgument("git", "symbolic-ref", "", function(...)
    require_root()
    local tuple = {...}
    local short_name = false
    local positional = {}
    for _, arg in ipairs(tuple) do
        if arg == "--short" then short_name = true elseif arg:sub(1, 1) ~= "-" then table.insert(positional, arg) end
    end
    if positional[1] ~= "HEAD" then
        error("fatal: only HEAD is a symbolic ref in roGit", 0)
    end
    if positional[2] then
        Handlers.set_head(positional[2], "symbolic-ref")
        return
    end
    local head = repo.read_file("HEAD") or ""
    local target = head:match("^ref: (.+)$")
    if not target then
        error("fatal: ref HEAD is not a symbolic ref", 0)
    end
    print(short_name and (target:gsub("^refs/heads/", "")) or target)
end)

arguments.createArgument("git", "update-ref", "", function(...)
    require_root()
    local tuple = {...}
    if tuple[1] == "-d" then
        if not Handlers.delete_ref(tuple[2] or "") then
            error("error: cannot lock ref '" .. tostring(tuple[2]) .. "'", 0)
        end
        return
    end
    local ref, rev = tuple[1], tuple[2]
    local sha = rev and Handlers.resolve_revision(rev)
    if not ref or not sha then
        error("usage: git update-ref [-d] <refname> [<new-oid>]", 0)
    end
    Handlers.update_ref(ref, sha, "update-ref")
end)

arguments.createArgument("git", "merge-base", "", function(...)
    require_root()
    local tuple = {...}
    if tuple[1] == "--is-ancestor" then
        local a, b = Handlers.resolve_revision(tuple[2] or ""), Handlers.resolve_revision(tuple[3] or "")
        if not (a and b and repo.is_ancestor(a, b)) then
            error("", 0)
        end
        return
    end
    local a, b = Handlers.resolve_revision(tuple[1] or ""), Handlers.resolve_revision(tuple[2] or "")
    if not a or not b then
        error("usage: git merge-base <commit> <commit>", 0)
    end
    local base = Handlers.merge_base(a, b)
    if not base then error("", 0) end
    print(base)
end)

--// ------------------------------------------------------------------ grep
--[[
Script sources of the index entries (live instances), or of a commit.
Returns a sorted list of {path, text}.
]]
local function script_sources(rev, filters)
    local sources = {}
    if rev then
        local commit = Handlers.read_commit(Handlers.resolve_revision(rev))
        if not commit then error("fatal: bad revision '" .. rev .. "'", 0) end
        for path, data in pairs(repo.tree_index(commit.tree)) do
            if repo.matches_filters(path, filters) then
                local content = repo.read_blob_content(data.sha)
                local ok, props = pcall(function() return HttpService:JSONDecode(content) end)
                if ok and type(props) == "table" then
                    for _, prop in ipairs(props) do
                        if prop.name == "Source" and type(prop.value) == "string" then
                            table.insert(sources, {path = repo.entity_of(path), text = prop.value})
                        end
                    end
                end
            end
        end
    else
        for path in pairs(Handlers.read_index()) do
            if repo.matches_filters(path, filters) then
                local instance = Utilities.parse_path(repo.entity_of(path))
                if instance and instance:IsA("LuaSourceContainer") then
                    local ok, text = pcall(function() return (instance :: any).Source end)
                    if ok and type(text) == "string" then
                        table.insert(sources, {path = repo.entity_of(path), text = text})
                    end
                end
            end
        end
    end
    table.sort(sources, function(a, b) return a.path < b.path end)
    return sources
end

arguments.createArgument("git", "grep", "", function(...)
    require_root()
    local tuple = {...}
    local ignore_case, line_numbers, count, files_only, lua_pattern, invert, word = false, false, false, false, false, false, false
    local pattern, rev = nil, nil
    local filters = {}
    local after_dashes = false

    local i = 1
    while i <= #tuple do
        local arg = tuple[i]
        if after_dashes then
            table.insert(filters, repo.normalize_user_path(arg))
        elseif arg == "--" then after_dashes = true
        elseif arg == "-i" or arg == "--ignore-case" then ignore_case = true
        elseif arg == "-n" or arg == "--line-number" then line_numbers = true
        elseif arg == "-c" or arg == "--count" then count = true
        elseif arg == "-l" or arg == "--files-with-matches" then files_only = true
        elseif arg == "-v" or arg == "--invert-match" then invert = true
        elseif arg == "-w" or arg == "--word-regexp" then word = true
        elseif arg == "-E" or arg == "-P" or arg == "--extended-regexp" then lua_pattern = true
        elseif arg == "-e" and tuple[i + 1] then pattern = tuple[i + 1] i += 1
        elseif arg:sub(1, 1) ~= "-" then
            if not pattern then
                pattern = arg
            elseif not rev and Handlers.resolve_revision(arg) then
                rev = arg
            else
                table.insert(filters, repo.normalize_user_path(arg))
            end
        end
        i += 1
    end

    if not pattern then
        error("usage: git grep [<options>] [-e] <pattern> [<rev>...] [[--] <path>...]\n(patterns are plain text, -E makes them Lua patterns)", 0)
    end

    local needle = ignore_case and pattern:lower() or pattern
    local function matches(line)
        local haystack = ignore_case and line:lower() or line
        local found
        if lua_pattern then
            found = haystack:find(needle) ~= nil
        elseif word then
            found = haystack:find("%f[%w_]" .. needle:gsub("%p", "%%%0") .. "%f[^%w_]") ~= nil
        else
            found = haystack:find(needle, 1, true) ~= nil
        end
        return found ~= invert
    end

    local any = false
    for _, source in ipairs(script_sources(rev, filters)) do
        local prefix = rev and (rev .. ":" .. source.path) or source.path
        local hits = 0
        local n = 0
        for line in (source.text .. "\n"):gmatch("([^\n]*)\n") do
            n += 1
            if matches(line) then
                hits += 1
                any = true
                if not count and not files_only then
                    print("\27[35m" .. prefix .. "\27[0m:" .. (line_numbers and ("\27[32m" .. n .. "\27[0m:") or "") .. line)
                end
            end
        end
        if hits > 0 and files_only then print(prefix) end
        if hits > 0 and count then print(prefix .. ":" .. hits) end
    end

    if not any then
        error("", 0) --// like git: no output, failure exit
    end
end)

--// ------------------------------------------------------------------ blame
arguments.createArgument("git", "blame", "", function(...)
    require_root()
    local positional = {}
    for _, arg in ipairs({...}) do
        if arg ~= "--" and arg:sub(1, 1) ~= "-" then table.insert(positional, arg) end
    end

    local rev, path
    if #positional >= 2 and Handlers.resolve_revision(positional[1]) then
        rev, path = positional[1], positional[2]
    else
        rev, path = "HEAD", positional[1]
    end
    if not path then
        error("usage: git blame [<rev>] [--] <path>", 0)
    end
    path = repo.normalize_user_path(path)

    local function source_at(sha)
        local commit = Handlers.read_commit(sha)
        if not commit then return nil end
        local index = repo.tree_index(commit.tree)
        local data = index[path] or index[path .. "/.properties"]
        if not data then return nil end
        local ok, props = pcall(function() return HttpService:JSONDecode(repo.read_blob_content(data.sha)) end)
        if not ok then return nil end
        for _, prop in ipairs(props) do
            if prop.name == "Source" and type(prop.value) == "string" then return prop.value end
        end
        return nil
    end

    local start = Handlers.resolve_revision(rev)
    local text = start and source_at(start)
    if not text then
        error("fatal: no such path '" .. path .. "' in " .. rev .. " (or it is not a script)", 0)
    end

    local lines = merge.split_lines(text)
    local owner = {}
    --// pending: current line index -> original line number, while walking back through first parents
    local pending = {}
    for n = 1, #lines do pending[n] = n end

    local sha = start
    local current_lines = lines
    while sha and next(pending) do
        local commit = Handlers.read_commit(sha)
        local parent = commit and commit.parents[1]
        local parent_text = parent and source_at(parent)
        if not parent_text then
            for _, original in pairs(pending) do owner[original] = sha end
            break
        end

        local parent_lines = merge.split_lines(parent_text)
        local hunks = merge.diff_hunks(parent_lines, current_lines) or {{s = 1, e = #parent_lines + 1, lines = current_lines}}

        --// map each current line either to a parent line, or to this commit
        local next_pending = {}
        local child, base = 1, 1
        local function carry(child_index, base_index)
            if pending[child_index] then next_pending[base_index] = pending[child_index] end
        end
        for _, hunk in ipairs(hunks) do
            while base < hunk.s do
                carry(child, base)
                child += 1
                base += 1
            end
            for _ = 1, #hunk.lines do
                if pending[child] then owner[pending[child]] = sha end
                child += 1
            end
            base = hunk.e
        end
        while child <= #current_lines do
            carry(child, base)
            child += 1
            base += 1
        end

        pending = next_pending
        current_lines = parent_lines
        sha = parent
        Utilities.roYield()
    end

    for n, line in ipairs(lines) do
        local commit = owner[n] and Handlers.read_commit(owner[n])
        local who, time = "Not Committed Yet", nil
        if commit and commit.author then
            who, time = commit.author:match("^(.-) <.-> (%d+)")
        end
        print(string.format("%s (%-12s %s %4d) %s",
            string.sub(owner[n] or ("0"):rep(8), 1, 8),
            (who or "?"):sub(1, 12),
            time and os.date("!%Y-%m-%d %H:%M:%S", tonumber(time)) or "",
            n,
            (line:gsub("\n$", ""))))
    end
end)

--// ------------------------------------------------------------------ describe
arguments.createArgument("git", "describe", "", function(...)
    require_root()
    local all_tags, always, long = false, false, false
    local rev = "HEAD"
    for _, arg in ipairs({...}) do
        if arg == "--tags" then all_tags = true
        elseif arg == "--always" then always = true
        elseif arg == "--long" then long = true
        elseif arg:sub(1, 1) ~= "-" then rev = arg
        end
    end
    local start = Handlers.resolve_revision(rev)
    if not start then error("fatal: Not a valid object name " .. rev, 0) end

    local tags = {}
    for name, sha in pairs(Handlers.list_refs()) do
        local tag = name:match("^refs/tags/(.+)$")
        if tag then
            local obj = Handlers.read_object(sha)
            if obj and obj.type == "tag" then
                tags[obj.content:match("^object (%x+)") or sha] = tag
            elseif all_tags then
                tags[sha] = tags[sha] or tag
            end
        end
    end

    local queue, depth, seen = {start}, {[start] = 0}, {}
    while #queue > 0 do
        local sha = table.remove(queue, 1)
        if not seen[sha] then
            seen[sha] = true
            if tags[sha] then
                if depth[sha] == 0 and not long then
                    print(tags[sha])
                else
                    print(string.format("%s-%d-g%s", tags[sha], depth[sha], short(start)))
                end
                return
            end
            local commit = Handlers.read_commit(sha)
            for _, parent in ipairs(commit and commit.parents or {}) do
                if depth[parent] == nil then depth[parent] = depth[sha] + 1 end
                table.insert(queue, parent)
            end
        end
    end

    if always then
        print(short(start))
        return
    end
    error("fatal: No names found, cannot describe anything.", 0)
end)

--// ------------------------------------------------------------------ shortlog
arguments.createArgument("git", "shortlog", "", function(...)
    require_root()
    local summary, numbered, emails = false, false, false
    local specs = {}
    for _, arg in ipairs({...}) do
        if arg:match("^%-[sne]+$") then
            if arg:find("s") then summary = true end
            if arg:find("n") then numbered = true end
            if arg:find("e") then emails = true end
        elseif arg == "--summary" then summary = true
        elseif arg == "--numbered" then numbered = true
        elseif arg == "--email" then emails = true
        elseif arg:sub(1, 1) ~= "-" then table.insert(specs, arg)
        end
    end

    local groups, order = {}, {}
    local list = inspect.rev_list(specs)
    for n = #list, 1, -1 do
        local commit = list[n].commit
        local name, email = (commit.author or ""):match("^(.-) <(.-)>")
        local key = (name or "?") .. (emails and (" <" .. (email or "") .. ">") or "")
        if not groups[key] then
            groups[key] = {}
            table.insert(order, key)
        end
        table.insert(groups[key], commit.message:match("^[^\n]*") or "")
    end

    table.sort(order, function(a, b)
        if numbered and #groups[a] ~= #groups[b] then return #groups[a] > #groups[b] end
        return a < b
    end)
    for _, key in ipairs(order) do
        if summary then
            print(string.format("%6d\t%s", #groups[key], key))
        else
            print(key .. " (" .. #groups[key] .. "):")
            for _, subject in ipairs(groups[key]) do print("      " .. subject) end
            print("")
        end
    end
end)

--// ------------------------------------------------------------------ count-objects
arguments.createArgument("git", "count-objects", "", function()
    local root = repo.require_root()
    local objects = root:FindFirstChild("objects")
    local count, size = 0, 0
    for _, folder in ipairs(objects and objects:GetChildren() or {}) do
        if #folder.Name == 2 then
            for _, file in ipairs(folder:GetChildren()) do
                count += 1
                local content = bash.getFileContents(folder, file.Name)
                size += content and #content or 0
            end
        end
    end
    print(string.format("%d objects, %d kilobytes", count, math.floor(size * 3 / 4 / 1024)))
end)

--[[
Prints a readable version of <rev>:<path> (used by git show).
]]
function inspect.show_object(spec)
    local sha = inspect.resolve_object(spec)
    local obj = sha and Handlers.read_object(sha)
    if not obj then
        error("fatal: invalid object name '" .. spec .. "'.", 0)
    end
    if obj.type == "blob" then
        print(inspect.pretty_blob(obj.content))
    elseif obj.type == "tree" then
        --// an instance with children: its properties, then what's inside
        local children = {}
        for _, entry in ipairs(Handlers.parse_tree(obj.content)) do
            if entry.name == ".properties" then
                local props = Handlers.read_object(entry.sha)
                if props then print(inspect.pretty_blob(props.content)) print("") end
            else
                table.insert(children, entry.name .. (entry.mode == "40000" and "/" or ""))
            end
        end
        print("tree " .. spec .. "\n")
        for _, name in ipairs(children) do print(name) end
    else
        print((obj.content:gsub("\n$", "")))
    end
end

local _ = instances
return inspect
