
--[[
The core `git` commands. Shared repository logic lives in libs/repo.lua,
the history/stash/inspection commands live in commands/.
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
local repo = require(script.Parent.libs.repo)
local editor = require(script.Parent.libs.editor)
local hooks = require(script.Parent.libs.hooks)
local output = require(script.Parent.libs.output)
local trace = require(script.Parent.libs.trace)


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
function git.replaceOutputCallback(callback, warncallback)
    --// errors are always real errors: the terminal catches them and prints them in red
    print = callback
    warn = warncallback
    output.set(callback, warncallback)
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

local read_last_index = repo.read_last_index
local make_signature = repo.make_signature
local create_commit = repo.create_commit
local collect_worktree_changes = repo.collect_worktree_changes
local is_ancestor_commit = repo.is_ancestor
local collect_untracked = repo.collect_untracked
local normalize_user_path = repo.normalize_user_path
local matches_filters = repo.matches_filters
local read_blob_content = repo.read_blob_content
local dirty_changes = repo.dirty_changes

--[[
Returns a combined table of all active working tree/index changes for the UI.
]]
git.get_changes = repo.get_changes


--// Terrain is expensive to read, so between commands it is only re-read after Studio records an edit.
--// Commands that look at or change the place always start from a fresh read (scripts can edit terrain silently).
local READ_ONLY_COMMANDS = {
    log = true, show = true, branch = true, br = true, tag = true, reflog = true, help = true, h = true, version = true,
    v = true, ["--version"] = true, config = true, remote = true, ["cat-file"] = true, ["ls-files"] = true, ["ls-tree"] = true,
    ["rev-parse"] = true, ["rev-list"] = true, ["show-ref"] = true, describe = true, shortlog = true, blame = true,
    grep = true, ["count-objects"] = true, ["merge-base"] = true, ["symbolic-ref"] = true, ["update-ref"] = true,
    fetch = true, push = true, credential = true, bisect = true,
}
arguments.onExecute = function(_, argument)
    if not READ_ONLY_COMMANDS[argument or ""] then
        instances.invalidate_terrain()
    end
end

--// rogit.trace (see libs/trace.lua)
arguments.onRun = function(depth, command, ...)
    if trace.enabled("run") then
        trace.log("run", "%sbuilt-in: %s", string.rep("  ", depth), trace.command_line(command, ...))
    end
end
bash.onContextChanged(function()
    if trace.enabled("context") then
        local context = bash.context
        trace.log("context", "now in %s", context and (context.kind .. " '" .. tostring(context.name) .. "' (" .. context.root:GetFullName() .. ")") or "the place")
    end
end)

--// hooks can run git commands and live where core.hooksPath says
hooks.run_git = function(...)
    return arguments.execute("git", ...)
end
hooks.config_path = function()
    return repo.get_config("core.hooksPath")
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
    print("git version " .. config.version .. " (roGit)")
end)
arguments.createArgument("git", "--version", function ()
    print("git version " .. config.version .. " (roGit)")
end)

--[[
Global options:
  git -C <worktree | submodule path | game> <command>   run the command in another worktree or a submodule
  git -c <name>=<value> <command>                       a config value just for this command
]]
arguments.createArgument("git", "-C", function(path, ...)
    if not path then
        error("error: switch `C' requires a value", 0)
    end
    local context = repo.context_for_path(path)
    if context == nil then
        error("fatal: cannot change to '" .. path .. "': not a worktree or submodule", 0)
    end
    return bash.withContext(context or nil, arguments.execute, "git", ...)
end)
arguments.createArgument("git", "-c", function(pair, ...)
    local key, value = (pair or ""):match("^([^=]+)=?(.*)$")
    if not key then
        error("error: switch `c' requires a value", 0)
    end
    if not pair:find("=", 1, true) then
        value = "true"
    end
    local previous = Auth.overrides[key]
    Auth.overrides[key] = value
    local results = table.pack(pcall(arguments.execute, "git", ...))
    Auth.overrides[key] = previous
    if not results[1] then
        error(results[2], 0)
    end
end)
for _, flag in ipairs({"--no-pager", "-P", "--paginate", "--no-replace-objects", "--no-optional-locks"}) do
    arguments.createArgument("git", flag, function(...)
        return arguments.execute("git", ...)
    end)
end

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
            commit = "git-commit - Record changes to the repository.\n\nUsage: git commit [-a] [-m <msg>] [--amend] [--allow-empty] [-S] [-n]\n\n    -m, --message <msg>   commit message (without it, a script opens in Studio to write one)\n    -a, --all             stage all changes first\n    --amend               replace the last commit\n    -e, --edit            edit the message in the editor script\n    -S, --gpg-sign        sign the commit (see git signing-key)\n    -n, --no-verify       skip the pre-commit and commit-msg hooks",
            push = "git-push - Update remote refs along with associated objects.\n\nUsage: git push [<options>] [<repository> [<refspec>...]]\n\n    -u, --set-upstream    set upstream for git pull/status\n    -f, --force           allow non-fast-forward updates\n    --all                 push all branches\n    --tags                push all tags\n    -d, --delete          delete the given remote refs",
            pull = "git-pull - Fetch from and integrate with another repository or a local branch.\n\nUsage: git pull [<options>] [<repository> [<branch>]]\n\n    --ff-only             refuse to merge, only fast-forward\n    -X ours|theirs        settle merge conflicts in favour of one side",
            status = "git-status - Show the working tree status.\n\nUsage: git status",
            branch = "git-branch - List, create, or delete branches.\n\nUsage: git branch [-a | -r] [-v]\n       git branch <branchname> [<start-point>]\n       git branch -d | -D <branchname>\n       git branch -m [<oldbranch>] <newbranch>",
            switch = "git-switch - Switch branches.\n\nUsage: git switch [<options>] <branch>\n\n    -c, --create <branch>  create and switch to a new branch\n    -d, --detach <commit>  switch to a commit in detached HEAD mode",
            clone = "git-clone - Clone a repository into a new directory.\n\nUsage: git clone [<options>] <repository>\n\n    -b, --branch <branch>  checkout <branch> instead of the remote's HEAD\n    --single-branch        only download the history of one branch\n    --recurse-submodules   also clone the submodules",
            fetch = "git-fetch - Download objects and refs from another repository.\n\nUsage: git fetch [<repository>]",
            reset = "git-reset - Reset current HEAD to the specified state.\n\nUsage: git reset [--soft | --mixed | --hard] [<commit>]\n\n    --hard       reset HEAD, index and working tree",
            rm = "git-rm - Remove files from the working tree and from the index.\n\nUsage: git rm [-r] <file>...",
            diff = "git-diff - Show changes between commits, the index and the place.\n\nUsage: git diff [--cached] [--stat | --name-only | --name-status] [<commit> [<commit>]] [-- <path>...]\n\nShows property changes of every modified instance, and a line diff for scripts.",
            show = "git-show - Show a commit and the instances it changed.\n\nUsage: git show [<commit>] [--name-only]",
            merge = "git-merge - Join two or more development histories together.\n\nUsage: git merge [--no-ff] [-m <msg>] [-X ours|theirs] <commit-or-branch>\n\nInstances changed on both sides are merged property by property, scripts line by line.\nIf something can't be merged the merge stops without changing anything.",
            mv = "git-mv - Move or rename a file, a directory, or a symlink.\n\nUsage: git mv <source> <destination>",
            restore = "git-restore - Restore working tree files.\n\nUsage: git restore <pathspec>",
            remote = "git-remote - Manage set of tracked repositories.\n\nUsage: git remote [-v | --verbose]\n       git remote add [-f] <name> <url>\n       git remote remove <name>\n       git remote set-url <name> <newurl>",
            init = "git-init - Create an empty Git repository or reinitialize an existing one.\n\nUsage: git init [-q | --quiet] [-b <branch-name>]",
            log = "git-log - Show commit logs.\n\nUsage: git log [--oneline] [--graph] [--all] [-n <number>] [-p | --stat | --name-status]\n               [--author=<name>] [--grep=<text>] [--format=<format>] [--reverse] [<revision range>] [-- <path>...]",
            doctor = "git-doctor - Check what roGit cannot store.\n\nUsage: git doctor [-v]\n\nScans every tracked instance and lists property types, instances and data roGit can't save.",
            tag = "git-tag - Create, list, delete tags.\n\nUsage: git tag [-l [<pattern>]]\n       git tag [-a | -s] [-m <msg>] <tagname> [<commit>]\n       git tag -d <tagname>\n\n    -s, --sign    make a signed tag (see git signing-key)",
            config = "git-config - Get and set repository or global options.\n\nUsage: git config [--global] <name> [<value>]",
            version = "git-version - Show the RoGit version information.\n\nUsage: git version",
            credential = "git-credential - Prompt for and cache user credentials.\n\nUsage: git credential (fill|approve|reject)",
            stash = "git-stash - Stash the changes in a dirty working directory away.\n\nUsage: git stash [push [-u] [-m <message>]]\n       git stash list | show [-p] [<stash>]\n       git stash pop | apply | drop [<stash>]\n       git stash branch <branchname> [<stash>]\n       git stash clear",
            ["cherry-pick"] = "git-cherry-pick - Apply the changes introduced by some existing commits.\n\nUsage: git cherry-pick [-n] [-x] [-m <parent>] [-X ours|theirs] <commit>...\n       git cherry-pick (--continue | --skip | --abort | --quit)",
            bisect = "git-bisect - Use binary search to find the commit that introduced a bug.\n\nUsage: git bisect start [<bad> [<good>...]]\n       git bisect (bad | good | skip) [<rev>]\n       git bisect reset | log",
            revert = "git-revert - Revert some existing commits.\n\nUsage: git revert [-n] [-m <parent>] <commit>...\n       git revert (--continue | --skip | --abort | --quit)",
            rebase = "git-rebase - Reapply commits on top of another base tip.\n\nUsage: git rebase [-i] [-x <git command>] [-X ours|theirs] [--onto <newbase>] [<upstream> [<branch>]]\n       git rebase (--continue | --skip | --abort | --quit)\n\n    -i, --interactive   edit the todo list (pick, reword, edit, squash, fixup, exec, break, drop) in a Studio script",
            reflog = "git-reflog - Show where HEAD (or a branch) has been.\n\nUsage: git reflog [show] [-n <number>] [<ref>]\n\nEntries can be used as revisions, e.g. git reset --hard HEAD@{1}",
            clean = "git-clean - Remove untracked instances.\n\nUsage: git clean [-n] [-f] [<path>...]",
            grep = "git-grep - Search script sources.\n\nUsage: git grep [-i] [-n] [-c] [-l] [-v] [-w] [-E] <pattern> [<rev>] [-- <path>...]\n\nPatterns are plain text; -E makes them Lua patterns.",
            blame = "git-blame - Show what revision and author last modified each line of a script.\n\nUsage: git blame [<rev>] [--] <path>",
            describe = "git-describe - Give an object a human readable name based on a tag.\n\nUsage: git describe [--tags] [--always] [--long] [<commit>]",
            shortlog = "git-shortlog - Summarize git log output.\n\nUsage: git shortlog [-s] [-n] [-e] [<revision range>]",
            ["cat-file"] = "git-cat-file - Show the content or type of objects.\n\nUsage: git cat-file (-t | -s | -e | -p) <object>   (<object> may be <rev>:<path>)",
            ["ls-files"] = "git-ls-files - Show tracked (or -o untracked, -m modified, -d deleted, -u unmerged) instances.\n\nUsage: git ls-files [-s] [-o] [-m] [-d] [-u] [<path>...]",
            ["ls-tree"] = "git-ls-tree - List the contents of a tree object.\n\nUsage: git ls-tree [-r] [--name-only] <tree-ish> [<path>]",
            ["rev-parse"] = "git-rev-parse - Resolve revisions.\n\nUsage: git rev-parse [--short] [--abbrev-ref] [--verify] <rev>...",
            ["rev-list"] = "git-rev-list - List commit objects in reverse chronological order.\n\nUsage: git rev-list [--count] [-n <n>] [--all] <commit>... [^<commit>] [<a>..<b>]",
            ["merge-base"] = "git-merge-base - Find a common ancestor for a merge.\n\nUsage: git merge-base [--is-ancestor] <commit> <commit>",
            ["show-ref"] = "git-show-ref - List references.\n\nUsage: git show-ref [--heads] [--tags]",
            ["symbolic-ref"] = "git-symbolic-ref - Read or change HEAD.\n\nUsage: git symbolic-ref [--short] HEAD [<ref>]",
            ["update-ref"] = "git-update-ref - Update a ref safely.\n\nUsage: git update-ref [-d] <ref> [<commit>]",
            ["count-objects"] = "git-count-objects - Count stored objects.\n\nUsage: git count-objects",
            worktree = "git-worktree - Manage multiple working trees.\n\nUsage: git worktree add [-f] [--detach] [-b <new-branch>] <name> [<commit-ish>]\n       git worktree list [--porcelain]\n       git worktree lock [--reason <string>] <name> | unlock <name>\n       git worktree move <name> <new-name>\n       git worktree prune [-n] [-v]\n       git worktree remove [-f] <name>\n\nWorktrees are folders in ServerStorage/RoGitWorktrees. Work in one with git -C <name> <command> or 'cd <name>'.",
            submodule = "git-submodule - Initialize, update or inspect submodules.\n\nUsage: git submodule [status] [--cached] [--recursive]\n       git submodule add [-b <branch>] [--name <name>] <repository> <path>\n       git submodule init | update [--init] [--remote] [--recursive] [-f] [<path>...]\n       git submodule deinit [-f] (--all | <path>...)\n       git submodule foreach [--recursive] <git command>\n       git submodule sync | summary | set-url <path> <url> | set-branch -b <branch> <path>\n\nA submodule is a folder holding another roGit repository, pinned to a commit. Settings are in ServerStorage/.gitmodules.",
            hook = "git-hook - Manage hooks (ModuleScripts in .git/hooks).\n\nUsage: git hook list\n       git hook create <name>\n       git hook run <name> [-- <args>...]\n       git hook remove <name>\n\nA hook returns function(context); returning false (and a reason) stops the command.",
            ["signing-key"] = "git-signing-key - Manage the SSH key used to sign commits and tags.\n\nUsage: git signing-key generate [--force]\n       git signing-key import [<private key>]\n       git signing-key show | remove\n\nAdd the public key on GitHub as a Signing Key to get Verified commits. The key is kept in your plugin settings.",
            ["verify-commit"] = "git-verify-commit - Check the SSH signature of commits.\n\nUsage: git verify-commit <commit>...",
            ["verify-tag"] = "git-verify-tag - Check the SSH signature of tags.\n\nUsage: git verify-tag <tag>...",
            activity = "git-activity - Show the commands run in this place.\n\nUsage: git activity [-n <count> | --all] [--failed] [--author=<name>] [--grep=<text>] [--clear]\n\nTurn it off with git config rogit.activityLog false. For live tracing: git config --global rogit.trace true (or run, http, hook, context, perf).",
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
   clean     Remove untracked instances
   stash     Stash the changes in a dirty working directory away

examine the history and state (see also: git help revisions)
   diff      Show changes between commits, commit and working tree, etc
   log       Show commit logs
   show      Show a commit and the instances it changed
   status    Show the working tree status
   grep      Search script sources
   blame     Show who last changed each line of a script
   reflog    Show where HEAD has been
   bisect    Use binary search to find the commit that introduced a bug

grow, mark and tweak your common history
   branch    List, create, or delete branches
   checkout  Switch branches or restore working tree files
   commit    Record changes to the repository
   switch    Switch branches
   merge     Join two or more development histories together
   tag       Create, list, delete tags
   rebase    Reapply commits on top of another base tip
   reset     Reset current HEAD to the specified state
   cherry-pick  Apply the changes introduced by some existing commits
   revert    Revert some existing commits

collaborate (see also: git help workflows)
   fetch     Download objects and refs from another repository
   pull      Fetch from and integrate with another repository or a local branch
   push      Update remote refs along with associated objects
   remote    Manage set of tracked repositories

Other commands:
   init      Create an empty Git repository or reinitialize an existing one
   config    Get and set repository or global options
   doctor    Check what roGit cannot store in this place
   worktree  Manage multiple working trees
   submodule Initialize, update or inspect submodules
   hook      Manage hooks
   signing-key, verify-commit, verify-tag   Signed commits and tags
   activity  Show the commands run in this place (see also rogit.trace)
   describe, shortlog, cat-file, ls-files, ls-tree, rev-parse, rev-list,
   merge-base, show-ref, symbolic-ref, update-ref, count-objects

'git help -a' and 'git help -g' list available subcommands and some
concept guides. See 'git help <command>' or 'git help <concept>'
to read about a specific subcommand or concept.
See 'git help git' for an overview of the system.]=])
end)

