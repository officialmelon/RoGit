-- Everyday commands behaving like git: rm/mv/restore/clean/reset/checkout paths, diff/log/show variants,
-- plumbing (cat-file, ls-files, rev-parse...), grep/blame/describe/shortlog, branch options, config, switch -.
local arguments = loadModule("arguments.lua")
loadModule("git.lua")
local Handlers = loadModule("libs/git_handlers.lua")
local ws = game:GetService("Workspace")

local realPrint = print
local failures = 0
local function check(name, cond)
	if not cond then failures += 1 realPrint("FAIL: " .. name) end
end

local output = {}
print = function(...) table.insert(output, table.concat({...}, " ")) end
loadModule("libs/output.lua").set(function(...) print(...) end, function(...) print(...) end)
local function run(...)
	output = {}
	local ok, err = pcall(arguments.execute, "git", ...)
	if not ok then table.insert(output, tostring(err)) end
	return ok, (table.concat(output, "\n"):gsub("\27%[%d+m", ""))
end
local function out(...) return select(2, run(...)) end
local function find(path)
	local o = game
	for seg in path:gmatch("[^/]+") do o = o:FindFirstChild(seg) if not o then return nil end end
	return o
end
local function new(class, name, parent, source)
	local i = Instance.new(class); i.Name = name; i.Parent = parent
	if source then i.Source = source end
	return i
end

local code = new("Folder", "Code", ws)
local a = new("Script", "A", code, "local x = 1\nprint(x)\n")
local b = new("Script", "B", code, "print('b')\n")

check("git --version", out("--version"):find("git version", 1, true))
check("git log --help", out("log", "--help"):find("git-log", 1, true))
check("commit without message refused", not run("init") or not run("commit", "-m", ""))
run("add", ".")
local ok, msg = run("commit")
check("commit without -m aborts like git", not ok and msg:find("empty commit message", 1, true))
run("commit", "-m", "first")
run("tag", "-a", "v1.0", "-m", "first release")

------------------------------------------------------------------ commit messages
ok, msg = run("commit", "-m", "nothing")
check("nothing to commit", not ok and msg:find("nothing to commit, working tree clean", 1, true))
a.Source = "local x = 2\nprint(x)\n"
ok, msg = run("commit", "-m", "unstaged only")
check("unstaged changes are not committed", not ok and msg:find("no changes added to commit", 1, true))
local untracked = new("Script", "Untracked", code, "-- u\n")
ok = run("commit", "-am", "second")
check("commit -a stages tracked changes", ok)
check("commit -a leaves untracked alone", out("status", "--porcelain"):find("?? Workspace/Code/Untracked", 1, true))
untracked:Destroy()

------------------------------------------------------------------ rm / mv / restore / clean
run("rm", "Workspace/Code/B")
check("rm removes the instance", find("Workspace/Code/B") == nil)
check("rm stages the deletion", out("status", "--porcelain"):find("D  Workspace/Code/B", 1, true))
run("restore", "--staged", "Workspace/Code/B")
check("restore --staged unstages", out("status", "--porcelain"):find(" D Workspace/Code/B", 1, true))
run("restore", "Workspace/Code/B")
check("restore brings the instance back", find("Workspace/Code/B") ~= nil and find("Workspace/Code/B").Source == "print('b')\n")

ok, msg = run("rm", "Workspace/Code")
check("rm of a parent needs -r", not ok and msg:find("recursively without -r", 1, true))

local folder2 = new("Folder", "Moved", ws)
run("add", ".")
run("commit", "-m", "folder")
run("mv", "Workspace/Code/B", "Workspace/Moved")
check("mv moves the instance", find("Workspace/Moved/B") ~= nil and find("Workspace/Code/B") == nil)
local st = out("status", "--porcelain")
check("mv stages both sides", st:find("D  Workspace/Code/B", 1, true) and st:find("A  Workspace/Moved/B", 1, true))
run("mv", "Workspace/Moved/B", "Workspace/Moved/Renamed")
check("mv renames", find("Workspace/Moved/Renamed") ~= nil)
run("commit", "-m", "moved")
local _ = folder2

