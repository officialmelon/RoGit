--[[
History rewriting commands: cherry-pick, revert, rebase, and reflog.

cherry-pick/revert/rebase share one "sequencer": a list of commits applied one by one.
When one of them conflicts the sequence stops (state in .git/ROGIT_SEQUENCER), the user resolves,
`git add`s and runs `--continue`, or gives up with `--abort` / `--skip`.
]]
local HttpService = game:GetService("HttpService")

local arguments = require(script.Parent.Parent.arguments)
local Handlers = require(script.Parent.Parent.libs.git_handlers)
local repo = require(script.Parent.Parent.libs.repo)
local output = require(script.Parent.Parent.libs.output)
local Utilities = require(script.Parent.Parent.libs.utilities)
local hooks = require(script.Parent.Parent.libs.hooks)
local editor = require(script.Parent.Parent.libs.editor)

local function print(...)
    output.print(...)
end

local function short(sha)
    return string.sub(sha or "", 1, 7)
end

local function subject_of(commit)
    return (commit.message:match("^[^\n]*") or "")
end

--// ------------------------------------------------------------------ sequencer state

local function load_state()
    local raw = repo.read_file("ROGIT_SEQUENCER")
    if not raw then return nil end
    local ok, state = pcall(function() return HttpService:JSONDecode(raw) end)
    return ok and state or nil
end

local function save_state(state)
    repo.write_file("ROGIT_SEQUENCER", HttpService:JSONEncode(state))
end

local function clear_step_files()
    for _, name in ipairs({"MERGE_MSG", "CHERRY_PICK_HEAD", "REVERT_HEAD", "ROGIT_PICK_AUTHOR", "ROGIT_CONFLICTS"}) do
        repo.delete_file(name)
    end
end

--[[
The message a picked/reverted commit gets.
]]
local function message_for(kind, sha, commit, opts)
    if kind == "revert" then
        return string.format('Revert "%s"\n\nThis reverts commit %s.\n', subject_of(commit), sha)
    end
    local message = commit.message
    if opts.record_origin then
        message = message:gsub("\n+$", "") .. "\n\n(cherry picked from commit " .. sha .. ")\n"
    end
    return message
end

--[[
Turns old style todo entries (plain shas) into steps: {cmd = "pick" | "revert" | "reword" | "edit" | "squash" | "fixup" | "exec" | "break", sha, arg}.
]]
local function as_step(kind, entry)
    if type(entry) == "table" then return entry end
    return {cmd = kind == "revert" and "revert" or "pick", sha = entry}
end

local function changed_since_head()
    local index = Handlers.read_index()
    local head_index = repo.read_last_index()
    for path, data in pairs(index) do
        if not head_index[path] or head_index[path].sha ~= data.sha then return true end
    end
    for path in pairs(head_index) do
        if not index[path] then return true end
    end
    return false
end

--[[
Records `tree_sha` for a step: a new commit (pick/revert/reword/edit) or folded into HEAD (squash/fixup).
]]
local function commit_step(state, step, tree_sha, message, author)
    local reflog = state.kind == "rebase" and ("rebase (" .. step.cmd .. ")") or state.kind

    if step.cmd == "squash" or step.cmd == "fixup" then
        local head = Handlers.read_commit(repo.head_sha())
        local combined = head.message
        if step.cmd == "squash" then
            combined = editor.message(
                editor.COMMENT .. " This is a combination of 2 commits.\n" .. editor.COMMENT .. " This is the 1st commit message:\n\n"
                    .. head.message:gsub("\n+$", "") .. "\n\n" .. editor.COMMENT .. " This is the commit message #2:\n\n" .. message,
                {"Please enter the commit message for your changes. Lines starting", "with '--' will be ignored, and an empty message aborts the commit."},
                "COMMIT_EDITMSG"
            )
            if combined == "" then combined = head.message end
        end
        repo.create_commit(tree_sha, head.parents, combined, {author = head.author, reflog = reflog})
    else
        if step.cmd == "reword" then
            local edited = editor.message((message:gsub("\n+$", "")), {"Please enter the commit message for your changes.", "Lines starting with '--' will be ignored."}, "COMMIT_EDITMSG")
            if edited ~= "" then message = edited end
        end
        local new_sha = repo.create_commit(tree_sha, {repo.head_sha()}, message, {author = author, reflog = reflog, sign = state.opts.sign})
        if state.kind ~= "rebase" then
            print(string.format("[%s %s] %s", Handlers.get_current_branch() or "detached HEAD", short(new_sha), (message:match("^[^\n]*"))))
        end
    end
    repo.checkout_tree(tree_sha)