--// commands/inspect.lua registers commands itself, so it can only be loaded once `git` exists
local function inspect()
    return require(script.Parent.commands.inspect)
end

--[[
What the place currently holds for an index path (serialized), nil when the instance is gone.
]]
--[[
Compares two indexes. `new` may be the string "worktree" (the live place, for the paths in `tracked`).
Returns a sorted list of {path, status = A/M/D, old_sha, new_sha, new_content}.
]]
local function compare_indexes(old, new, tracked, filters)
    local entries = {}
    if new == "worktree" then
        local paths, seen = {}, {}
        for path in pairs(old) do seen[path] = true table.insert(paths, path) end
        for path in pairs(tracked) do if not seen[path] then table.insert(paths, path) end end
        for _, path in ipairs(paths) do
            if matches_filters(path, filters) then
                Utilities.roYield()
                local old_entry = old[path]
                local live = Utilities.parse_path(repo.entity_of(path))
                if live and Handlers.is_submodule(live) then
                    --// a submodule is compared by the commit it is at
                    local head = Handlers.submodule_head(live)
                    if head and (not old_entry or old_entry.sha ~= head) then
                        table.insert(entries, {path = path, status = old_entry and "M" or "A", old_sha = old_entry and old_entry.sha, new_sha = head, gitlink = true})
                    end
                    continue
                end
                local content = live and instances.serialize_instance(live) or nil
                if not content then
                    if old_entry then table.insert(entries, {path = path, status = "D", old_sha = old_entry.sha}) end
                else
                    local sha = compute_blob_sha(content)
                    if not old_entry then
                        table.insert(entries, {path = path, status = "A", new_sha = sha, new_content = content})
                    elseif old_entry.sha ~= sha then
                        table.insert(entries, {path = path, status = "M", old_sha = old_entry.sha, new_sha = sha, new_content = content})
                    end
                end
            end
        end
    else
        for path, data in pairs(new) do
            if matches_filters(path, filters) then
                if not old[path] then
                    table.insert(entries, {path = path, status = "A", new_sha = data.sha, gitlink = data.mode == "160000"})
                elseif old[path].sha ~= data.sha then
                    table.insert(entries, {path = path, status = "M", old_sha = old[path].sha, new_sha = data.sha, gitlink = data.mode == "160000"})
                end
            end
        end
        for path, data in pairs(old) do
            if matches_filters(path, filters) and not new[path] then
                table.insert(entries, {path = path, status = "D", old_sha = data.sha, gitlink = data.mode == "160000"})
            end
        end
    end
    table.sort(entries, function(x, y) return x.path < y.path end)
    return entries
end

