-- merge conflicts with markers, cherry-pick, revert, rebase (clean + conflicting), reflog, stash.
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
	return ok, table.concat(output, "\n")
end
local function find(path)
	local o = game
	for seg in path:gmatch("[^/]+") do o = o:FindFirstChild(seg) if not o then return nil end end
	return o
end
local function lines(n, overrides)
	local t = {}
	for i = 1, n do t[i] = (overrides and overrides[i]) or ("line " .. i) end
	return table.concat(t, "\n") .. "\n"
end
local function source() return find("Workspace/Code/Main").Source end
local function setSource(text) find("Workspace/Code/Main").Source = text end
local function head() return Handlers.get_ref("HEAD") end
local function subject(rev) return Handlers.read_commit(Handlers.resolve_revision(rev)).message:match("^[^\n]*") end

local folder = Instance.new("Folder"); folder.Name = "Code"; folder.Parent = ws
local main = Instance.new("Script"); main.Name = "Main"; main.Source = lines(10); main.Parent = folder
run("init")
run("add", ".")
run("commit", "-m", "base")

------------------------------------------------------------------ script conflict -> markers -> resolve -> commit
run("switch", "-c", "feature")
setSource(lines(10, {[3] = "FEATURE 3"}))
run("commit", "-am", "feature edits line 3")
run("switch", "master")
setSource(lines(10, {[3] = "MASTER 3"}))
run("commit", "-am", "master edits line 3")