end

--[[
Applies one step on top of HEAD. Returns "done", "conflict" or "stop" (edit/break: hand control back to the user).
]]
local function apply_step(state, step)
    local kind, opts = state.kind, state.opts

    if step.cmd == "break" then
        return "stop"
    elseif step.cmd == "exec" then
        local args = {}
        for word in tostring(step.arg or ""):gmatch("%S+") do table.insert(args, word) end
        if args[1] == "git" then table.remove(args, 1) end
        local ok, err = pcall(arguments.execute, "git", table.unpack(args))
        if not ok then
            error("warning: execution failed: git " .. tostring(step.arg) .. "\n" .. tostring(err) .. "\nYou can fix the problem, and then run\n\n  git rebase --continue", 0)
        end
        return "done"
    elseif step.cmd == "drop" then
        return "done"
    end

    local sha = step.sha
    local commit = Handlers.read_commit(sha)
    if not commit then
        error("fatal: bad revision '" .. tostring(sha) .. "'", 0)
    end

    local parent = commit.parents[opts.mainline or 1]
    if #commit.parents > 1 and not opts.mainline then
        if kind == "rebase" then
            return "done" --// merge commits are dropped by a rebase, like git does
        end
        error("error: commit " .. sha .. " is a merge but no -m option was given.", 0)
    end
    local parent_commit = parent and Handlers.read_commit(parent)
    local parent_tree = parent_commit and parent_commit.tree or nil

    local base, theirs = parent_tree, commit.tree
    if step.cmd == "revert" then
        base, theirs = commit.tree, parent_tree
    end

    local label = short(sha) .. " (" .. subject_of(commit) .. ")"
    local message = message_for(step.cmd == "revert" and "revert" or kind, sha, commit, opts)
    local author = step.cmd ~= "revert" and commit.author or nil

    local tree_sha = repo.three_way(base, theirs, {
        prefer = opts.prefer,
        ours_label = "HEAD",
        theirs_label = (step.cmd == "revert" and "parent of " or "") .. label,
    })

    if not tree_sha then
        repo.write_file(step.cmd == "revert" and "REVERT_HEAD" or "CHERRY_PICK_HEAD", sha)
        repo.write_file("MERGE_MSG", message)
        if author then repo.write_file("ROGIT_PICK_AUTHOR", author) end
        return "conflict"
    end

    if tree_sha == repo.head_tree() and step.cmd ~= "squash" and step.cmd ~= "fixup" then
        if kind == "rebase" then
            print("dropping " .. sha .. " " .. subject_of(commit) .. " -- patch contents already upstream")
        else
            print("The previous " .. kind .. " is now empty, skipping " .. short(sha))
        end
        return step.cmd == "edit" and "stop" or "done"
    end

    if opts.no_commit then
        repo.checkout_tree(tree_sha)
        return "done"
    end

    commit_step(state, step, tree_sha, message, author)
    return step.cmd == "edit" and "stop" or "done"
end

local function finish(state)
    if state.kind == "rebase" and state.head_name then
        local head = repo.head_sha()
        Handlers.update_ref(state.head_name, head, "rebase (finish): " .. state.head_name .. " onto " .. state.onto)
        Handlers.set_head(state.head_name, "rebase (finish): returning to " .. state.head_name)
        print("Successfully rebased and updated " .. state.head_name .. ".")
        hooks.notify("post-rewrite", {args = {"rebase"}})
    elseif state.kind == "rebase" then
        print("Successfully rebased.")
    end
    clear_step_files()
    repo.delete_file("ROGIT_SEQUENCER")
end