--[[
Prints compare_indexes() results. format: "patch" (default), "stat", "name-only", "name-status".
]]
local function print_changes(entries, format)
    local colors = {A = "\27[32m", M = "\27[33m", D = "\27[31m"}
    if format == "stat" then
        for _, entry in ipairs(entries) do
            print(string.format(" %s | %s", entry.path, entry.status == "A" and "new" or (entry.status == "D" and "deleted" or "changed")))
        end
        if #entries > 0 then
            print(string.format(" %d file%s changed", #entries, #entries == 1 and "" or "s"))
        end
        return
    end
    for _, entry in ipairs(entries) do
        if format == "name-only" then
            print(entry.path)
        elseif format == "name-status" then
            print(entry.status .. "\t" .. entry.path)
        else
            print(colors[entry.status] .. entry.status .. "\27[0m  " .. entry.path)
            if entry.gitlink then
                if entry.old_sha then print("\27[31m-Subproject commit " .. entry.old_sha .. "\27[0m") end
                if entry.new_sha then print("\27[32m+Subproject commit " .. entry.new_sha .. "\27[0m") end
                continue
            end
            local old = entry.old_sha and read_blob_content(entry.old_sha) or nil
            local new = entry.new_content or (entry.new_sha and read_blob_content(entry.new_sha)) or nil
            if entry.status ~= "D" then
                for _, line in ipairs(diff.describe(old, new)) do
                    print(line)
                end
            end
        end
    end
end

git.compare_indexes = compare_indexes
git.print_changes = print_changes

--[[
commands:
diff

git diff                      the place vs the index
git diff --cached [<commit>]  the index vs HEAD (or <commit>)
git diff <commit>             the place vs <commit>
git diff <a> <b> / <a>..<b>   two commits (a...b: from their merge base)
Shows property level changes, and a line diff for scripts.
]]
arguments.createArgument("git", "diff", "", function(...)
    repo.require_root()
    Handlers.load_ignore_patterns()

    local cached = false
    local format = "patch"
    local filters = {}
    local revs = {}
    local after_dashes = false
    for _, arg in ipairs({...}) do
        if after_dashes then
            table.insert(filters, normalize_user_path(arg))
        elseif arg == "--" then
            after_dashes = true
        elseif arg == "--cached" or arg == "--staged" then
            cached = true
        elseif arg == "--name-only" then
            format = "name-only"
        elseif arg == "--name-status" then
            format = "name-status"
        elseif arg == "--stat" or arg == "--shortstat" or arg == "--numstat" then
            format = "stat"
        elseif arg:sub(1, 1) ~= "-" then
            local from, dots, to = arg:match("^(.-)(%.%.%.?)(.*)$")
            if from and (Handlers.resolve_revision(from ~= "" and from or "HEAD")) then
                local a = Handlers.resolve_revision(from ~= "" and from or "HEAD")
                local b = Handlers.resolve_revision(to ~= "" and to or "HEAD")
                if dots == "..." then a = Handlers.merge_base(a, b) or a end
                table.insert(revs, a)
                table.insert(revs, b)
            elseif #filters == 0 and Handlers.resolve_revision(arg) and not Utilities.parse_path(arg) then
                table.insert(revs, Handlers.resolve_revision(arg))
            else
                table.insert(filters, normalize_user_path(arg))
            end
        end
    end

    local function tree_of(sha)
        local commit = Handlers.read_commit(sha)
        if not commit then error("fatal: bad revision '" .. tostring(sha) .. "'", 0) end
        return repo.tree_index(commit.tree)
    end

    local index = Handlers.read_index()
    local entries
    if #revs >= 2 then
        entries = compare_indexes(tree_of(revs[1]), tree_of(revs[2]), nil, filters)
    elseif cached then
        local base = revs[1] and tree_of(revs[1]) or read_last_index()
        entries = compare_indexes(base, index, nil, filters)
    elseif revs[1] then
        entries = compare_indexes(tree_of(revs[1]), "worktree", index, filters)
    else
        entries = compare_indexes(index, "worktree", {}, filters)
    end

    print_changes(entries, format)
end)

local function print_dirty_abort(_dirty, action)
    repo.ensure_clean(action)
end

--[[
Fails when a merge/cherry-pick/revert/rebase is still waiting to be concluded.
]]
local function ensure_no_operation()
    local op = repo.operation_in_progress()
    if op == "merge" then
        error("fatal: You have not concluded your merge (MERGE_HEAD exists).\nPlease, commit your changes before you merge.", 0)
    elseif op then
        error("fatal: a " .. op .. " is in progress. Finish it with 'git " .. op .. " --continue' or cancel it with 'git " .. op .. " --abort'.", 0)
    end
    if #repo.read_conflicts() > 0 then
        error("error: you need to resolve your current conflicts first.", 0)
    end
end

--[[
Merges the commit `target_sha` into the current branch.
Fast-forwards when possible, otherwise performs a three-way merge of the instances and creates a merge commit.
On conflicts the place is left half merged (like git): resolve, `git add`, then `git commit` (or `git merge --abort`).

opts: prefer ("ours" | "theirs"), no_ff, ff_only, no_commit, squash, message, name (shown in conflict markers)
]]
local function perform_merge(target_sha, label, opts)
    opts = opts or {}
    ensure_no_operation()

    local head_sha = repo.head_sha()
    local target_commit = Handlers.read_commit(target_sha)
    assert(target_commit and target_commit.tree, "fatal: " .. tostring(target_sha) .. " is not a commit we have locally")
    local name = opts.name or label

    if head_sha and (head_sha == target_sha or is_ancestor_commit(target_sha, head_sha)) then
        print("Already up to date.")
        return true
    end

    repo.ensure_clean("merge")

    if not head_sha or (is_ancestor_commit(head_sha, target_sha) and not opts.no_ff and not opts.squash) then
        print(string.format("Updating %s..%s", string.sub(head_sha or "0000000", 1, 7), string.sub(target_sha, 1, 7)))
        repo.save_orig_head()
        Handlers.update_ref("HEAD", target_sha, "merge " .. name .. ": Fast-forward")
        repo.checkout_tree(target_commit.tree)
        print("Fast-forward")
        hooks.notify("post-merge", {args = {"0"}})
        return true
    end

    if opts.ff_only then
        error("fatal: Not possible to fast-forward, aborting.", 0)
    end

    local base_sha = Handlers.merge_base(head_sha, target_sha)
    local base_commit = base_sha and Handlers.read_commit(base_sha)
    local message = opts.message or ("Merge " .. label)

    repo.save_orig_head()
    local tree_sha = repo.three_way(base_commit and base_commit.tree, target_commit.tree, {
        prefer = opts.prefer,
        ours_label = "HEAD",
        theirs_label = name,
    })

    if not tree_sha then
        if not opts.squash then
            repo.write_file("MERGE_HEAD", target_sha)
        end
        repo.write_file("MERGE_MSG", message)
        error("Automatic merge failed; fix conflicts and then commit the result.", 0)
    end

    if opts.squash or opts.no_commit then
        repo.checkout_tree(tree_sha)
        if opts.squash then
            repo.write_file("MERGE_MSG", "Squashed commit of the following:\n\n" .. target_sha .. " " .. target_commit.message)
            print("Squash commit -- not updating HEAD")
        else
            repo.write_file("MERGE_HEAD", target_sha)
            repo.write_file("MERGE_MSG", message)
            print("Automatic merge went well; stopped before committing as requested")
        end
        return true
    end

    if not opts.no_verify then
        hooks.run_blocking("pre-merge-commit")
    end
    if opts.edit then
        message = editor.message(message, {
            "Please enter a commit message to explain why this merge is necessary,",
            "especially if it merges an updated upstream into a topic branch.",
            "",
            "Lines starting with '--' will be ignored, and an empty message aborts",
            "the commit.",
        }, "MERGE_MSG")
        if message == "" then
            error("Not committing merge; use 'git commit' to complete the merge.", 0)
        end
    end
    create_commit(tree_sha, {head_sha, target_sha}, message, {reflog = "merge " .. name, sign = opts.sign})
    repo.checkout_tree(tree_sha)
    print("Merge made by the 'ort' strategy.")
    hooks.notify("post-merge", {args = {"0"}})
    return true
end

git.perform_merge = perform_merge
git.ensure_no_operation = ensure_no_operation

--[[
commands:
merge

Joins another branch (or commit) into the current branch.
Instances changed on both sides are merged property by property, scripts line by line.
]]
arguments.createArgument("git", "merge", "", function(...)
    repo.require_root()

    local tuple = {...}
    local rev = nil
    local opts = {}

    local i = 1
    while i <= #tuple do
        local arg = tuple[i]
        if arg == "--abort" or arg == "--quit" then
            if not repo.read_file("MERGE_HEAD") and #repo.read_conflicts() == 0 then
                error("fatal: There is no merge to abort (MERGE_HEAD missing).", 0)
            end
            if arg == "--abort" then
                repo.checkout_tree(repo.head_tree())
            end
            repo.clear_operation_state()
            return
        elseif arg == "--continue" then
            arguments.execute("git", "commit")
            return
        elseif arg == "--no-ff" then
            opts.no_ff = true
        elseif arg == "--ff-only" then
            opts.ff_only = true
        elseif arg == "--ff" then
            opts.no_ff = false
        elseif arg == "--no-commit" then
            opts.no_commit = true
        elseif arg == "--squash" then
            opts.squash = true
        elseif arg == "-e" or arg == "--edit" then
            opts.edit = true
        elseif arg == "--no-edit" then
            opts.edit = false
        elseif arg == "--no-verify" then
            opts.no_verify = true
        elseif arg == "-S" or arg == "--gpg-sign" then
            opts.sign = true
        elseif arg == "--no-gpg-sign" then
            opts.sign = false
        elseif (arg == "-m" or arg == "--message") and tuple[i + 1] then
            opts.message = tuple[i + 1]
            i += 1
        elseif (arg == "-X" or arg == "--strategy-option") and tuple[i + 1] then
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
        error("fatal: unknown strategy option '" .. opts.prefer .. "' (use ours or theirs)", 0)
    end

    if not rev then
        --// like merge.defaultToUpstream: merge the branch's upstream
        local branch = Handlers.get_current_branch()
        local remote, remote_branch = repo.get_upstream(branch)
        if branch and Handlers.get_ref("refs/remotes/" .. remote .. "/" .. remote_branch) then
            rev = remote .. "/" .. remote_branch
        else
            error("fatal: No remote for the current branch.", 0)
        end
    end

    local target_sha = Handlers.resolve_revision(rev)
    if not target_sha then
        error("merge: " .. rev .. " - not something we can merge", 0)
    end

    local label = (rev:find("/", 1, true) and Handlers.get_ref("refs/remotes/" .. rev)) and ("remote-tracking branch '" .. rev .. "'")
        or (Handlers.get_ref("refs/heads/" .. rev) and ("branch '" .. rev .. "'"))
        or (Handlers.get_ref("refs/tags/" .. rev) and ("tag '" .. rev .. "'"))
        or ("commit '" .. rev .. "'")
    opts.name = rev
    perform_merge(target_sha, label, opts)
end)

--[[
commands:
mv

Moves or renames an instance and updates the index.
]]
arguments.createArgument("git", "mv", "", function(...)
    repo.require_root()
    local positional = {}
    local dry_run, verbose = false, false
    for _, arg in ipairs({...}) do
        if arg == "-n" or arg == "--dry-run" then
            dry_run = true
        elseif arg == "-v" or arg == "--verbose" then
            verbose = true
        elseif arg ~= "-f" and arg ~= "--force" and arg ~= "-k" and arg ~= "--" then
            table.insert(positional, arg)
        end
    end
    if #positional < 2 then
        error("usage: git mv [<options>] <source>... <destination>", 0)
    end

    local destination = normalize_user_path(table.remove(positional))
    local index = Handlers.read_index()

    for _, source_arg in ipairs(positional) do
        local source = normalize_user_path(source_arg)
        local sourceObj = Utilities.parse_path(source)
        if not sourceObj then
            error("fatal: bad source, source=" .. source .. ", destination=" .. destination, 0)
        end
        local tracked = false
        for path in pairs(index) do
            if repo.matches_filters(path, {source}) then tracked = true break end
        end
        if not tracked then
            error("fatal: not under version control, source=" .. source .. ", destination=" .. destination, 0)
        end

        --// into an existing instance (keeping the name), or to a new name
        local destObj = Utilities.parse_path(destination)
        local newParent, newName
        if destObj then
            newParent, newName = destObj, sourceObj.Name
        else
            local parentPath, name = destination:match("^(.*)/([^/]+)$")
            newParent = parentPath and Utilities.parse_path(parentPath)
            newName = name and Utilities.unescape_name(name)
            if not newParent then
                error("fatal: destination directory does not exist, source=" .. source .. ", destination=" .. destination, 0)
            end
        end

        if verbose or dry_run then
            print("Renaming " .. source .. " to " .. destination)
        end
        if not dry_run then
            for path in pairs(table.clone(index)) do
                if repo.matches_filters(path, {source}) then index[path] = nil end
            end
            Handlers.write_index(index)

            sourceObj.Name = newName
            sourceObj.Parent = newParent
            local newPath = destObj and (destination .. "/" .. Utilities.escape_name(newName)) or destination
            arguments.execute("git", "add", newPath)
            index = Handlers.read_index()
        end
    end
end)

--[[
commands:
restore

Restores instances from the index (or --source), or with --staged restores the index from HEAD.
]]
arguments.createArgument("git", "restore", "", function(...)
    repo.require_root()
    local tuple = {...}
    local source_rev, staged, worktree = nil, false, false
    local filters = {}

    local i = 1
    while i <= #tuple do
        local arg = tuple[i]
        if (arg == "-s" or arg == "--source") and tuple[i + 1] then
            source_rev = tuple[i + 1]
            i += 1
        elseif arg:match("^%-%-source=") then
            source_rev = arg:match("^%-%-source=(.*)$")
        elseif arg == "-S" or arg == "--staged" then
            staged = true
        elseif arg == "-W" or arg == "--worktree" then
            worktree = true
        elseif arg == "-SW" or arg == "-WS" then
            staged, worktree = true, true
        elseif arg ~= "--" and arg:sub(1, 1) ~= "-" then
            table.insert(filters, arg == "." and "." or normalize_user_path(arg))
        end
        i += 1
    end
    if not staged then worktree = true end

    if #filters == 0 then
        error("fatal: you must specify path(s) to restore", 0)
    end

    local index = Handlers.read_index()
    local original_index = table.clone(index)
    local source
    if source_rev then
        local commit = Handlers.read_commit(Handlers.resolve_revision(source_rev))
        if not commit then
            error("fatal: could not resolve " .. source_rev, 0)
        end
        source = repo.tree_index(commit.tree)
    elseif staged then
        source = read_last_index()
    else
        source = index
    end

    local matched = 0
    if staged then
        for path in pairs(table.clone(index)) do
            if matches_filters(path, filters) and not source[path] then
                index[path] = nil
                matched += 1
            end
        end
        for path, data in pairs(source) do
            if matches_filters(path, filters) then
                index[path] = {sha = data.sha, mode = data.mode}
                matched += 1
            end
        end
        Handlers.write_index(index)
    end

    if worktree then
        matched += repo.restore_worktree(source, original_index, filters)
    end

    if matched == 0 then
        error("error: pathspec '" .. table.concat(filters, "', '") .. "' did not match any file(s) known to git", 0)
    end
end)

--[[
commands:
clean

Removes untracked instances.
]]
arguments.createArgument("git", "clean", "", function(...)
    repo.require_root()
    local force, dry_run, quiet = false, false, false
    local filters = {}
    for _, arg in ipairs({...}) do
        if arg:match("^%-[fdnqx]+$") then
            if arg:find("f") then force = true end
            if arg:find("n") then dry_run = true end
            if arg:find("q") then quiet = true end
        elseif arg == "--force" then
            force = true
        elseif arg == "--dry-run" then
            dry_run = true
        elseif arg ~= "--" and arg:sub(1, 1) ~= "-" then
            table.insert(filters, normalize_user_path(arg))
        end
    end

    if not force and not dry_run and repo.get_config("clean.requireForce") ~= "false" then
        error("fatal: clean.requireForce defaults to true and neither -i, -n, nor -f given; refusing to clean", 0)
    end

    Handlers.load_ignore_patterns()
    local untracked = collect_untracked(Handlers.read_index())
    local paths = {}
    for path in pairs(untracked) do
        local parent = path:match("^(.*)/[^/]+$")
        --// only the top-most untracked instance, its children go with it
        if not (parent and untracked[parent]) and matches_filters(path, filters) then
            table.insert(paths, path)
        end
    end
    table.sort(paths)

    for _, path in ipairs(paths) do
        if dry_run then
            print("Would remove " .. path)
        else
            if not quiet then print("Removing " .. path) end
            pcall(function() untracked[path]:Destroy() end)
        end
    end
end)

--[[
Commands:
add
a

Adds files to be commited
]]
arguments.createArgument("git", "add", "a", function (...)
    repo.require_root()
    Handlers.load_ignore_patterns()

    local args = {...}
    local dry_run = false
    local verbose = false
    local update_only = false
    local paths = {}

    for _, arg in ipairs(args) do
        if arg == "-f" or arg == "--force" or arg == "--" then
            --// accepted: ignored instances are never staged (they're not part of the tree at all)
        elseif arg == "-n" or arg == "--dry-run" then
            dry_run = true
        elseif arg == "-v" or arg == "--verbose" then
            verbose = true
        elseif arg == "-u" or arg == "--update" then
            update_only = true
        elseif arg == "-A" or arg == "--all" then
            table.insert(paths, ".")
        else
            table.insert(paths, arg)
        end
    end

    local index = Handlers.read_index()
    local before = table.clone(index)
    local seen_ids = {}

    local function report()
        if not (verbose or dry_run) then return end
        local names = {}
        for path, data in pairs(index) do
            if not before[path] or before[path].sha ~= data.sha then table.insert(names, "add '" .. path .. "'") end
        end
        for path in pairs(before) do
            if not index[path] then table.insert(names, "remove '" .. path .. "'") end
        end
        table.sort(names)
        for _, line in ipairs(names) do print(line) end
    end

    local function finish(resolved)
        report()
        if not dry_run then
            Handlers.write_index(index)
            repo.resolve_conflicts(resolved)
        end
    end

    --// git add -u: refresh what is tracked, never pick up new instances
    if update_only then
        local filters = {}
        for _, path in ipairs(paths) do table.insert(filters, normalize_user_path(path)) end
        for path in pairs(table.clone(index)) do
            if repo.matches_filters(path, filters) then
                Utilities.roYield()
                local currObj = Utilities.parse_path(repo.entity_of(path))
                if currObj then
                    index[path] = {mode = "100644", sha = Handlers.write_blob(instances.serialize_instance(currObj))}
                else
                    index[path] = nil
                end
            end
        end
        finish(#filters > 0 and filters or {"."})
        return
    end

    if #paths == 0 then
        print("Nothing specified, nothing added.")
        print("hint: Maybe you wanted to say 'git add .'?")
        return
    end

    local has_dot = false
    for _, p in ipairs(paths) do
        if p == "." or p == "*" or p == ":/" then
            has_dot = true
            break
        end
    end

    if has_dot then
        for path, _ in pairs(index) do
            for _, service in ipairs(bash.getTrackedRoots()) do
                if path == service.Name or path:sub(1, #service.Name + 1) == service.Name .. "/" then
                    index[path] = nil
                    break
                end
            end
        end

        for _, service in ipairs(bash.getTrackedRoots()) do
            if not Handlers.is_ignored_instance(service) then
                instances.stage_recursive(service, index, seen_ids)
            end
        end
        finish({"."})
        return
    end

    local resolved = {}
    for _, target in ipairs(paths) do
        local currObj, _, segments = Utilities.parse_path(target)
        local ownPath = segments and table.concat(segments, "/") or normalize_user_path(target)
        table.insert(resolved, ownPath)

        --// Restage the whole subtree: drop what the index knew about it (deleted children included)
        local known = false
        for path in pairs(index) do
            if path == ownPath or path:sub(1, #ownPath + 1) == ownPath .. "/" then
                index[path] = nil
                known = true
            end
        end

        if not currObj then
            --// staging a deletion is fine, a path nobody knows about isn't
            if not known then
                error("fatal: pathspec '" .. target .. "' did not match any files", 0)
            end
        else
            instances.stage_recursive(currObj, index, seen_ids, nil, #segments > 1 and ownPath or nil)

            --// The parents need an entry too (and one in the "has children" form), otherwise the tree would lose their class/properties
            for depth = 1, #segments - 1 do
                local ancestorPath = table.concat(segments, "/", 1, depth)
                local ancestor = Utilities.parse_path(ancestorPath)
                if ancestor and not index[ancestorPath .. "/.properties"] then
                    index[ancestorPath] = nil
                    instances.stage_instance(ancestor, index, seen_ids, ancestorPath)
                end
            end
        end
    end

    finish(resolved)
end)


--[[
commands:
pull

Fetches the latest commits and integrates them: fast-forwards when it can, otherwise merges (or rebases with --rebase).
]]
arguments.createArgument("git", "pull", "", function (...)
    repo.require_root()

    local positional = {}
    local opts = {}
    local rebase = repo.get_config("pull.rebase") == "true"
    local tuple = {...}
    local i = 1
    while i <= #tuple do
        local arg = tuple[i]
        if arg == "--ff-only" then
            opts.ff_only = true
        elseif arg == "--no-ff" then
            opts.no_ff = true
        elseif arg == "--rebase" or arg == "-r" then
            rebase = true
        elseif arg == "--no-rebase" then
            rebase = false
        elseif arg == "--squash" then
            opts.squash = true
        elseif arg == "--no-commit" then
            opts.no_commit = true
        elseif (arg == "-X" or arg == "--strategy-option") and tuple[i + 1] then
            opts.prefer = tuple[i + 1]
            i += 1
        elseif arg:match("^%-X(%a+)$") then
            opts.prefer = arg:match("^%-X(%a+)$")
        elseif arg:sub(1, 1) ~= "-" then
            table.insert(positional, arg)
        end
        i += 1
    end

    ensure_no_operation()

    local current_branch = Handlers.get_current_branch()
    local upstream_remote, upstream_branch = repo.get_upstream(current_branch)
    local remote_name = positional[1] or upstream_remote or "origin"
    local branch_name = positional[2] or (positional[1] == nil and upstream_branch) or current_branch or repo.default_branch()

    local refs = Remote.fetch(remote_name)
    local remoteSha = refs["refs/heads/" .. branch_name]
    assert(remoteSha, "fatal: couldn't find remote ref 'refs/heads/" .. branch_name .. "'")

    local remote_ref = remote_name .. "/" .. branch_name
    Handlers.update_ref("refs/remotes/" .. remote_ref, remoteSha, "pull")

    local remote_commit = Handlers.read_commit(remoteSha)
    assert(remote_commit and remote_commit.tree, "fatal: the remote commit " .. remoteSha .. " was not downloaded")

    local head_sha = repo.head_sha()
    if not head_sha then
        --// nothing local yet: just take theirs
        perform_merge(remoteSha, "branch '" .. branch_name .. "' of " .. remote_name, {name = remote_ref})
        return
    end

    --// If we are already up to date, make sure the instances still match the tree
    if head_sha == remoteSha then
        local index = Handlers.read_index()
        for path, _ in pairs(index) do
            if not Utilities.parse_path(repo.entity_of(path)) then
                repo.ensure_clean("merge")
                print("Restoring missing instances...")
                repo.checkout_tree(remote_commit.tree)
                return
            end
        end
        print("Already up to date.")
        return
    end

    if rebase then
        arguments.execute("git", "rebase", remote_ref)
        return
    end

    local remote_url = (repo.read_config()['remote "' .. remote_name .. '"'] or {}).url or remote_name
    local label = "branch '" .. branch_name .. "' of " .. remote_url
    perform_merge(remoteSha, label, {
        name = remote_ref,
        prefer = opts.prefer,
        no_ff = opts.no_ff,
        ff_only = opts.ff_only,
        squash = opts.squash,
        no_commit = opts.no_commit,
    })
end)


--[[
commands:
rm

Removes instances from the index (and the place, unless --cached).
]]
arguments.createArgument("git", "rm", "", function (...)
    repo.require_root()

    local is_cached, recursive, force, quiet, dry_run = false, false, false, false, false
    local filters = {}
    for _, arg in ipairs({...}) do
        if arg == "--cached" then
            is_cached = true
        elseif arg == "-r" then
            recursive = true
        elseif arg == "-f" or arg == "--force" then
            force = true
        elseif arg == "-q" or arg == "--quiet" then
            quiet = true
        elseif arg == "-n" or arg == "--dry-run" then
            dry_run = true
        elseif arg:match("^%-[rfq]+$") then
            if arg:find("r") then recursive = true end
            if arg:find("f") then force = true end
            if arg:find("q") then quiet = true end
        elseif arg ~= "--" then
            table.insert(filters, normalize_user_path(arg))
        end
    end

    if #filters == 0 then
        error("usage: git rm [<options>] [--] <file>...", 0)
    end

    local index = Handlers.read_index()
    local removed = {}

    for _, filter in ipairs(filters) do
        local matches = {}
        local has_children = false
        for path in pairs(index) do
            if matches_filters(path, {filter}) then
                table.insert(matches, path)
                if repo.entity_of(path) ~= filter then has_children = true end
            end
        end
        if #matches == 0 then
            error("fatal: pathspec '" .. filter .. "' did not match any files", 0)
        end
        if has_children and not recursive then
            error("fatal: not removing '" .. filter .. "' recursively without -r", 0)
        end

        if not force and not is_cached then
            local currObj = Utilities.parse_path(filter)
            if currObj and index[filter] and Handlers.blob_sha(instances.serialize_instance(currObj)) ~= index[filter].sha then
                error("error: the following file has local modifications:\n    " .. filter .. "\n(use --cached to keep the file, or -f to force removal)", 0)
            end
        end

        for _, path in ipairs(matches) do
            table.insert(removed, path)
            index[path] = nil
        end
    end

    table.sort(removed)
    for _, path in ipairs(removed) do
        if not quiet then print("rm '" .. path .. "'") end
    end
    if dry_run then return end

    Handlers.write_index(index)
    repo.resolve_conflicts(filters)

    if not is_cached then
        for _, filter in ipairs(filters) do
            local currObj = Utilities.parse_path(filter)
            if currObj and not bash.isProtected(currObj) then
                pcall(function() currObj:Destroy() end)
            end
        end
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
    local allow_empty_message = false
    local amend = false
    local stage_all = false
    local no_edit = false
    local no_verify = false
    local force_edit = false
    local author_override = nil
    local quiet = false
    local sign = nil

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
        elseif arg == "--allow-empty-message" then
            allow_empty_message = true
        elseif arg == "--amend" then
            amend = true
        elseif arg == "--no-edit" then
            no_edit = true
        elseif arg == "-n" or arg == "--no-verify" then
            no_verify = true
        elseif arg == "-e" or arg == "--edit" then
            force_edit = true
        elseif arg == "-q" or arg == "--quiet" then
            quiet = true
        elseif arg == "-S" or arg:match("^%-%-gpg%-sign") or arg:match("^%-S.") then
            sign = true
        elseif arg == "--no-gpg-sign" then
            sign = false
        elseif arg:match("^%-%-author=") then
            author_override = arg:match("^%-%-author=(.*)$")
        elseif (arg == "-C" or arg == "--reuse-message") and tuple[i + 1] then
            local reused = Handlers.read_commit(Handlers.resolve_revision(tuple[i + 1]))
            assert(reused, "fatal: could not lookup commit " .. tuple[i + 1])
            table.insert(messages, (reused.message:gsub("\n+$", "")))
            i += 1
        end
        i += 1
    end

    --// A stopped merge/cherry-pick/revert can only be committed once every conflict is resolved
    local conflicts = repo.read_conflicts()
    if #conflicts > 0 then
        local lines = {
            "error: Committing is not possible because you have unmerged files.",
            "hint: Fix them up in the work tree, and then use 'git add <file>'",
            "hint: as appropriate to mark resolution and make a commit.",
        }
        for _, conflict in ipairs(conflicts) do
            table.insert(lines, "U\t" .. conflict.path)
        end
        table.insert(lines, "fatal: Exiting because of an unresolved conflict.")
        error(table.concat(lines, "\n"), 0)
    end

    if stage_all then
        arguments.execute("git", "add", "-u")
    end

    local merge_head = repo.read_file("MERGE_HEAD")
    local pick_author = repo.read_file("ROGIT_PICK_AUTHOR")
    local message = table.concat(messages, "\n\n")
    local open_editor = (#messages == 0 and not no_edit) or force_edit

    --// what the editor starts with (and what --no-edit keeps)
    local prefill = ""
    if #messages == 0 then
        local prepared = repo.read_file("MERGE_MSG")
        if prepared then
            prefill = prepared
        elseif amend then
            local old_commit = Handlers.read_commit(repo.head_sha())
            prefill = old_commit and old_commit.message or ""
        end
        message = editor.strip(prefill)
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

    if not allow_empty and num_files_changed == 0 and not amend and not merge_head then
        local unstaged, untracked = false, false
        for _, change in ipairs(repo.get_changes()) do
            if change.status == "U" then untracked = true else unstaged = true end
        end
        local branch = Handlers.get_current_branch()
        local lines = {branch and ("On branch " .. branch) or "HEAD detached"}
        if unstaged then
            table.insert(lines, 'no changes added to commit (use "git add" and/or "git commit -a")')
        elseif untracked then
            table.insert(lines, 'nothing added to commit but untracked files present (use "git add" to track)')
        else
            table.insert(lines, "nothing to commit, working tree clean")
        end
        error(table.concat(lines, "\n"), 0)
    end

    if not no_verify then
        hooks.run_blocking("pre-commit")
        local source = merge_head and "merge" or (amend and "commit" or (#messages > 0 and "message" or ""))
        local prepared = hooks.run_message_hook("prepare-commit-msg", #messages > 0 and message or prefill, {source})
        if #messages > 0 then
            message = prepared
        else
            prefill = prepared
            message = editor.strip(prefill)
        end
    end

    if open_editor then
        local help = {
            "Please enter the commit message for your changes. Lines starting",
            "with '--' will be ignored, and an empty message aborts the commit.",
            "",
            "On branch " .. (Handlers.get_current_branch() or "HEAD (detached)"),
            "Changes to be committed:",
        }
        local changed = {}
        for _, entry in ipairs(files_added) do table.insert(changed, "\tnew file:   " .. entry.path) end
        for _, entry in ipairs(files_modified) do table.insert(changed, "\tmodified:   " .. entry.path) end
        for _, entry in ipairs(files_deleted) do table.insert(changed, "\tdeleted:    " .. entry.path) end
        for _, entry in ipairs(files_renamed) do table.insert(changed, "\trenamed:    " .. entry.old_path .. " -> " .. entry.new_path) end
        table.sort(changed)
        for _, line in ipairs(changed) do table.insert(help, line) end
        message = editor.message(prefill ~= "" and editor.strip(prefill) or table.concat(messages, "\n\n"), help, "COMMIT_EDITMSG")
    end
    if message:match("^%s*$") and not allow_empty_message then
        error("Aborting commit due to empty commit message.", 0)
    end
    if not no_verify then
        message = hooks.run_message_hook("commit-msg", message)
    end

    local parent_sha = Handlers.get_ref("HEAD")
    if parent_sha == "" then parent_sha = nil end

    local parents = {}
    local author = author_override or pick_author
    if amend then
        local old_commit = Handlers.read_commit(parent_sha)
        if old_commit then
            parents = old_commit.parents
            author = author or old_commit.author
        end
    elseif parent_sha then
        parents = {parent_sha}
    end
    if merge_head and not amend then
        table.insert(parents, merge_head)
    end

    local reflog = amend and "commit (amend)" or (merge_head and "commit (merge)") or nil
    if repo.read_file("CHERRY_PICK_HEAD") then reflog = "commit (cherry-pick)" end

    local tree_sha = Handlers.write_tree(index)
    local commit_sha = create_commit(tree_sha, parents, message, {author = author, reflog = reflog, sign = sign})

    --// a concluded merge/cherry-pick/revert (a running sequence keeps its own state)
    for _, name in ipairs({"MERGE_HEAD", "MERGE_MSG", "CHERRY_PICK_HEAD", "REVERT_HEAD", "ROGIT_PICK_AUTHOR"}) do
        repo.delete_file(name)
    end
    local op, sequence = repo.operation_in_progress()
    if sequence and op ~= "rebase" and #(sequence.todo or {}) == 0 then
        repo.delete_file("ROGIT_SEQUENCER")
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
    if not quiet then
        print(final_output)
    end
    hooks.notify("post-commit")
    if amend then
        hooks.notify("post-rewrite", {args = {"amend"}})
    end
end)

--[[
commands:
init

initializes new repository
]]
arguments.createArgument("git", "init", "", function (...)
    local tuple = {...}
    local quiet = false
    local initial_branch = Auth.getConfigValue("init_defaultBranch") or Auth.getConfigValue("init.defaultBranch") or "master"

    local i = 1
    while i <= #tuple do
        if tuple[i] == "-q" or tuple[i] == "--quiet" then
            quiet = true
        elseif (tuple[i] == "-b" or tuple[i] == "--initial-branch") and tuple[i + 1] then
            initial_branch = tuple[i + 1]
            i += 1
        elseif tuple[i]:match("^%-%-initial%-branch=") then
            initial_branch = tuple[i]:match("=(.*)$")
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
    if bash.getWorkRoot() ~= game then
        --// a submodule gets its files from the repository it is cloned from
        return
    end
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
    local recurse_submodules, quiet = false, false

    local i = 1
    while i <= #tuple do
        local arg = tuple[i]
        if (arg == "-b" or arg == "--branch") and tuple[i + 1] then
            branch_override = tuple[i + 1]
            i += 1
        elseif arg == "--single-branch" then
            single_branch = true
        elseif arg == "--recurse-submodules" or arg == "--recursive" then
            recurse_submodules = true
        elseif arg == "-q" or arg == "--quiet" then
            quiet = true
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
    if not quiet then print("Cloning into '" .. repoName .. "'...") end

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
    Handlers.append_reflog("HEAD", nil, headSha, "clone: from " .. url)
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

    Remote.writeRoot(objectsBySha, treeSha)
    Remote.resolve_instance_refs()

    local new_index = Remote.buildIndexFromTree(objectsBySha, treeSha)
    Handlers.write_index(new_index)
    bash.writeFile(gitRoot, "last_commit_index", HttpService:JSONEncode(new_index))

    if not quiet then
        print("Done. '" .. repoName .. "' cloned.")
    end
    if recurse_submodules then
        arguments.execute("git", "submodule", "update", "--init", "--recursive")
    end
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
        ["show"] = true,
        ["prune"] = true,
        ["update"] = true,
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
    
    if subcommand == "prune" then
        assert(tuple[2], "usage: git remote prune <name>")
        git_remote.fetch(tuple[2], false, {prune = true})
        return
    elseif subcommand == "update" then
        arguments.execute("git", "fetch", "--all")
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
    local dry_run = false
    local no_verify = false
    local lease = nil
    local positional = {}

    for _, arg in ipairs(tuple) do
        if arg == "-n" or arg == "--dry-run" then
            dry_run = true
        elseif arg == "--no-verify" then
            no_verify = true
        elseif arg == "--force-with-lease" then
            lease = {}
        elseif arg:match("^%-%-force%-with%-lease=") then
            local ref, expect = arg:match("^%-%-force%-with%-lease=([^:]+):?(.*)$")
            lease = {ref = ref, expect = expect ~= "" and expect or nil}
        elseif arg == "-f" or arg == "--force" then
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

    local current_branch = Handlers.get_current_branch()
    local upstream_remote, upstream_branch, has_upstream = repo.get_upstream(current_branch)
    local remote_name = table.remove(positional, 1) or upstream_remote or "origin"

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
        table.insert(specs, {sha = sha, ref = dst_ref, force = plus or force_push, lease = lease, label = (src_name == "HEAD" and current_branch) or src_name})
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
        --// push.default=simple: to the configured upstream branch (same name otherwise)
        local destination = (has_upstream and upstream_remote == remote_name) and upstream_branch or current_branch
        add_spec("HEAD", "refs/heads/" .. destination)
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
            if spec.lease and not spec.force then
                --// only overwrite what we last saw on the remote
                local short_name = spec.ref:gsub("^refs/heads/", "")
                local expected = spec.lease.expect and Handlers.resolve_revision(spec.lease.expect)
                    or Handlers.get_ref("refs/remotes/" .. remote_name .. "/" .. short_name)
                if remoteSha and remoteSha ~= expected then
                    error("To " .. url .. "\n ! [rejected]        " .. spec.label .. " -> " .. short_name .. " (stale info)\nerror: failed to push some refs to '" .. url .. "'", 0)
                end
            elseif remoteSha and spec.ref:match("^refs/heads/") and not spec.force then
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

    if not no_verify then
        local hook_updates = {}
        for _, update in ipairs(updates) do
            table.insert(hook_updates, {ref = update.ref, old = update.old, new = update.new, delete = update.delete == true})
        end
        hooks.run_blocking("pre-push", {args = {remote_name, url}, updates = hook_updates})
    end

    if dry_run then
        local lines = {"To " .. url}
        for _, update in ipairs(updates) do
            local short_name = update.ref:gsub("^refs/%a+/", "")
            if update.delete then
                table.insert(lines, " - [deleted]         " .. short_name)
            elseif update.old == ZERO_SHA then
                table.insert(lines, " * [new " .. (update.ref:match("^refs/tags/") and "tag" or "branch") .. "]      " .. update.label .. " -> " .. short_name)
            else
                table.insert(lines, "   " .. update.old:sub(1, 7) .. ".." .. update.new:sub(1, 7) .. "  " .. update.label .. " -> " .. short_name)
            end
        end
        print(table.concat(lines, "\n"))
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
Describes how the current branch relates to its upstream, nil when there is nothing to compare.
Returns the upstream name, ahead, behind.
]]
local function upstream_state(branch, head_sha)
    if not branch or not head_sha then return nil end
    local remote, remote_branch = repo.get_upstream(branch)
    local upstream_name = remote .. "/" .. remote_branch
    local upstream = Handlers.get_ref("refs/remotes/" .. upstream_name)
    if not upstream or not Handlers.read_commit(upstream) then return nil end
    local ahead, behind = count_ahead_behind(head_sha, upstream)
    return upstream_name, ahead, behind
end

local CONFLICT_LABELS = {
    ["content"] = "both modified",
    ["add/add"] = "both added",
    ["modify/delete: deleted in theirs"] = "deleted by them",
    ["modify/delete: deleted in ours"] = "deleted by us",
}

local function conflict_label(reason)
    local kind = reason:match("^([^:]+:?[^:]*)") or reason
    for prefix, label in pairs(CONFLICT_LABELS) do
        if reason:sub(1, #prefix) == prefix then return label end
    end
    return kind
end

--[[
commands:
status
st

gets status of branch/changes
]]
arguments.createArgument("git", "status", "st", function(...)
    repo.require_root()
    Handlers.load_ignore_patterns()

    local short, porcelain, show_branch = false, false, false
    for _, arg in ipairs({...}) do
        if arg == "-s" or arg == "--short" then
            short = true
        elseif arg == "--porcelain" or arg:match("^%-%-porcelain=") then
            short, porcelain = true, true
        elseif arg == "-b" or arg == "--branch" then
            show_branch = true
        elseif arg == "-sb" or arg == "-bs" then
            short, show_branch = true, true
        end
    end

    local index = Handlers.read_index()
    local headSha = repo.head_sha()
    local current_branch = Handlers.get_current_branch()
    local last_index = read_last_index()

    local conflicted = {}
    local conflicts = repo.read_conflicts()
    for _, conflict in ipairs(conflicts) do
        conflicted[conflict.path] = conflict
    end
    local function is_conflicted(path)
        return conflicted[repo.entity_of(path)] ~= nil
    end

    --// per path: staged status (X) and worktree status (Y)
    local entries = {}
    local function entry(path)
        entries[path] = entries[path] or {path = path, x = " ", y = " "}
        return entries[path]
    end

    for path, data in pairs(index) do
        Utilities.roYield()
        if not last_index[path] then
            entry(path).x = "A"
        elseif last_index[path].sha ~= data.sha then
            entry(path).x = "M"
        end
    end
    for path in pairs(last_index) do
        if not index[path] then
            entry(path).x = "D"
        end
    end

    local unstaged_modified, unstaged_deleted = collect_worktree_changes(index)
    for _, path in ipairs(unstaged_modified) do entry(path).y = "M" end
    for _, path in ipairs(unstaged_deleted) do entry(path).y = "D" end

    local untracked = {}
    for path in pairs(collect_untracked(index)) do
        table.insert(untracked, path)
    end
    table.sort(untracked)

    local sorted = {}
    for _, e in pairs(entries) do
        if not is_conflicted(e.path) then table.insert(sorted, e) end
    end
    table.sort(sorted, function(x, y) return x.path < y.path end)

    local upstream_name, ahead, behind = upstream_state(current_branch, headSha)

    if short then
        local red, green, reset = "\27[31m", "\27[32m", "\27[0m"
        if porcelain then red, green, reset = "", "", "" end

        if show_branch then
            local line = "## " .. (current_branch or "HEAD (no branch)")
            if upstream_name then
                line ..= "..." .. upstream_name
                local parts = {}
                if ahead > 0 then table.insert(parts, "ahead " .. ahead) end
                if behind > 0 then table.insert(parts, "behind " .. behind) end
                if #parts > 0 then line ..= " [" .. table.concat(parts, ", ") .. "]" end
            end
            print(line)
        end
        for _, conflict in ipairs(conflicts) do
            local codes = {["both modified"] = "UU", ["both added"] = "AA", ["deleted by them"] = "UD", ["deleted by us"] = "DU"}
            print(red .. (codes[conflict_label(conflict.reason)] or "UU") .. reset .. " " .. conflict.path)
        end
        for _, e in ipairs(sorted) do
            print(green .. e.x .. reset .. red .. e.y .. reset .. " " .. e.path)
        end
        for _, path in ipairs(untracked) do
            print(red .. "??" .. reset .. " " .. path)
        end
        return
    end

    if current_branch then
        print("On branch " .. current_branch)
        if upstream_name then
            if ahead > 0 and behind > 0 then
                print(string.format("Your branch and '%s' have diverged,\nand have %d and %d different commits each, respectively.", upstream_name, ahead, behind))
            elseif ahead > 0 then
                print(string.format("Your branch is ahead of '%s' by %d commit%s.", upstream_name, ahead, ahead == 1 and "" or "s"))
            elseif behind > 0 then
                print(string.format("Your branch is behind '%s' by %d commit%s, and can be fast-forwarded.", upstream_name, behind, behind == 1 and "" or "s"))
            else
                print(string.format("Your branch is up to date with '%s'.", upstream_name))
            end
        end
    else
        local op, state = repo.operation_in_progress()
        if op == "rebase" and state then
            print("interactive rebase in progress; onto " .. tostring(state.onto):sub(1, 7))
        else
            print("HEAD detached at " .. string.sub(headSha or "", 1, 7))
        end
    end

    if not headSha then
        print("\nNo commits yet\n")
    end

    --// operations that stopped half way
    local op, state = repo.operation_in_progress()
    if op then
        local verbs = {merge = "merge", ["cherry-pick"] = "cherry-pick", revert = "revert", rebase = "rebase"}
        if op == "rebase" and state then
            print(string.format("You are currently rebasing%s on '%s'.", state.head_name and (" branch '" .. state.head_name:gsub("^refs/heads/", "") .. "'") or "", tostring(state.onto):sub(1, 7)))
        end
        if #conflicts > 0 then
            print(op == "merge" and "You have unmerged paths." or ("You are currently in a " .. verbs[op] .. "."))
            print(op == "merge" and '  (fix conflicts and run "git commit")' or ('  (fix conflicts and run "git ' .. verbs[op] .. ' --continue")'))
            print('  (use "git ' .. verbs[op] .. ' --abort" to abort the ' .. verbs[op] .. ")")
        else
            print(op == "merge" and "All conflicts fixed but you are still merging." or ("All conflicts fixed: run \"git " .. verbs[op] .. " --continue\""))
            if op == "merge" then print('  (use "git commit" to conclude merge)') end
        end
        print("")
    elseif #conflicts > 0 then
        print("You have unmerged paths.\n")
    end

    local staged, unstaged = {}, {}
    local labels = {A = "new file:   ", M = "modified:   ", D = "deleted:    "}
    for _, e in ipairs(sorted) do
        if e.x ~= " " then table.insert(staged, "\t\27[32m" .. labels[e.x] .. e.path .. "\27[0m") end
        if e.y ~= " " then table.insert(unstaged, "\t\27[31m" .. labels[e.y] .. e.path .. "\27[0m") end
    end

    if #staged > 0 then
        print("Changes to be committed:")
        print('  (use "git restore --staged <file>..." to unstage)')
        for _, line in ipairs(staged) do print(line) end
        print("")
    end

    if #conflicts > 0 then
        print("Unmerged paths:")
        print('  (use "git add <file>..." to mark resolution)')
        for _, conflict in ipairs(conflicts) do
            local label = conflict_label(conflict.reason)
            print("\t\27[31m" .. label .. ":" .. string.rep(" ", math.max(1, 16 - #label)) .. conflict.path .. "\27[0m")
        end
        print("")
    end

    if #unstaged > 0 then
        print("Changes not staged for commit:")
        print('  (use "git add <file>..." to update what will be committed)')
        print('  (use "git restore <file>..." to discard changes in working directory)')
        for _, line in ipairs(unstaged) do print(line) end
        print("")
    end

    if #untracked > 0 then
        print("Untracked files:")
        print('  (use "git add <file>..." to include in what will be committed)')
        local limit = 50
        for i, path in ipairs(untracked) do
            if i > limit then
                print(string.format("\t... and %d more", #untracked - limit))
                break
            end
            print("\t\27[31m" .. path .. "\27[0m")
        end
        print("")
    end

    if #staged == 0 and #conflicts == 0 then
        if #unstaged > 0 then
            print('no changes added to commit (use "git add" and/or "git commit -a")')
        elseif #untracked > 0 then
            print('nothing added to commit but untracked files present (use "git add" to track)')
        else
            print("nothing to commit, working tree clean")
        end
    end
end)

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
Did a commit change anything under `filters` (compared to its first parent)?
]]
local function commit_touches(commit, filters)
    if #filters == 0 then return true end
    local parent = commit.parents[1] and Handlers.read_commit(commit.parents[1])
    local old = parent and repo.tree_index(parent.tree) or {}
    local new = repo.tree_index(commit.tree)
    for path, data in pairs(new) do
        if matches_filters(path, filters) and (not old[path] or old[path].sha ~= data.sha) then return true end
    end
    for path in pairs(old) do
        if matches_filters(path, filters) and not new[path] then return true end
    end
    return false
end

--[[
Expands a --format/--pretty placeholder string for one commit.
]]
local function format_commit(fmt, sha, commit, decorations)
    if fmt:find("%G", 1, true) then
        fmt = fmt:gsub("%%G%?", function() return (repo.verify_signature(sha)) end)
            :gsub("%%GK", function() return select(2, repo.verify_signature(sha)) or "" end)
    end
    local author_name, author_email, author_time = (commit.author or ""):match("^(.-) <(.-)> (%d+)")
    local committer_name, committer_email, committer_time = (commit.committer or ""):match("^(.-) <(.-)> (%d+)")
    local subject = commit.message:match("^[^\n]*") or ""
    local body = commit.message:match("^[^\n]*\n\n(.*)$") or ""
    local function date(t) return t and os.date("%a %b %d %H:%M:%S %Y", tonumber(t)) .. " +0000" or "" end
    local short_parents = {}
    for _, parent in ipairs(commit.parents) do table.insert(short_parents, parent:sub(1, 7)) end

    local values = {
        H = sha, h = sha:sub(1, 7),
        T = commit.tree or "", t = (commit.tree or ""):sub(1, 7),
        P = table.concat(commit.parents, " "), p = table.concat(short_parents, " "),
        an = author_name or "", ae = author_email or "", ad = date(author_time), at = author_time or "",
        cn = committer_name or "", ce = committer_email or "", cd = date(committer_time), ct = committer_time or "",
        s = subject, b = body:gsub("\n+$", ""), B = commit.message:gsub("\n+$", ""),
        d = (decorations and #decorations > 0) and (" (" .. table.concat(decorations, ", ") .. ")") or "",
        D = decorations and table.concat(decorations, ", ") or "",
        n = "\n", ["%"] = "%",
    }
    return (fmt:gsub("%%(%a%a?)", function(key)
        if values[key] ~= nil then return values[key] end
        local single = key:sub(1, 1)
        if values[single] ~= nil then return values[single] .. key:sub(2) end
        return "%" .. key
    end):gsub("%%%%", "%%"))
end

--[[
commands:
log

Shows commit logs.
]]
arguments.createArgument("git", "log", "", function(...)
    repo.require_root()

    local tuple = {...}
    local max_count = nil
    local oneline, graph, all, reverse = false, false, false, false
    local format = nil
    local changes = nil --// nil, "patch", "stat", "name-only", "name-status"
    local author, grep = nil, nil
    local show_signature = false
    local specs, filters = {}, {}
    local after_dashes = false

    local i = 1
    while i <= #tuple do
        local arg = tuple[i]
        if after_dashes then
            table.insert(filters, normalize_user_path(arg))
        elseif arg == "--" then
            after_dashes = true
        elseif arg == "--oneline" then
            oneline = true
        elseif arg == "--graph" then
            graph = true
        elseif arg == "--all" then
            all = true
        elseif arg == "--reverse" then
            reverse = true
        elseif arg == "-p" or arg == "--patch" or arg == "-u" then
            changes = "patch"
        elseif arg == "--stat" then
            changes = "stat"
        elseif arg == "--name-only" then
            changes = "name-only"
        elseif arg == "--name-status" then
            changes = "name-status"
        elseif arg == "--show-signature" then
            show_signature = true
        elseif arg == "--decorate" or arg == "--no-decorate" or arg == "--abbrev-commit" then
            --// always decorated
        elseif (arg == "-n" or arg == "--max-count") and tuple[i + 1] then
            max_count = tonumber(tuple[i + 1])
            i += 1
        elseif arg:match("^%-%-max%-count=(%d+)$") then
            max_count = tonumber(arg:match("^%-%-max%-count=(%d+)$"))
        elseif arg:match("^%-(%d+)$") then
            max_count = tonumber(arg:match("^%-(%d+)$"))
        elseif arg:match("^%-%-author=") then
            author = arg:match("^%-%-author=(.*)$"):lower()
        elseif arg:match("^%-%-grep=") then
            grep = arg:match("^%-%-grep=(.*)$"):lower()
        elseif arg:match("^%-%-pretty=") or arg:match("^%-%-format=") then
            format = arg:match("^%-%-%a+=(.*)$")
            format = format:gsub("^format:", ""):gsub("^tformat:", "")
            if format == "oneline" then oneline, format = true, nil end
            if format == "short" or format == "medium" or format == "full" then format = nil end
        elseif arg:sub(1, 1) ~= "-" then
            if Handlers.resolve_revision(arg) or arg:find("..", 1, true) or arg:sub(1, 1) == "^" then
                table.insert(specs, arg)
            else
                table.insert(filters, normalize_user_path(arg))
            end
        end
        i += 1
    end

    if all then
        for _, sha in pairs(Handlers.list_refs()) do table.insert(specs, sha) end
        if repo.head_sha() then table.insert(specs, repo.head_sha()) end
    end
    if #specs == 0 and not repo.head_sha() then
        error("fatal: your current branch '" .. (Handlers.get_current_branch() or repo.default_branch()) .. "' does not have any commits yet", 0)
    end

    local decorations = collect_decorations()
    local list = {}
    for _, item in ipairs(inspect().rev_list(specs)) do
        local commit = item.commit
        local keep = true
        if author and not (commit.author or ""):lower():find(author, 1, true) then keep = false end
        if keep and grep and not commit.message:lower():find(grep, 1, true) then keep = false end
        if keep and not commit_touches(commit, filters) then keep = false end
        if keep then table.insert(list, item) end
        if max_count and #list >= max_count and not reverse then break end
    end
    if max_count then
        while #list > max_count do table.remove(list) end
    end
    if reverse then
        local reversed = {}
        for n = #list, 1, -1 do table.insert(reversed, list[n]) end
        list = reversed
    end

    --// lanes for --graph: which commit each column is waiting for
    local columns = {}
    local function graph_prefix(sha)
        if not graph then return "", nil end
        local column = table.find(columns, sha)
        if not column then
            table.insert(columns, sha)
            column = #columns
        end
        local cells = {}
        for n = 1, #columns do cells[n] = n == column and "*" or "|" end
        return table.concat(cells, " ") .. " ", column
    end
    local function graph_advance(column, commit)
        if not graph then return end
        local parents = commit.parents
        if #parents == 0 then
            table.remove(columns, column)
            return
        end
        columns[column] = parents[1]
        local added = 0
        for n = 2, #parents do
            if not table.find(columns, parents[n]) then
                table.insert(columns, column + n - 1, parents[n])
                added += 1
            end
        end
        if added > 0 then
            local cells = {}
            for n = 1, #columns - added do cells[n] = "|" end
            print(table.concat(cells, " ") .. "\\")
        end
        --// two lanes waiting for the same commit join up
        for a = 1, #columns do
            for b = #columns, a + 1, -1 do
                if columns[a] == columns[b] then
                    table.remove(columns, b)
                    local cells = {}
                    for n = 1, #columns do cells[n] = "|" end
                    print(table.concat(cells, " ") .. "/")
                end
            end
        end
    end

    for _, item in ipairs(list) do
        local sha, commit = item.sha, item.commit
        local prefix, column = graph_prefix(sha)
        local pad = graph and string.rep("| ", #columns) or ""

        if format then
            print(prefix .. format_commit(format, sha, commit, decorations[sha]))
        elseif oneline then
            local decoration = decorations[sha] and (" \27[33m(" .. table.concat(decorations[sha], ", ") .. ")\27[0m") or ""
            print(prefix .. "\27[33m" .. sha:sub(1, 7) .. "\27[0m" .. decoration .. " " .. (commit.message:match("^[^\n]*") or ""))
        else
            if graph then
                output.print(prefix .. "\27[33mcommit " .. sha .. "\27[0m")
            else
                print_commit_header(sha, commit, decorations[sha])
            end
            if show_signature then
                local status = repo.verify_signature(sha)
                if status ~= "N" then
                    local _, text = require(script.Parent.commands.signing).describe(sha)
                    print(pad .. text)
                end
            end
            if graph then
                local who, time = (commit.author or ""):match("^(.-) (%d+) [+-]%d+$")
                print(pad .. "Author: " .. (who or ""))
                print(pad .. "Date:   " .. (time and os.date("%a %b %d %H:%M:%S %Y", tonumber(time)) or "") .. " +0000")
            end
            print(pad)
            for line in (commit.message:gsub("\n+$", "") .. "\n"):gmatch("([^\n]*)\n") do
                print(pad .. "    " .. line)
            end
            print(pad)
        end

        if changes then
            local parent = commit.parents[1] and Handlers.read_commit(commit.parents[1])
            print_changes(compare_indexes(parent and repo.tree_index(parent.tree) or {}, repo.tree_index(commit.tree), nil, filters), changes)
            if not oneline then print("") end
        end

        graph_advance(column, commit)
    end
end)

--[[
commands:
show

Shows a commit (HEAD by default) and the instances it changed, a tag, or an object (<rev>:<path>).
]]
arguments.createArgument("git", "show", "", function(...)
    repo.require_root()

    local revs = {}
    local format = "patch"
    local oneline = false
    for _, arg in ipairs({...}) do
        if arg == "--name-only" then
            format = "name-only"
        elseif arg == "--name-status" then
            format = "name-status"
        elseif arg == "--stat" then
            format = "stat"
        elseif arg == "--oneline" then
            oneline = true
        elseif arg == "-s" or arg == "--no-patch" then
            format = nil
        elseif arg:sub(1, 1) ~= "-" then
            table.insert(revs, arg)
        end
    end
    if #revs == 0 then revs = {"HEAD"} end

    for _, rev in ipairs(revs) do
        if rev:find(":", 1, true) then
            inspect().show_object(rev)
        else
            local sha = Handlers.resolve_revision(rev)
            if not sha then
                error("fatal: ambiguous argument '" .. rev .. "': unknown revision or path not in the working tree.", 0)
            end

            --// annotated tag: show the tag itself first
            local tagSha = Handlers.get_ref("refs/tags/" .. rev)
            local tagObj = tagSha and Handlers.read_object(tagSha)
            if tagObj and tagObj.type == "tag" then
                print("\27[33mtag " .. rev .. "\27[0m")
                local tagger = tagObj.content:match("\ntagger ([^\n]+)") or ""
                print("Tagger: " .. (tagger:match("^(.-) %d+ [+-]%d+$") or tagger))
                print("")
                print((tagObj.content:match("\n\n(.*)$") or ""):gsub("\n+$", ""))
                print("")
            end

            local commit = Handlers.read_commit(sha)
            if oneline then
                print("\27[33m" .. sha:sub(1, 7) .. "\27[0m " .. (commit.message:match("^[^\n]*") or ""))
            else
                print_commit_header(sha, commit, collect_decorations()[sha])
                print("")
                for line in (commit.message:gsub("\n+$", "") .. "\n"):gmatch("([^\n]*)\n") do
                    print("    " .. line)
                end
                print("")
            end

            if format then
                local parent = commit.parents[1] and Handlers.read_commit(commit.parents[1])
                print_changes(compare_indexes(parent and repo.tree_index(parent.tree) or {}, repo.tree_index(commit.tree), nil, {}), format)
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
    local show_remotes, only_remotes, verbose, very_verbose, force = false, false, false, false, false
    local merged_filter, contains = nil, nil
    local upstream_arg = nil
    local positional = {}

    local i = 1
    while i <= #tuple do
        local arg = tuple[i]
        if arg == "-a" or arg == "--all" then
            show_remotes = true
        elseif arg == "-r" or arg == "--remotes" then
            show_remotes, only_remotes = true, true
        elseif arg == "-v" or arg == "--verbose" then
            verbose = true
        elseif arg == "-vv" then
            verbose, very_verbose = true, true
        elseif arg == "--merged" or arg == "--no-merged" then
            merged_filter = {merged = arg == "--merged", rev = "HEAD"}
            if tuple[i + 1] and tuple[i + 1]:sub(1, 1) ~= "-" and Handlers.resolve_revision(tuple[i + 1]) then
                merged_filter.rev = tuple[i + 1]
                i += 1
            end
        elseif arg == "--contains" and tuple[i + 1] then
            contains = tuple[i + 1]
            i += 1
        elseif (arg == "-u" or arg == "--set-upstream-to") and tuple[i + 1] then
            mode, upstream_arg = "upstream", tuple[i + 1]
            i += 1
        elseif arg:match("^%-%-set%-upstream%-to=") then
            mode, upstream_arg = "upstream", arg:match("=(.*)$")
        elseif arg == "--unset-upstream" then
            mode = "unset-upstream"
        elseif arg == "-c" or arg == "--copy" or arg == "-C" then
            mode = "copy"
            if arg == "-C" then force = true end
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
        i += 1
    end

    local current_branch = Handlers.get_current_branch()

    if mode == "current" then
        if current_branch then print(current_branch) end
        return
    end

    if mode == "upstream" then
        local branch = positional[1] or current_branch
        assert(branch, "fatal: could not set upstream of HEAD when it does not point to any branch.")
        local remote, remote_branch = upstream_arg:match("^([^/]+)/(.+)$")
        assert(remote and Handlers.get_ref("refs/remotes/" .. upstream_arg), "fatal: the requested upstream branch '" .. upstream_arg .. "' does not exist")
        repo.set_upstream(branch, remote, remote_branch)
        print("branch '" .. branch .. "' set up to track '" .. upstream_arg .. "'.")
        return
    end

    if mode == "unset-upstream" then
        local branch = positional[1] or current_branch
        local conf = repo.read_config()
        conf['branch "' .. tostring(branch) .. '"'] = nil
        repo.write_config(conf)
        return
    end

    if mode == "copy" then
        local old_branch, new_branch = positional[1], positional[2]
        if not new_branch then old_branch, new_branch = current_branch, old_branch end
        local sha = old_branch and Handlers.get_ref("refs/heads/" .. old_branch)
        assert(sha, "error: refname refs/heads/" .. tostring(old_branch) .. " not found")
        assert(is_valid_branch_name(new_branch), "fatal: '" .. tostring(new_branch) .. "' is not a valid branch name.")
        assert(force or not Handlers.get_ref("refs/heads/" .. new_branch), "fatal: a branch named '" .. new_branch .. "' already exists")
        Handlers.update_ref("refs/heads/" .. new_branch, sha, "branch: Copied from " .. old_branch)
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

        local merged_target = merged_filter and Handlers.resolve_revision(merged_filter.rev)
        local contains_sha = contains and Handlers.resolve_revision(contains)
        if contains and not contains_sha then
            error("error: malformed object name " .. contains, 0)
        end

        for _, entry in ipairs(entries) do
            local show = true
            if merged_filter and entry.sha then
                show = is_ancestor_commit(entry.sha, merged_target) == merged_filter.merged
            end
            if show and contains_sha and entry.sha then
                show = is_ancestor_commit(contains_sha, entry.sha)
            end
            if show then
                local line = (entry.is_current and "* " or "  ") .. (entry.is_current and ("\27[32m" .. entry.display .. "\27[0m") or entry.display)
                if verbose and entry.sha then
                    local commit = Handlers.read_commit(entry.sha)
                    local tracking = ""
                    if very_verbose and not entry.name:match("^remotes/") then
                        local upstream_name, ahead, behind = upstream_state(entry.name, entry.sha)
                        if upstream_name then
                            local parts = {}
                            if ahead > 0 then table.insert(parts, "ahead " .. ahead) end
                            if behind > 0 then table.insert(parts, "behind " .. behind) end
                            tracking = "[\27[34m" .. upstream_name .. "\27[0m" .. (#parts > 0 and (": " .. table.concat(parts, ", ")) or "") .. "] "
                        end
                    end
                    line = line .. " " .. entry.sha:sub(1, 7) .. " " .. tracking .. (commit and commit.message:match("^[^\n]*") or "")
                end
                print(line)
            end
        end

        if #entries == 0 and current_branch then
            print("* " .. current_branch)
        end
        return
    end

    if mode == "delete" then
        assert(#positional > 0, "fatal: branch name required")
        for _, branch in ipairs(positional) do
            local checked_out = current_branch == branch and (bash.getWorkRoot() == game and "game" or bash.getWorkRoot():GetFullName())
                or repo.branch_worktree(branch)
            if checked_out then
                print("error: Cannot delete branch '" .. branch .. "' checked out at '" .. checked_out .. "'")
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
    local sign_tag = nil
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
        elseif arg == "-s" or arg == "--sign" then
            annotated, sign_tag = true, true
        elseif arg == "--no-sign" then
            sign_tag = false
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
        local tag_message = message
        if not tag_message then
            tag_message = editor.message("", {
                "Write a message for tag:",
                "  " .. name,
                "Lines starting with '--' will be ignored.",
            }, "TAG_EDITMSG")
            if tag_message == "" then
                error("fatal: no tag message?", 0)
            end
        end
        local content = string.format("object %s\ntype commit\ntag %s\ntagger %s\n\n%s\n", target, name, make_signature(), tag_message)
        if repo.wants_signature(sign_tag, "tag.gpgSign") then
            local seed = repo.signing_seed()
            if not seed then
                error("error: no signing key configured\nhint: create one with 'git signing-key generate'", 0)
            end
            content ..= require(script.Parent.libs.sshsig).sign(seed, content)
        end
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

    if #repo.read_conflicts() > 0 then
        error("error: you need to resolve your current index first", 0)
    end
    local elsewhere = branch and repo.branch_worktree(branch)
    if elsewhere then
        error("fatal: '" .. branch .. "' is already used by worktree at '" .. elsewhere .. "'", 0)
    end

    local current_sha = Handlers.get_ref("HEAD")
    if target_sha ~= current_sha then
        local dirty = dirty_changes()
        if #dirty > 0 then
            print_dirty_abort(dirty, "checkout")
            return false
        end
    end

    local from = Handlers.get_current_branch() or string.sub(current_sha or "", 1, 7)
    local to = branch or string.sub(target_sha, 1, 7)
    if create then
        Handlers.update_ref("refs/heads/" .. branch, target_sha, "branch: Created from " .. from)
    end
    Handlers.set_head(branch and ("refs/heads/" .. branch) or target_sha, "checkout: moving from " .. from .. " to " .. to)

    if target_sha ~= current_sha then
        print("Checking out files: 100% done.")
        local ok, err = Remote.checkout(commit.tree)
        assert(ok, err)
    end
    hooks.notify("post-checkout", {args = {current_sha or repo.ZERO_SHA, target_sha, "1"}})
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
        error("fatal: missing branch or commit argument\nusage: git switch [-c | --create] <branch> [<start-point>]", 0)
    end

    local current_branch = Handlers.get_current_branch()

    --// "-" is the branch you were on before (from the reflog)
    if name == "-" or name == "@{-1}" then
        name = nil
        for _, entry in ipairs(Handlers.read_reflog("HEAD")) do
            local previous = entry.message:match("^checkout: moving from (%S+) to ")
            if previous then
                name = previous
                break
            end
        end
        if not name then
            error("fatal: invalid reference: @{-1}", 0)
        end
        if not Handlers.get_ref("refs/heads/" .. name) then
            detach = true
        end
    end

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
            --// branching off a remote branch tracks it (branch.autoSetupMerge)
            local start = positional[2]
            local remote, remote_branch = nil, nil
            if start then
                remote, remote_branch = start:match("^([^/]+)/(.+)$")
            end
            if remote and Handlers.get_ref("refs/remotes/" .. start) then
                repo.set_upstream(name, remote, remote_branch)
                print("branch '" .. name .. "' set up to track '" .. start .. "'.")
            end
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
            repo.set_upstream(name, "origin", name)
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

    if first == "-" then
        arguments.execute("git", "switch", "-")
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

    --// git checkout <tree-ish> -- <paths>: take the paths from that commit (index and place)
    if tuple[2] == "--" or (#tuple > 1 and Handlers.resolve_revision(first) and not Utilities.parse_path(first)) then
        local paths = {}
        for i = 2, #tuple do
            if tuple[i] ~= "--" then table.insert(paths, tuple[i]) end
        end
        if Handlers.resolve_revision(first) then
            arguments.execute("git", "restore", "--source=" .. first, "--staged", "--worktree", table.unpack(paths))
        else
            arguments.execute("git", "restore", first, table.unpack(paths))
        end
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

    local prune, all, quiet = repo.get_config("fetch.prune") == "true", false, false
    local positional = {}
    for _, arg in ipairs({...}) do
        if arg == "-p" or arg == "--prune" then prune = true
        elseif arg == "--no-prune" then prune = false
        elseif arg == "--all" then all = true
        elseif arg == "-q" or arg == "--quiet" then quiet = true
        elseif arg == "--tags" or arg == "-t" then --// tags are always fetched
        elseif arg:sub(1, 1) ~= "-" then table.insert(positional, arg)
        end
    end

    local remotes = {}
    if all then
        for section in pairs(repo.read_config()) do
            local name = section:match('^remote "(.+)"$')
            if name then table.insert(remotes, name) end
        end
        table.sort(remotes)
    else
        local upstream_remote = repo.get_upstream(Handlers.get_current_branch())
        table.insert(remotes, positional[1] or upstream_remote or "origin")
    end

    for _, remote_name in ipairs(remotes) do
        git_remote.fetch(remote_name, quiet, {prune = prune})
    end
end)

--[[
commands:
reset

resets repository change/s
]]
arguments.createArgument("git", "reset", "", function(...)
    repo.require_root()

    local tuple = {...}
    local mode = "--mixed"
    local commit_target = "HEAD"
    local positional, paths = {}, {}
    local after_dashes, quiet = false, false

    for _, arg in ipairs(tuple) do
        if after_dashes then
            table.insert(paths, arg)
        elseif arg == "--" then
            after_dashes = true
        elseif arg == "--soft" or arg == "--mixed" or arg == "--hard" or arg == "--keep" or arg == "--merge" then
            mode = arg
        elseif arg == "-q" or arg == "--quiet" then
            quiet = true
        elseif arg:sub(1, 1) ~= "-" then
            table.insert(positional, arg)
        end
    end

    if #positional > 0 then
        local first = positional[1]
        if Handlers.resolve_revision(first) and (after_dashes or #positional > 1 or not Utilities.parse_path(first)) then
            commit_target = table.remove(positional, 1)
        end
        for _, path in ipairs(positional) do
            table.insert(paths, path)
        end
    end

    local target_sha = Handlers.resolve_revision(commit_target)
    if not target_sha then
        if commit_target == "HEAD" and #paths > 0 then
            target_sha = nil --// unborn branch: unstaging means dropping from the index
        else
            error("fatal: ambiguous argument '" .. commit_target .. "': unknown revision or path not in the working tree.", 0)
        end
    end
    local target_commit = target_sha and Handlers.read_commit(target_sha)

    local function list_unstaged()
        if quiet then return end
        local unstaged = {}
        for _, change in ipairs(git.get_changes()) do
            if change.status ~= "U" and not change.staged then
                table.insert(unstaged, change.status .. "\t" .. change.path)
            end
        end
        if #unstaged > 0 then
            print("Unstaged changes after reset:")
            for _, line in ipairs(unstaged) do print(line) end
        end
    end

    --// git reset [<commit>] -- <paths>: copy those entries from the commit into the index
    if #paths > 0 then
        if mode ~= "--mixed" then
            error("fatal: Cannot do " .. mode:sub(3) .. " reset with paths.", 0)
        end
        local filters = {}
        for _, path in ipairs(paths) do table.insert(filters, path == "." and "." or normalize_user_path(path)) end

        local source = target_commit and repo.tree_index(target_commit.tree) or {}
        local index = Handlers.read_index()
        for path in pairs(table.clone(index)) do
            if matches_filters(path, filters) and not source[path] then index[path] = nil end
        end
        for path, data in pairs(source) do
            if matches_filters(path, filters) then index[path] = {sha = data.sha, mode = data.mode} end
        end
        Handlers.write_index(index)
        repo.resolve_conflicts(filters)
        list_unstaged()
        return
    end

    if not target_commit or not target_commit.tree then
        error("fatal: Could not parse object '" .. commit_target .. "'.", 0)
    end

    if mode == "--keep" or mode == "--merge" then
        repo.ensure_clean("reset")
        mode = "--hard"
    end

    repo.save_orig_head()
    local current_branch = Handlers.get_current_branch()
    local message = "reset: moving to " .. commit_target
    if current_branch then
        Handlers.update_ref("HEAD", target_sha, message)
    else
        Handlers.set_head(target_sha, message)
    end

    if mode == "--soft" then
        return
    end

    --// a reset ends any merge/cherry-pick/revert that was waiting
    if not repo.read_file("ROGIT_SEQUENCER") then
        repo.clear_operation_state()
    else
        repo.write_conflicts({})
    end

    if mode == "--hard" then
        repo.checkout_tree(target_commit.tree)
        if not quiet then
            print("HEAD is now at " .. target_sha:sub(1, 7) .. " " .. (target_commit.message:match("^[^\n]*") or ""))
        end
        return
    end

    Handlers.write_index(repo.tree_index(target_commit.tree))
    list_unstaged()
end)

--[[
commands:
doctor

Scans every tracked instance and reports what roGit can't store (property types it doesn't understand,
instances with data outside of properties, known limits).
]]
arguments.createArgument("git", "doctor", "", function(...)
    local verbose = false
    for _, arg in ipairs({...}) do
        if arg == "-v" or arg == "--verbose" then verbose = true end
    end

    Handlers.load_ignore_patterns()
    local report = {unsupported = {}, unreadable = {}, special = {}, failed = {}, limits = {}}
    local class_counts = {}
    local total = 0
    local git_root = bash.getGitFolderRoot()

    local function visit(instance)
        Utilities.roYield()
        if instance == git_root or Handlers.is_ignored_instance(instance) then return end

        total += 1
        class_counts[instance.ClassName] = (class_counts[instance.ClassName] or 0) + 1
        local ok, err = pcall(instances.serialize_instance, instance, report)
        if not ok then
            report.failed[instance.ClassName .. ".(serialize)"] = {count = 1, detail = tostring(err)}
        end

        for _, child in ipairs(instance:GetChildren()) do
            visit(child)
        end
    end

    print("Scanning tracked instances...")
    for _, service in ipairs(bash.getTrackedRoots()) do
        visit(service)
    end

    local class_total = 0
    for _ in pairs(class_counts) do class_total += 1 end
    print(string.format("Checked %d instances of %d classes.", total, class_total))

    local function sorted_keys(map)
        local keys = {}
        for key in pairs(map) do table.insert(keys, key) end
        table.sort(keys)
        return keys
    end

    local problems = 0

    local special_classes = sorted_keys(report.special)
    if #special_classes > 0 then
        print("\nStored through special handling:")
        for _, key in ipairs(special_classes) do
            print(string.format("  %s x%d", key:gsub("%.$", ""), report.special[key].count))
        end
    end

    local unsupported = sorted_keys(report.unsupported)
    if #unsupported > 0 then
        problems += #unsupported
        print("\n\27[33mNot stored (roGit doesn't know this property type):\27[0m")
        for _, key in ipairs(unsupported) do
            local entry = report.unsupported[key]
            print(string.format("  %s  [%s] on %d instance%s", key, tostring(entry.detail), entry.count, entry.count == 1 and "" or "s"))
        end
    end

    local failed = sorted_keys(report.failed)
    if #failed > 0 then
        problems += #failed
        print("\n\27[31mFailed to read:\27[0m")
        for _, key in ipairs(failed) do
            print(string.format("  %s: %s", key, tostring(report.failed[key].detail)))
        end
    end

    local limits = sorted_keys(report.limits)
    if #limits > 0 then
        problems += #limits
        print("\n\27[33mKnown limits:\27[0m")
        for _, key in ipairs(limits) do
            print(string.format("  %s: %s", key:gsub("%.$", ""), tostring(report.limits[key].detail)))
        end
    end

    if verbose then
        local unreadable = sorted_keys(report.unreadable)
        print(string.format("\n%d reflected properties could not be read (usually internal or protected, harmless):", #unreadable))
        for _, key in ipairs(unreadable) do
            print("  " .. key)
        end
    end

    if problems == 0 then
        print("\nEverything in this place can be stored.")
    end
end)

--[[
commands:
config

change/set configurations for repository/global
]]
arguments.createArgument("git", "config", "", function(...)
    local tuple = {...}
    local scope = nil --// nil = local for writes, both for reads
    local action = nil
    local positional = {}

    for _, arg in ipairs(tuple) do
        if arg == "--global" or arg == "--system" then scope = "global"
        elseif arg == "--local" then scope = "local"
        elseif arg == "-l" or arg == "--list" then action = "list"
        elseif arg == "--get" then action = "get"
        elseif arg == "--unset" then action = "unset"
        elseif arg == "--get-all" then action = "get"
        elseif arg:sub(1, 1) ~= "-" then table.insert(positional, arg)
        end
    end

    local key, value = positional[1], positional[2]
    if not action then
        action = value ~= nil and "set" or (key and "get" or nil)
    end
    if not action then
        error("usage: git config [<options>] <name> [<value>]\n       git config --list | --get <name> | --unset <name>", 0)
    end

    --// Credentials and identity live in the plugin settings (per user, never inside the place)
    local sensitive_keys = {
        ["user.name"] = true, ["user.email"] = true, ["user.token"] = true, ["user.password"] = true,
        ["user_name"] = true, ["user_email"] = true, ["user_token"] = true, ["user_password"] = true,
    }
    local GLOBAL_KEYS = {"user.name", "user.email", "init.defaultBranch", "pull.rebase", "fetch.prune", "clean.requireForce",
        "commit.gpgsign", "tag.gpgSign", "core.hooksPath", "rogit.trace", "rogit.activityLog"}

    local function global_get(name)
        return Auth.getConfigValue((name:gsub("%.", "_"))) or Auth.getConfigValue(name)
    end
    local function global_set(name, v)
        assert(ACTIVE_PLUGIN, "fatal: global settings need the plugin to be running")
        ACTIVE_PLUGIN:SetSetting((name:gsub("%.", "_")), v)
    end

    local function is_global(name)
        return scope == "global" or (scope == nil and sensitive_keys[name])
    end

    if action == "list" then
        if scope ~= "local" then
            for _, name in ipairs(GLOBAL_KEYS) do
                local v = global_get(name)
                if v ~= nil and name ~= "user.token" then print(name .. "=" .. tostring(v)) end
            end
        end
        if scope ~= "global" and bash.getGitFolderRoot() then
            local conf = repo.read_config()
            local sections = {}
            for section in pairs(conf) do table.insert(sections, section) end
            table.sort(sections)
            for _, section in ipairs(sections) do
                local base, sub = section:match('^(%S+) "(.*)"$')
                local prefix = base and (base .. "." .. sub) or section
                local names = {}
                for name in pairs(conf[section]) do table.insert(names, name) end
                table.sort(names)
                for _, name in ipairs(names) do
                    print(prefix .. "." .. name .. "=" .. tostring(conf[section][name]))
                end
            end
        end
        return
    end

    assert(key and key:find(".", 1, true), "error: key does not contain a section: " .. tostring(key))

    if action == "get" then
        local v = nil
        if scope ~= "global" and bash.getGitFolderRoot() and not sensitive_keys[key] then
            local section, name = repo.config_section(key)
            local conf = repo.read_config()
            v = conf[section] and conf[section][name]
        end
        if v == nil and scope ~= "local" then
            v = global_get(key)
        end
        if v == nil then
            error("", 0) --// like git: nothing printed, failure
        end
        if key == "user.token" or key == "user.password" then
            v = "<hidden>"
        end
        print(tostring(v))
        return
    end

    if is_global(key) then
        if action == "unset" then
            global_set(key, nil)
        else
            global_set(key, value)
        end
        if action == "set" then
            print("Set '" .. key .. "' in plugin settings")
        end
        return
    end

    repo.require_root()
    local section, name = repo.config_section(key)
    local conf = repo.read_config()
    if action == "unset" then
        if not (conf[section] and conf[section][name] ~= nil) then
            error("", 0)
        end
        conf[section][name] = nil
        if next(conf[section]) == nil then conf[section] = nil end
    else
        conf[section] = conf[section] or {}
        conf[section][name] = value
    end
    repo.write_config(conf)
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

--// Commands that live in their own modules (they register themselves)
require(script.Parent.commands.history)
require(script.Parent.commands.inspect)
require(script.Parent.commands.signing)
require(script.Parent.commands.hooks)
require(script.Parent.commands.stash)
require(script.Parent.commands.worktree)
require(script.Parent.commands.submodule)
require(script.Parent.commands.activity)

return git