local junk = new("Folder", "Junk", ws)
new("Folder", "Inner", junk)
ok, msg = run("clean")
check("clean needs -f", not ok and msg:find("requireForce", 1, true))
check("clean -n lists", out("clean", "-n"):find("Would remove Workspace/Junk", 1, true))
run("clean", "-f")
check("clean -f removes untracked", find("Workspace/Junk") == nil)

------------------------------------------------------------------ reset / checkout paths
a.Source = "changed\n"
run("add", ".")
run("reset", "Workspace/Code/A")
check("reset <path> unstages", out("status", "--porcelain"):find(" M Workspace/Code/A", 1, true))
run("checkout", "HEAD", "--", "Workspace/Code/A")
check("checkout <rev> -- <path> restores", a.Source == "local x = 2\nprint(x)\n")
run("checkout", "v1.0", "--", "Workspace/Code/A")
check("checkout <tag> -- <path> takes the old version", a.Source == "local x = 1\nprint(x)\n")
run("reset", "--hard")

------------------------------------------------------------------ diff / log / show
check("diff between commits", out("diff", "v1.0", "HEAD", "--name-status"):find("M\tWorkspace/Code/A", 1, true))
check("diff a..b", out("diff", "v1.0..HEAD", "--name-only"):find("Workspace/Code/A", 1, true))
check("diff --stat", out("diff", "HEAD~1", "HEAD", "--stat"):find("changed", 1, true))
a.Source = "worktree edit\n"
check("diff <commit> vs the place", out("diff", "HEAD", "--name-only") == "Workspace/Code/A")
run("restore", ".")

local log = out("log", "--format=%h %s")
check("log --format", log:find("^%x%x%x%x%x%x%x moved\n"))
check("log -- path", out("log", "--oneline", "--", "Workspace/Moved"):find("moved", 1, true) and not out("log", "--oneline", "--", "Workspace/Moved"):find("first", 1, true))
check("log -p shows script lines", out("log", "-p", "-1", "--", "Workspace/Code/A"):find("+ local x = 2", 1, true))
check("log --author", out("log", "--oneline", "--author=nobody") == "")
check("log --grep", out("log", "--oneline", "--grep=folder"):find("folder", 1, true))
check("log -n 2 --reverse", select(2, out("log", "--oneline", "-n", "2", "--reverse"):gsub("\n", "")) == 1)
run("switch", "-c", "side")
a.Source = "side\n"
run("commit", "-am", "side")
run("switch", "master")
b = find("Workspace/Moved/Renamed")
b.Source = "master\n"
run("commit", "-am", "master")
run("merge", "side", "-m", "merge side")
local graph = out("log", "--graph", "--oneline")
check("log --graph draws the merge", graph:find("|\\", 1, true) and graph:find("* ", 1, true))

check("show <rev>:<path>", out("show", "v1.0:Workspace/Code/A"):find("local x = 1", 1, true))
check("show tag", out("show", "v1.0", "--name-only"):find("tag v1.0", 1, true))