local function stop_message(state)
    local verb = state.kind
    local sha = state.current and state.current.sha
    local commit = sha and Handlers.read_commit(sha)
    local lines = {}
    if state.kind == "rebase" then
        table.insert(lines, "error: could not apply " .. short(sha) .. "... " .. (commit and subject_of(commit) or ""))
        table.insert(lines, "hint: Resolve all conflicts manually, mark them as resolved with")
        table.insert(lines, 'hint: "git add <conflicted_files>", then run "git rebase --continue".')
        table.insert(lines, 'hint: You can instead skip this commit: run "git rebase --skip".')
        table.insert(lines, 'hint: To abort and get back to the state before "git rebase", run "git rebase --abort".')
    else
        table.insert(lines, "error: could not " .. verb .. " " .. short(sha) .. "... " .. (commit and subject_of(commit) or ""))
        table.insert(lines, "hint: After resolving the conflicts, mark them with")
        table.insert(lines, 'hint: "git add <paths>", then run "git ' .. verb .. ' --continue".')
        table.insert(lines, 'hint: You can instead skip this commit with "git ' .. verb .. ' --skip".')
        table.insert(lines, 'hint: To abort and get back to the state before "git ' .. verb .. '", run "git ' .. verb .. ' --abort".')
    end
    return table.concat(lines, "\n")
end

local function run_sequence(state)
    while #state.todo > 0 do
        local step = as_step(state.kind, table.remove(state.todo, 1))
        state.current = step
        save_state(state)

        local result = apply_step(state, step)
        if result == "conflict" then
            save_state(state)
            error(stop_message(state), 0)
        end

        table.insert(state.done, step)
        state.current = nil
        save_state(state)

        if result == "stop" then
            if step.cmd == "edit" then
                local commit = Handlers.read_commit(repo.head_sha())
                print("Stopped at " .. short(step.sha) .. "...  " .. (commit and subject_of(commit) or ""))
                print("You can amend the commit now, with\n\n  git commit --amend\n\nOnce you are satisfied with your changes, run\n\n  git rebase --continue")
            else
                print("Stopped at " .. short(repo.head_sha()) .. "... (break)\nRun 'git rebase --continue' when you're done.")
            end
            return
        end
        Utilities.roYield()
    end
    finish(state)
end

