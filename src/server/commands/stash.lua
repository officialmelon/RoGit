--[[
git stash: put uncommitted changes aside and bring them back later.

Stashes are stored like git stores them: a "WIP" commit of the working tree whose parents are
the commit you were on and a commit of the index, refs/stash points at the newest and the
stash list is the reflog of refs/stash.
]]
local arguments = require(script.Parent.Parent.arguments)
local Handlers = require(script.Parent.Parent.libs.git_handlers)
local repo = require(script.Parent.Parent.libs.repo)
local output = require(script.Parent.Parent.libs.output)
local diff = require(script.Parent.Parent.libs.diff)

local function print(...)
    output.print(...)
end

local function short(sha)
    return string.sub(sha or "", 1, 7)
end

--[[
Resolves "stash@{2}", "2" or nothing (latest) to {index, sha, message}.
]]
local function find_stash(arg)
    local entries = Handlers.read_reflog("refs/stash")
    local n = 0
    if arg then
        n = tonumber(arg:match("^stash@{(%d+)}$") or arg:match("^(%d+)$") or "")
        if not n then
            error("error: '" .. arg .. "' is not a stash-like commit", 0)
        end
    end
    local entry = entries[n + 1]
    if not entry then
        if #entries == 0 then
            error("error: No stash entries found.", 0)
        end
        error("error: stash@{" .. n .. "} is not a valid reference", 0)
    end
    return {index = n, sha = entry.new, message = entry.message}
end