------------------------------------------------------------------ plumbing
check("rev-parse", out("rev-parse", "HEAD") == Handlers.get_ref("HEAD"))
check("rev-parse --short", #out("rev-parse", "--short", "HEAD") == 7)
check("rev-parse --abbrev-ref", out("rev-parse", "--abbrev-ref", "HEAD") == "master")
check("rev-parse HEAD^2", out("rev-parse", "HEAD^2") == Handlers.get_ref("refs/heads/side"))
check("cat-file -t", out("cat-file", "-t", "HEAD") == "commit")
check("cat-file -p HEAD^{tree}", out("cat-file", "-p", "HEAD^{tree}"):find("040000 tree %x+\tWorkspace"))
check("cat-file -p <rev>:<dir>", out("cat-file", "-p", "HEAD:Workspace"):find("\tCode", 1, true))
check("ls-files", out("ls-files"):find("Workspace/Code/A", 1, true))
check("ls-files -s", out("ls-files", "-s"):find("100644 %x+ 0\tWorkspace/Code/A"))
check("ls-tree -r --name-only", out("ls-tree", "-r", "--name-only", "HEAD"):find("Workspace/Moved/Renamed", 1, true))
check("rev-list --count", tonumber(out("rev-list", "--count", "HEAD")) >= 6)
check("merge-base", out("merge-base", "master", "side") == Handlers.get_ref("refs/heads/side"))
check("merge-base --is-ancestor", run("merge-base", "--is-ancestor", "v1.0", "HEAD") and not run("merge-base", "--is-ancestor", "HEAD", "v1.0"))
check("show-ref --tags", out("show-ref", "--tags"):find("refs/tags/v1.0", 1, true))
check("symbolic-ref", out("symbolic-ref", "HEAD") == "refs/heads/master")
run("update-ref", "refs/heads/pointer", "v1.0")
check("update-ref", Handlers.resolve_revision("pointer") == Handlers.resolve_revision("v1.0"))

------------------------------------------------------------------ grep / blame / describe / shortlog
check("grep", out("grep", "print"):find("Workspace/Code/A:print(x)", 1, true) or out("grep", "side"):find("Workspace/Code/A:side", 1, true))
check("grep -n", out("grep", "-n", "master"):find("Workspace/Moved/Renamed:1:master", 1, true))
check("grep in a commit", out("grep", "local x = 1", "v1.0"):find("v1.0:Workspace/Code/A", 1, true))
check("grep without match fails", not run("grep", "definitely-not-there"))
local blame = out("blame", "Workspace/Code/A")
check("blame", blame:find("side", 1, true) and blame:find("%x%x%x%x%x%x%x%x %("))
check("describe", out("describe"):find("^v1%.0%-%d+%-g%x+$"))
check("describe exact", out("describe", "v1.0") == "v1.0")
check("shortlog -s", out("shortlog", "-s"):find("roGit", 1, true))

------------------------------------------------------------------ branches / switch - / config
run("branch", "feature-x")
check("branch --merged", out("branch", "--merged"):find("feature-x", 1, true))
run("switch", "feature-x")
a.Source = "unmerged work\n"
run("commit", "-am", "unmerged")
run("switch", "-")
check("switch - goes back", Handlers.get_current_branch() == "master")
check("branch --no-merged", out("branch", "--no-merged"):find("feature-x", 1, true))
ok, msg = run("branch", "-d", "feature-x")
check("branch -d refuses unmerged", msg:find("not fully merged", 1, true))
run("branch", "-c", "feature-x", "feature-copy")
check("branch -c copies", Handlers.get_ref("refs/heads/feature-copy") == Handlers.get_ref("refs/heads/feature-x"))
check("branch --contains", out("branch", "--contains", "v1.0"):find("master", 1, true))

run("config", "core.autocrlf", "false")
check("config get", out("config", "core.autocrlf") == "false")
check("config --list", out("config", "--list"):find("core.autocrlf=false", 1, true))
run("config", "--unset", "core.autocrlf")
check("config --unset", not run("config", "--get", "core.autocrlf"))
run("config", "branch.master.remote", "origin")
check("config with subsections", out("config", "branch.master.remote") == "origin")

------------------------------------------------------------------ reflog recovery
local before_reset = Handlers.get_ref("HEAD")
run("reset", "--hard", "HEAD~2")
check("reset moved back", Handlers.get_ref("HEAD") ~= before_reset)
run("reset", "--hard", "HEAD@{1}")
check("HEAD@{1} recovers the lost commits", Handlers.get_ref("HEAD") == before_reset)
check("ORIG_HEAD", Handlers.resolve_revision("ORIG_HEAD") ~= nil)

print = realPrint
if failures > 0 then error(failures .. " check(s) failed") end
print("all parity checks passed")