--[[
--continue: commit the resolved step (if the user didn't already), then carry on.
]]
local function continue_sequence(kind)
    local state = load_state()
    if not state or state.kind ~= kind then
        error("error: no " .. kind .. " in progress", 0)
    end

    if #repo.read_conflicts() > 0 then
        error("error: you need to resolve your current index first\nhint: fix the conflicts, `git add` them, then continue.", 0)
    end

    if state.current then
        local step = as_step(kind, state.current)
        --// commit what was resolved, unless `git commit` already did
        if changed_since_head() and not state.opts.no_commit then
            local message = repo.read_file("MERGE_MSG") or ""
            local author = repo.read_file("ROGIT_PICK_AUTHOR")
            commit_step(state, step, Handlers.write_tree(Handlers.read_index()), message, author)
        end
        table.insert(state.done, step)
        state.current = nil
    elseif changed_since_head() then
        --// stopped by "edit"/"break" and then changed without committing: git refuses too
        error("error: you have staged changes in your working tree.\nIf these changes are meant to be squashed into the previous commit, run:\n\n  git commit --amend\n\nThen run git rebase --continue", 0)
    end

    clear_step_files()
    run_sequence(state)
end

local function abort_sequence(kind)
    local state = load_state()
    if not state or state.kind ~= kind then
        error("error: no " .. kind .. " in progress", 0)
    end

    local orig = Handlers.read_commit(state.orig_head)
    if state.kind == "rebase" and state.head_name then
        Handlers.update_ref(state.head_name, state.orig_head, "rebase (abort)")
        Handlers.set_head(state.head_name, "rebase (abort): returning to " .. state.head_name)
    else
        Handlers.update_ref("HEAD", state.orig_head, kind .. " (abort)")
    end
    if orig then
        repo.checkout_tree(orig.tree)
    end
    clear_step_files()
    repo.delete_file("ROGIT_SEQUENCER")
end

local function skip_step(kind)
    local state = load_state()
    if not state or state.kind ~= kind then
        error("error: no " .. kind .. " in progress", 0)
    end
    repo.checkout_tree(repo.head_tree())
    clear_step_files()
    state.current = nil
    run_sequence(state)
end

local function quit_sequence(kind)
    local state = load_state()
    if not state or state.kind ~= kind then
        error("error: no " .. kind .. " in progress", 0)
    end
    clear_step_files()
    repo.delete_file("ROGIT_SEQUENCER")
end

--// Commands handling --continue/--abort/--skip/--quit the same way
local function handle_control(kind, arg)
    if arg == "--continue" then continue_sequence(kind) return true end
    if arg == "--abort" then abort_sequence(kind) return true end
    if arg == "--skip" then skip_step(kind) return true end
    if arg == "--quit" then quit_sequence(kind) return true end
    return false
end

local function ensure_idle()
    local op = repo.operation_in_progress()
    if op then
        error("error: a " .. op .. " is already in progress\nhint: try \"git " .. op .. " --continue\" or \"git " .. op .. " --abort\"", 0)
    end
    if #repo.read_conflicts() > 0 then
        error("error: you need to resolve your current conflicts first.", 0)
    end
end

--[[
Expands "A..B" into the commits reachable from B but not A, oldest first. A single revision is just itself.
]]
local function expand_revisions(revs)
    local list = {}
    for _, rev in ipairs(revs) do
        local from, to = rev:match("^(.-)%.%.(.+)$")
        if from then
            local exclude = Handlers.ancestors(Handlers.resolve_revision(from == "" and "HEAD" or from) or "")
            local tip = Handlers.resolve_revision(to)
            if not tip then error("fatal: bad revision '" .. to .. "'", 0) end
            local range = {}
            local seen = {}
            local function visit(sha)
                if seen[sha] or exclude[sha] then return end
                seen[sha] = true
                local commit = Handlers.read_commit(sha)
                if not commit then return end
                for _, parent in ipairs(commit.parents) do visit(parent) end
                table.insert(range, sha)
            end
            visit(tip)
            for _, sha in ipairs(range) do table.insert(list, sha) end
        else
            local sha = Handlers.resolve_revision(rev)
            if not sha then error("fatal: bad revision '" .. rev .. "'", 0) end
            table.insert(list, sha)
        end
    end
    return list
end

--[[
cherry-pick and revert: same options, different direction.
]]
local function pick_command(kind)
    return function(...)
        repo.require_root()
        local tuple = {...}
        local opts = {}
        local revs = {}

        local i = 1
        while i <= #tuple do
            local arg = tuple[i]
            if handle_control(kind, arg) then
                return
            elseif arg == "-n" or arg == "--no-commit" then
                opts.no_commit = true
            elseif arg == "-x" then
                opts.record_origin = true
            elseif (arg == "-m" or arg == "--mainline") and tuple[i + 1] then
                opts.mainline = tonumber(tuple[i + 1])
                i += 1
            elseif (arg == "-X" or arg == "--strategy-option") and tuple[i + 1] then
                opts.prefer = tuple[i + 1]
                i += 1
            elseif arg:match("^%-X(%a+)$") then
                opts.prefer = arg:match("^%-X(%a+)$")
            elseif arg == "--no-edit" or arg == "-e" or arg == "--edit" then
                --// there is no editor, messages are never edited
            elseif arg:sub(1, 1) ~= "-" then
                table.insert(revs, arg)
            end
            i += 1
        end

        if #revs == 0 then
            error("usage: git " .. kind .. " [<options>] <commit-ish>...\n   or: git " .. kind .. " (--continue | --skip | --abort | --quit)", 0)
        end

        ensure_idle()
        local head = repo.head_sha()
        if not head then
            error("fatal: your current branch does not have any commits yet", 0)
        end
        if not opts.no_commit then
            repo.ensure_clean(kind)
        end

        repo.save_orig_head()
        local state = {
            kind = kind,
            todo = expand_revisions(revs),
            done = {},
            orig_head = head,
            opts = opts,
        }
        run_sequence(state)
    end
end

arguments.createArgument("git", "cherry-pick", "", pick_command("cherry-pick"))
arguments.createArgument("git", "revert", "", pick_command("revert"))

--[[
commands:
rebase

Replays the commits of the current branch on top of another one.
]]
arguments.createArgument("git", "rebase", "", function(...)
    repo.require_root()
    local tuple = {...}
    local opts = {}
    local onto_rev = nil
    local positional = {}
    local interactive, exec_after = false, nil

    local i = 1
    while i <= #tuple do
        local arg = tuple[i]
        if handle_control("rebase", arg) then
            return
        elseif arg == "--onto" and tuple[i + 1] then
            onto_rev = tuple[i + 1]
            i += 1
        elseif (arg == "-X" or arg == "--strategy-option") and tuple[i + 1] then
            opts.prefer = tuple[i + 1]
            i += 1
        elseif arg:match("^%-X(%a+)$") then
            opts.prefer = arg:match("^%-X(%a+)$")
        elseif arg == "-i" or arg == "--interactive" then
            interactive = true
        elseif arg == "--root" then
            error("fatal: --root isn't supported by roGit, rebase onto a commit instead (e.g. git rebase -i <first commit>)", 0)
        elseif (arg == "-x" or arg == "--exec") and tuple[i + 1] then
            exec_after = tuple[i + 1]
            i += 1
        elseif arg:sub(1, 1) ~= "-" then
            table.insert(positional, arg)
        end
        i += 1
    end

    ensure_idle()

    local head = repo.head_sha()
    if not head then
        error("fatal: your current branch does not have any commits yet", 0)
    end

    local branch = Handlers.get_current_branch()
    if positional[2] then
        --// git rebase <upstream> <branch>: switch to <branch> first
        arguments.execute("git", "switch", positional[2])
        branch = Handlers.get_current_branch()
        head = repo.head_sha()
    end

    local upstream_rev = positional[1]
    if not upstream_rev then
        local remote, remote_branch, configured = repo.get_upstream(branch)
        if not configured and not Handlers.get_ref("refs/remotes/" .. tostring(remote) .. "/" .. tostring(remote_branch)) then
            error("There is no tracking information for the current branch.\nPlease specify which branch you want to rebase against.", 0)
        end
        upstream_rev = remote .. "/" .. remote_branch
    end

    local upstream = Handlers.resolve_revision(upstream_rev)
    if not upstream then
        error("fatal: invalid upstream '" .. upstream_rev .. "'", 0)
    end
    local onto = onto_rev and Handlers.resolve_revision(onto_rev) or upstream
    if not onto then
        error("fatal: Does not point to a valid commit: '" .. tostring(onto_rev) .. "'", 0)
    end

    repo.ensure_clean("rebase")

    --// commits that are ours only, oldest first (merge commits are dropped)
    local exclude = Handlers.ancestors(upstream)
    local commits = {}
    local seen = {}
    local function visit(sha)
        if seen[sha] or exclude[sha] then return end
        seen[sha] = true
        local commit = Handlers.read_commit(sha)
        if not commit then return end
        for _, parent in ipairs(commit.parents) do visit(parent) end
        if #commit.parents <= 1 then
            table.insert(commits, sha)
        end
    end
    visit(head)

    local head_name = branch and ("refs/heads/" .. branch) or nil

    hooks.run_blocking("pre-rebase", {args = {upstream_rev, branch}})

    --// the todo list: picks, or whatever the user turned it into
    local steps = {}
    for _, sha in ipairs(commits) do
        table.insert(steps, {cmd = "pick", sha = sha})
        if exec_after then
            table.insert(steps, {cmd = "exec", arg = exec_after})
        end
    end

    if interactive then
        if #commits == 0 then
            steps = {}
        end
        local lines = {}
        for _, step in ipairs(steps) do
            if step.cmd == "pick" then
                local commit = Handlers.read_commit(step.sha)
                table.insert(lines, "pick " .. short(step.sha) .. " " .. subject_of(commit))
            else
                table.insert(lines, "exec " .. step.arg)
            end
        end
        if #lines == 0 then table.insert(lines, "noop") end
        local c = editor.COMMENT
        local help = {
            "",
            c .. " Rebase " .. short(upstream) .. ".." .. short(head) .. " onto " .. short(onto) .. " (" .. #steps .. " command" .. (#steps == 1 and "" or "s") .. ")",
            c,
            c .. " Commands:",
            c .. " p, pick <commit> = use commit",
            c .. " r, reword <commit> = use commit, but edit the commit message",
            c .. " e, edit <commit> = use commit, but stop for amending",
            c .. " s, squash <commit> = use commit, but meld into previous commit",
            c .. " f, fixup <commit> = like \"squash\" but keep only the previous commit's log message",
            c .. " x, exec <command> = run a git command (e.g. exec git status)",
            c .. " b, break = stop here (continue rebase later with 'git rebase --continue')",
            c .. " d, drop <commit> = remove commit",
            c,
            c .. " These lines can be re-ordered; they are executed from top to bottom.",
            c,
            c .. " If you remove a line here THAT COMMIT WILL BE LOST.",
            c,
            c .. " However, if you remove everything, the rebase will be aborted.",
        }
        local text = editor.edit(table.concat(lines, "\n") .. "\n" .. table.concat(help, "\n") .. "\n", "git-rebase-todo")

        local ALIASES = {p = "pick", r = "reword", e = "edit", s = "squash", f = "fixup", x = "exec", b = "break", d = "drop"}
        steps = {}
        for line in (text .. "\n"):gmatch("([^\n]*)\n") do
            line = line:match("^%s*(.-)%s*$")
            if line ~= "" and line:sub(1, #c) ~= c and line:sub(1, 1) ~= "#" and line ~= "noop" then
                local word, rest = line:match("^(%S+)%s*(.*)$")
                local cmd = ALIASES[word] or word
                if cmd == "exec" then
                    table.insert(steps, {cmd = "exec", arg = rest})
                elseif cmd == "break" then
                    table.insert(steps, {cmd = "break"})
                elseif cmd == "pick" or cmd == "reword" or cmd == "edit" or cmd == "squash" or cmd == "fixup" or cmd == "drop" then
                    local ref = rest:match("^(%S+)")
                    local sha = ref and Handlers.resolve_revision(ref)
                    if not sha then
                        error("error: invalid line: " .. line .. "\nYou can fix this with 'git rebase --edit-todo' after aborting... (nothing was changed)", 0)
                    end
                    if (cmd == "squash" or cmd == "fixup") and #steps == 0 then
                        error("error: cannot '" .. cmd .. "' without a previous commit", 0)
                    end
                    if cmd ~= "drop" then
                        table.insert(steps, {cmd = cmd, sha = sha})
                    end
                else
                    error("error: invalid command '" .. tostring(word) .. "' in: " .. line, 0)
                end
            end
        end
        if #steps == 0 then
            print("Nothing to do")
            return
        end
    end

    if #commits == 0 and not interactive then
        if repo.is_ancestor(onto, head) then
            print("Current branch " .. (branch or "HEAD") .. " is up to date.")
            return
        end
        --// nothing of our own: just move to onto
        repo.save_orig_head()
        Handlers.update_ref("HEAD", onto, "rebase (finish): " .. (head_name or "HEAD") .. " onto " .. onto)
        repo.checkout_tree(Handlers.read_commit(onto).tree)
        print("Successfully rebased and updated " .. (head_name or "HEAD") .. ".")
        return
    end

    if not interactive and not exec_after and onto == upstream and Handlers.merge_base(head, onto) == onto then
        print("Current branch " .. (branch or "HEAD") .. " is up to date.")
        return
    end

    repo.save_orig_head()
    local state = {
        kind = "rebase",
        todo = steps,
        done = {},
        orig_head = head,
        head_name = head_name,
        onto = onto,
        opts = opts,
    }
    save_state(state)

    Handlers.set_head(onto, "rebase (start): checkout " .. upstream_rev)
    repo.checkout_tree(Handlers.read_commit(onto).tree)
    run_sequence(state)
end)

--[[
commands:
reflog

Where HEAD (or a branch) has been. Entries can be used as revisions: HEAD@{2}.
]]
arguments.createArgument("git", "reflog", "", function(...)
    repo.require_root()
    local ref = "HEAD"
    local limit = nil
    local tuple = {...}
    local i = 1
    while i <= #tuple do
        local arg = tuple[i]
        if arg == "show" then
            --// default action
        elseif arg == "-n" and tuple[i + 1] then
            limit = tonumber(tuple[i + 1])
            i += 1
        elseif arg:match("^%-(%d+)$") then
            limit = tonumber(arg:match("^%-(%d+)$"))
        elseif arg:sub(1, 1) ~= "-" then
            ref = arg
        end
        i += 1
    end

    local name = ref
    local log_ref = ref == "HEAD" and "HEAD" or (ref:match("^refs/") and ref or ("refs/heads/" .. ref))
    for n, entry in ipairs(Handlers.read_reflog(log_ref)) do
        if limit and n > limit then break end
        print(string.format("\27[33m%s\27[0m %s@{%d}: %s", short(entry.new), name, n - 1, entry.message))
    end
end)

--[[
commands:
bisect

Binary search for the commit that introduced a bug.
]]
local function load_bisect()
    local raw = repo.read_file("ROGIT_BISECT")
    if not raw then return nil end
    local ok, state = pcall(function() return HttpService:JSONDecode(raw) end)
    return ok and state or nil
end

local function save_bisect(state)
    repo.write_file("ROGIT_BISECT", HttpService:JSONEncode(state))
end

local function bisect_next(state)
    if not state.bad or #state.good == 0 then
        if not state.bad then print("status: waiting for both good and bad commits") end
        if state.bad and #state.good == 0 then print("status: waiting for good commit(s), bad commit known") end
        return
    end

    --// candidates: reachable from bad, not from any good
    local excluded = {}
    for _, good in ipairs(state.good) do
        for sha in pairs(Handlers.ancestors(good)) do excluded[sha] = true end
    end
    local candidates = {}
    for sha in pairs(Handlers.ancestors(state.bad)) do
        if not excluded[sha] then candidates[sha] = true end
    end
    local skipped = {}
    for _, sha in ipairs(state.skip or {}) do skipped[sha] = true end

    local count = 0
    for _ in pairs(candidates) do count += 1 end
    if count <= 1 then
        local commit = Handlers.read_commit(state.bad)
        print(state.bad .. " is the first bad commit")
        print("commit " .. state.bad)
        print("Author: " .. ((commit.author or ""):match("^(.-) %d+ [+-]%d+$") or ""))
        print("")
        print("    " .. (commit.message:match("^[^\n]*") or ""))
        return
    end

    --// the commit that splits the candidates closest to half
    local best, bestScore = nil, math.huge
    for sha in pairs(candidates) do
        if not skipped[sha] and sha ~= state.bad then
            local below = 0
            for ancestor in pairs(Handlers.ancestors(sha)) do
                if candidates[ancestor] then below += 1 end
            end
            local score = math.abs(count - 2 * below)
            if score < bestScore or (score == bestScore and sha < best) then
                best, bestScore = sha, score
            end
        end
    end
    if not best then
        print("There are only 'skip'ped commits left to test.")
        return
    end

    local steps = math.max(0, math.floor(math.log(count, 2)))
    print(string.format("Bisecting: %d revisions left to test after this (roughly %d steps)", count // 2, steps))
    local commit = Handlers.read_commit(best)
    Handlers.set_head(best, "checkout: moving to " .. best)
    repo.checkout_tree(commit.tree)
    print("[" .. best .. "] " .. (commit.message:match("^[^\n]*") or ""))
end

arguments.createArgument("git", "bisect", "", function(...)
    repo.require_root()
    local tuple = {...}
    local sub = tuple[1]
    local state = load_bisect()

    if sub == "start" then
        if state then
            error("error: a bisect is already running, use 'git bisect reset' first", 0)
        end
        repo.ensure_clean("bisect")
        state = {
            orig_head = repo.head_sha(),
            head_name = Handlers.get_current_branch(),
            bad = nil,
            good = {},
            skip = {},
        }
        if tuple[2] then state.bad = Handlers.resolve_revision(tuple[2]) end
        for i = 3, #tuple do
            local good = Handlers.resolve_revision(tuple[i])
            if good then table.insert(state.good, good) end
        end
        save_bisect(state)
        bisect_next(state)
        return
    end

    if not state then
        error("You need to start by \"git bisect start\"", 0)
    end

    if sub == "bad" or sub == "new" then
        state.bad = Handlers.resolve_revision(tuple[2] or "HEAD")
    elseif sub == "good" or sub == "old" then
        for i = 2, math.max(2, #tuple) do
            table.insert(state.good, Handlers.resolve_revision(tuple[i] or "HEAD"))
        end
    elseif sub == "skip" then
        table.insert(state.skip, Handlers.resolve_revision(tuple[2] or "HEAD"))
    elseif sub == "reset" then
        local target = tuple[2] and Handlers.resolve_revision(tuple[2]) or state.orig_head
        if state.head_name and not tuple[2] then
            Handlers.set_head("refs/heads/" .. state.head_name, "checkout: moving to " .. state.head_name)
        else
            Handlers.set_head(target, "checkout: moving to " .. target)
        end
        local commit = Handlers.read_commit(target)
        if commit then repo.checkout_tree(commit.tree) end
        repo.delete_file("ROGIT_BISECT")
        print("Previous HEAD position was " .. short(repo.head_sha()))
        return
    elseif sub == "log" then
        print("# bad: " .. tostring(state.bad))
        for _, good in ipairs(state.good) do print("# good: " .. good) end
        for _, skip in ipairs(state.skip) do print("# skip: " .. skip) end
        return
    else
        error("usage: git bisect (start | bad | good | skip | reset | log)", 0)
    end

    save_bisect(state)
    bisect_next(state)
end)

return {}