--[[
Removes one entry from the stash list (and moves refs/stash).
]]
local function drop_entry(n)
    local raw = repo.read_file("logs/refs/stash") or ""
    local lines = {}
    for line in raw:gmatch("[^\n]+") do
        table.insert(lines, line)
    end
    --// the reflog is oldest first, stash@{0} is the last line
    table.remove(lines, #lines - n)

    if #lines == 0 then
        repo.delete_file("logs/refs/stash")
        Handlers.delete_ref("refs/stash")
    else
        repo.write_file("logs/refs/stash", table.concat(lines, "\n") .. "\n")
        local newest = lines[#lines]:match("^%x+ (%x+)")
        repo.write_file("refs/stash", newest)
    end
end

local function stash_push(message, include_untracked)
    local head = repo.head_sha()
    if not head then
        error("You do not have the initial commit yet", 0)
    end

    local index = Handlers.read_index()
    local untracked = repo.collect_untracked(index)
    local has_untracked = next(untracked) ~= nil
    local dirty = repo.dirty_changes()
    if #dirty == 0 and not (include_untracked and has_untracked) then
        print("No local changes to save")
        return
    end

    local branch = Handlers.get_current_branch() or "(no branch)"
    local head_commit = Handlers.read_commit(head)
    local description = short(head) .. " " .. (head_commit.message:match("^[^\n]*") or "")

    local index_commit = repo.write_commit_object(Handlers.write_tree(index), {head}, "index on " .. branch .. ": " .. description)

    local snapshot = repo.snapshot_worktree()
    if not include_untracked then
        for path in pairs(untracked) do
            for key in pairs(snapshot) do
                if key == path or key:sub(1, #path + 1) == path .. "/" then
                    snapshot[key] = nil
                end
            end
        end
    end

    local title = message and ("On " .. branch .. ": " .. message) or ("WIP on " .. branch .. ": " .. description)
    local stash_commit = repo.write_commit_object(Handlers.write_tree(snapshot), {head, index_commit}, title)
    Handlers.update_ref("refs/stash", stash_commit, title)

    --// back to a clean HEAD
    repo.checkout_tree(head_commit.tree)
    if include_untracked then
        for _, instance in pairs(untracked) do
            pcall(function() instance:Destroy() end)
        end
    end

    print("Saved working directory and index state " .. title)
end

local function stash_apply(arg, drop_after)
    local entry = find_stash(arg)
    local stash = Handlers.read_commit(entry.sha)
    local base = stash and Handlers.read_commit(stash.parents[1])
    if not stash or not base then
        error("error: " .. entry.sha .. " is not a stash-like commit", 0)
    end

    repo.ensure_clean("checkout")

    local head_index = repo.read_last_index()
    local tree_sha, conflicts = repo.three_way(base.tree, stash.tree, {
        ours_label = "Updated upstream",
        theirs_label = "Stashed changes",
    })

    if not tree_sha then
        error(string.format("error: %d conflict(s) applying the stash.\nThe stash entry is kept in case you need it again.", #conflicts), 0)
    end

    repo.checkout_tree(tree_sha)

    --// like git: the changes come back unstaged, only new instances are staged
    local applied = Handlers.read_index()
    local index = table.clone(head_index)
    for path, data in pairs(applied) do
        if not head_index[path] then
            index[path] = data
        end
    end
    Handlers.write_index(index)

    if drop_after then
        drop_entry(entry.index)
        print(string.format("Dropped stash@{%d} (%s)", entry.index, entry.sha))
    else
        print("Applied stash@{" .. entry.index .. "}")
    end
end

arguments.createArgument("git", "stash", "", function(...)
    repo.require_root()
    local tuple = {...}
    local sub = tuple[1]
    local rest = {table.unpack(tuple, 2)}

    if sub == nil or sub == "push" or sub == "save" or (sub and sub:sub(1, 1) == "-") then
        local args = (sub == "push" or sub == "save") and rest or tuple
        local message = nil
        local include_untracked = false
        local i = 1
        while i <= #args do
            local arg = args[i]
            if (arg == "-m" or arg == "--message") and args[i + 1] then
                message = args[i + 1]
                i += 1
            elseif arg == "-u" or arg == "--include-untracked" or arg == "-a" or arg == "--all" then
                include_untracked = true
            elseif sub == "save" and arg:sub(1, 1) ~= "-" then
                message = message and (message .. " " .. arg) or arg
            end
            i += 1
        end
        stash_push(message, include_untracked)

    elseif sub == "list" then
        for n, entry in ipairs(Handlers.read_reflog("refs/stash")) do
            print(string.format("stash@{%d}: %s", n - 1, entry.message))
        end

    elseif sub == "show" then
        local patch = false
        local which = nil
        for _, arg in ipairs(rest) do
            if arg == "-p" or arg == "--patch" then patch = true elseif arg:sub(1, 1) ~= "-" then which = arg end
        end
        local entry = find_stash(which)
        local stash = Handlers.read_commit(entry.sha)
        local base = Handlers.read_commit(stash.parents[1])
        local old_index = repo.tree_index(base.tree)
        local new_index = repo.tree_index(stash.tree)
        local paths, seen = {}, {}
        for path in pairs(old_index) do seen[path] = true table.insert(paths, path) end
        for path in pairs(new_index) do if not seen[path] then table.insert(paths, path) end end
        table.sort(paths)
        for _, path in ipairs(paths) do
            local old, new = old_index[path], new_index[path]
            if not old or not new or old.sha ~= new.sha then
                local status = (not old and "A") or (not new and "D") or "M"
                print(status .. "\t" .. path)
                if patch and status == "M" then
                    for _, line in ipairs(diff.describe(repo.read_blob_content(old.sha), repo.read_blob_content(new.sha))) do
                        print(line)
                    end
                end
            end
        end

    elseif sub == "apply" then
        stash_apply(rest[1], false)

    elseif sub == "pop" then
        stash_apply(rest[1], true)

    elseif sub == "drop" then
        local entry = find_stash(rest[1])
        drop_entry(entry.index)
        print(string.format("Dropped stash@{%d} (%s)", entry.index, entry.sha))

    elseif sub == "clear" then
        repo.delete_file("logs/refs/stash")
        Handlers.delete_ref("refs/stash")

    elseif sub == "branch" then
        local name = rest[1]
        if not name then
            error("usage: git stash branch <branchname> [<stash>]", 0)
        end
        local entry = find_stash(rest[2])
        local stash = Handlers.read_commit(entry.sha)
        arguments.execute("git", "switch", "-c", name, stash.parents[1])
        stash_apply(rest[2], true)

    else
        error("error: unknown subcommand: " .. tostring(sub) .. "\nusage: git stash list | show | drop | pop | apply | branch | push | clear", 0)
    end
end)

return {}