local ok, out = run("merge", "feature")
check("script conflict stops the merge", not ok and out:find("CONFLICT %(content"))
local marked = source()
check("conflict markers written", marked:find("<<<<<<< HEAD\nMASTER 3\n=======\nFEATURE 3\n>>>>>>> feature\n", 1, true) ~= nil)
check("short status shows UU", select(2, run("status", "-s")):gsub("\27%[%d+m", ""):find("UU Workspace/Code/Main", 1, true))
setSource(lines(10, {[3] = "RESOLVED 3"}))
check("add marks resolved", run("add", "Workspace/Code/Main"))
check("status says conflicts fixed", select(2, run("status")):find("All conflicts fixed"))
ok, out = run("commit", "--no-edit")
check("commit concludes the merge", ok)
local merge_commit = Handlers.read_commit(head())
check("merge commit has both parents", #merge_commit.parents == 2)
check("merge message from MERGE_MSG", merge_commit.message:find("Merge branch 'feature'", 1, true) ~= nil)
check("merge state cleared", select(2, run("status")):find("nothing to commit"))

------------------------------------------------------------------ cherry-pick / revert
run("switch", "-c", "side")
setSource(lines(10, {[3] = "RESOLVED 3", [8] = "SIDE 8"}))
run("commit", "-am", "side edits line 8")
local side_commit = head()
run("switch", "master")
ok = run("cherry-pick", "side")
check("cherry-pick applies", ok and source():find("SIDE 8", 1, true) ~= nil)
check("cherry-pick keeps message", subject("HEAD") == "side edits line 8")

ok = run("revert", "HEAD")
check("revert undoes it", ok and not source():find("SIDE 8", 1, true))
check("revert message", subject("HEAD") == 'Revert "side edits line 8"')

------------------------------------------------------------------ reflog
local reflog = select(2, run("reflog"))
check("reflog lists revert first", reflog:find("HEAD@{0}: revert", 1, true) ~= nil)
check("HEAD@{1} resolves to the cherry-pick", Handlers.resolve_revision("HEAD@{1}") == Handlers.read_commit(head()).parents[1])

------------------------------------------------------------------ rebase (clean)
run("switch", "-c", "topic")
setSource(lines(10, {[3] = "RESOLVED 3", [10] = "TOPIC 10"}))
run("commit", "-am", "topic edits line 10")
run("switch", "master")
setSource(lines(10, {[1] = "MASTER 1", [3] = "RESOLVED 3"}))
run("commit", "-am", "master edits line 1")
local master_tip = head()
run("switch", "topic")
ok, out = run("rebase", "master")
check("rebase succeeds", ok and out:find("Successfully rebased", 1, true))
check("rebased commit sits on master", Handlers.read_commit(head()).parents[1] == master_tip)
check("rebase result has both edits", source():find("MASTER 1", 1, true) and source():find("TOPIC 10", 1, true))
check("still on topic", Handlers.get_current_branch() == "topic")
check("topic ref moved", Handlers.get_ref("refs/heads/topic") == head())

------------------------------------------------------------------ rebase (conflict -> continue)
run("switch", "-c", "conflicty", "master")
setSource(lines(10, {[1] = "CONFLICTY 1", [3] = "RESOLVED 3"}))
run("commit", "-am", "conflicty edits line 1")
run("switch", "master")
setSource(lines(10, {[1] = "MASTER AGAIN 1", [3] = "RESOLVED 3"}))
run("commit", "-am", "master edits line 1 again")
run("switch", "conflicty")
ok, out = run("rebase", "master")
check("conflicting rebase stops", not ok and out:find("could not apply", 1, true))
check("status shows rebase", select(2, run("status")):find("rebasing", 1, true))
setSource(lines(10, {[1] = "BOTH 1", [3] = "RESOLVED 3"}))
run("add", ".")
ok, out = run("rebase", "--continue")
check("rebase --continue finishes", ok and out:find("Successfully rebased", 1, true))
check("resolution committed", source():find("BOTH 1", 1, true) and subject("HEAD") == "conflicty edits line 1")
check("back on the branch", Handlers.get_current_branch() == "conflicty")

------------------------------------------------------------------ rebase --abort
run("switch", "master")
setSource(lines(10, {[2] = "MASTER 2", [3] = "RESOLVED 3", [1] = "MASTER AGAIN 1"}))
run("commit", "-am", "master edits line 2")
run("switch", "-c", "doomed", "master~1")
setSource(lines(10, {[2] = "DOOMED 2", [3] = "RESOLVED 3", [1] = "MASTER AGAIN 1"}))
run("commit", "-am", "doomed edits line 2")
local doomed_tip = head()
ok = run("rebase", "master")
check("doomed rebase stops", not ok)
check("rebase --abort", run("rebase", "--abort"))
check("abort restores branch", Handlers.get_current_branch() == "doomed" and head() == doomed_tip)
check("abort restores instances", source():find("DOOMED 2", 1, true) ~= nil and not source():find("<<<<<<<", 1, true))

------------------------------------------------------------------ stash
run("switch", "master")
local clean_source = source()
setSource(clean_source .. "-- work in progress\n")
local extra = Instance.new("Script"); extra.Name = "NewThing"; extra.Source = "-- new"; extra.Parent = find("Workspace/Code")
run("add", "Workspace/Code/NewThing")
local untracked = Instance.new("Folder"); untracked.Name = "Scratch"; untracked.Parent = ws

ok, out = run("stash")
check("stash saves", ok and out:find("Saved working directory and index state WIP on master", 1, true))
check("stash reverts the script", source() == clean_source)
check("stash removes the staged new instance", find("Workspace/Code/NewThing") == nil)
check("stash keeps untracked instances", find("Workspace/Scratch") ~= nil)
check("tree clean after stash", select(2, run("status")):find("nothing added to commit but untracked", 1, true))
check("stash list", select(2, run("stash", "list")):find("stash@{0}: WIP on master", 1, true))
check("stash show", select(2, run("stash", "show")):find("A\tWorkspace/Code/NewThing", 1, true))

ok = run("stash", "pop")
check("stash pop", ok)
check("pop restores the script", source() == clean_source .. "-- work in progress\n")
check("pop restores the new instance", find("Workspace/Code/NewThing") ~= nil)
check("pop drops the entry", select(2, run("stash", "list")) == "")
local st = select(2, run("status", "--porcelain"))
check("popped changes are unstaged, new instance staged", st:find(" M Workspace/Code/Main", 1, true) and st:find("A  Workspace/Code/NewThing", 1, true))

-- -u also takes untracked instances along
ok = run("stash", "push", "-u", "-m", "everything")
check("stash -u", ok and find("Workspace/Scratch") == nil and find("Workspace/Code/NewThing") == nil)
check("stash message", select(2, run("stash", "list")):find("stash@{0}: On master: everything", 1, true))
ok = run("stash", "apply")
check("apply brings untracked back", ok and find("Workspace/Scratch") ~= nil)
check("apply keeps the entry", select(2, run("stash", "list")) ~= "")
run("stash", "drop")
check("drop empties the list", select(2, run("stash", "list")) == "")

------------------------------------------------------------------ bisect
run("switch", "master")
run("stash", "clear")
run("reset", "--hard")
local marks = {}
for n = 1, 8 do
	setSource("version " .. n .. (n >= 6 and "\nBUG\n" or "\n"))
	run("commit", "-am", "step " .. n)
	marks[n] = head()
end
ok, out = run("bisect", "start", "HEAD", marks[1])
check("bisect start", ok and out:find("Bisecting", 1, true))
for _ = 1, 6 do
	local current = source()
	if current:find("BUG", 1, true) then
		ok, out = run("bisect", "bad")
	else
		ok, out = run("bisect", "good")
	end
	if out:find("is the first bad commit", 1, true) then break end
end
check("bisect finds the first bad commit", out:find(marks[6] .. " is the first bad commit", 1, true))
run("bisect", "reset")
check("bisect reset returns to the branch", Handlers.get_current_branch() == "master" and head() == marks[8])

print = realPrint
if failures > 0 then error(failures .. " check(s) failed") end
print("all history checks passed")
