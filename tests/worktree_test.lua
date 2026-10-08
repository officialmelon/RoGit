-- Worktrees, submodules, git -C / -c.
local arguments = loadModule("arguments.lua")
local git = loadModule("git.lua")
local Handlers = loadModule("libs/git_handlers.lua")
local Remote = loadModule("libs/git_remote.lua")
local bash = loadModule("bash.lua")
local ws = game:GetService("Workspace")
local rs = game:GetService("ReplicatedStorage")
local ss = game:GetService("ServerStorage")

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

local code = Instance.new("Folder"); code.Name = "Code"; code.Parent = ws
local main = Instance.new("Script"); main.Name = "Main"; main.Source = "print(1)\n"; main.Parent = code
run("init")
run("add", ".")
run("commit", "-m", "base")
local base = Handlers.get_ref("HEAD")

------------------------------------------------------------------ worktree add / list
local ok, msg = run("worktree", "add", "hotfix")
check("worktree add", ok and msg:find("new branch 'hotfix'", 1, true) and msg:find("HEAD is now at", 1, true))
local holder = ss:FindFirstChild("RoGitWorktrees")
local wt = holder and holder:FindFirstChild("hotfix")
check("worktree folder has the services", wt and wt:FindFirstChild("Workspace") and wt.Workspace:FindFirstChild("Code") and wt.Workspace.Code:FindFirstChild("Main"))
check("worktree script content", wt and wt.Workspace.Code.Main.Source == "print(1)\n")
check("worktree is clean", out("-C", "hotfix", "status"):find("nothing to commit", 1, true) ~= nil)
check("worktree on its branch", out("-C", "hotfix", "rev-parse", "--abbrev-ref", "HEAD") == "hotfix")
check("main still on master", out("rev-parse", "--abbrev-ref", "HEAD") == "master")
check("place status ignores worktree folder", out("status"):find("nothing to commit", 1, true) ~= nil)

local list = out("worktree", "list")
check("worktree list", list:find("^game%s+%x+ %[master%]") and list:find("ServerStorage.RoGitWorktrees.hotfix%s+%x+ %[hotfix%]"))

------------------------------------------------------------------ commit inside a worktree
wt.Workspace.Code.Main.Source = "print('fixed')\n"
check("worktree sees its change", out("-C", "hotfix", "status"):find("Workspace/Code/Main", 1, true) ~= nil)
check("place doesn't see worktree change", out("status"):find("nothing to commit", 1, true) ~= nil)
check("commit in worktree", run("-C", "hotfix", "commit", "-am", "fix"))
check("branch moved", Handlers.get_ref("refs/heads/hotfix") ~= base and Handlers.get_ref("HEAD") == base)
check("place untouched", main.Source == "print(1)\n")
check("worktree reflog separate", out("-C", "hotfix", "reflog", "-1"):find("fix", 1, true) ~= nil and not out("reflog", "-1"):find("fix", 1, true))

-- the branch can't be checked out twice
ok, msg = run("switch", "hotfix")
check("switch to branch used by worktree refused", not ok and msg:find("already used by worktree", 1, true))
ok, msg = run("branch", "-D", "hotfix")
check("delete branch used by worktree refused", msg:find("checked out at", 1, true) ~= nil and Handlers.get_ref("refs/heads/hotfix"))

-- merge the worktree's branch from the place
check("merge worktree branch", run("merge", "hotfix"))
check("merged into place", main.Source == "print('fixed')\n")

------------------------------------------------------------------ detached worktree, lock, remove, prune
check("detached worktree", run("worktree", "add", "--detach", "old", base))
check("detached worktree content", holder.old.Workspace.Code.Main.Source == "print(1)\n")
check("detached worktree HEAD", out("-C", "old", "rev-parse", "HEAD") == base)
check("lock", run("worktree", "lock", "--reason", "keep", "old"))
check("list shows locked", out("worktree", "list"):find("locked", 1, true) ~= nil)
check("locked can't be removed", not run("worktree", "remove", "old"))
check("unlock", run("worktree", "unlock", "old"))
holder.old.Workspace.Code.Main.Source = "dirty"
check("dirty worktree needs --force", not run("worktree", "remove", "old"))
check("remove --force", run("worktree", "remove", "--force", "old") and holder:FindFirstChild("old") == nil)

holder.hotfix:Destroy()
check("prunable", out("worktree", "list"):find("prunable", 1, true) ~= nil)
run("worktree", "prune")
check("pruned", not out("worktree", "list"):find("hotfix", 1, true))
check("branch freed after prune", run("branch", "-d", "hotfix"))

------------------------------------------------------------------ -c
check("-c overrides config", out("-c", "user.name=Someone", "config", "user.name") == "Someone")
run("-c", "user.name=Temp Person", "commit", "--allow-empty", "-m", "by temp")
check("-c used for commit author", Handlers.read_commit(Handlers.get_ref("HEAD")).author:find("Temp Person", 1, true) ~= nil)

------------------------------------------------------------------ submodules
-- a library repository, made inside a folder (its objects go to the shared store)
local libSource = Instance.new("Folder"); libSource.Name = "LibSource"; libSource.Parent = ss
local function inLib(...)
	return bash.withContext({kind = "submodule", name = "libsource", root = libSource}, run, ...)
end
inLib("init", "-b", "main")
local libRS = Instance.new("Folder"); libRS.Name = "ReplicatedStorage"; libRS.Parent = libSource
local libSS = Instance.new("Folder"); libSS.Name = "ServerStorage"; libSS.Parent = libSource
local marker = Instance.new("StringValue"); marker.Name = ".rogit_project"; marker.Value = "lib"; marker.Parent = libSS
local libModule = Instance.new("ModuleScript"); libModule.Name = "Lib"; libModule.Source = "return 1\n"; libModule.Parent = libRS
check("lib add", inLib("add", "."))
check("lib commit", inLib("commit", "-m", "lib v1"))
local libV1 = bash.withContext({kind = "submodule", name = "libsource", root = libSource}, Handlers.get_ref, "HEAD")
libModule.Source = "return 2\n"
inLib("commit", "-am", "lib v2")
local libV2 = bash.withContext({kind = "submodule", name = "libsource", root = libSource}, Handlers.get_ref, "HEAD")
check("lib has two commits", libV1 and libV2 and libV1 ~= libV2)
libSource.Parent = nil -- keep it out of the place's work tree

-- fake the network: the "remote" serves the library's history
local remoteHead = libV1
Remote.discoverRefs = function(url)
	return {["refs/heads/main"] = remoteHead, HEAD = remoteHead}, {symrefs = {HEAD = "refs/heads/main"}}
end
Remote.fetchPackfile = function() return "PACK" end
Remote.unpackObjects = function()
	local objects = {}
	local types = {commit = 1, tree = 2, blob = 3, tag = 4}
	for sha, obj in pairs(Handlers.collectObjects(remoteHead, nil)) do
		objects[sha] = {objType = types[obj.type], content = obj.content}
	end
	return nil, objects
end

local packages = Instance.new("Folder"); packages.Name = "Packages"; packages.Parent = rs
run("add", ".")
run("commit", "-m", "packages")
ok, msg = run("submodule", "add", "https://example.com/lib.git", "ReplicatedStorage/Packages/Lib")
check("submodule add", ok)
if not ok then realPrint(msg) end
local subFolder = packages:FindFirstChild("Lib")
check("submodule folder", subFolder and subFolder:GetAttribute("RoGitSubmodule") == "ReplicatedStorage/Packages/Lib")
check("submodule contents", subFolder and subFolder:FindFirstChild("ReplicatedStorage") and subFolder.ReplicatedStorage:FindFirstChild("Lib") and subFolder.ReplicatedStorage.Lib.Source == "return 1\n")
local index = Handlers.read_index()
check("gitlink staged", index["ReplicatedStorage/Packages/Lib"] and index["ReplicatedStorage/Packages/Lib"].mode == "160000" and index["ReplicatedStorage/Packages/Lib"].sha == libV1)
check("submodule contents not staged in the place", index["ReplicatedStorage/Packages/Lib/ReplicatedStorage/Lib"] == nil)
check(".gitmodules staged", index["ServerStorage/.gitmodules"] ~= nil)
local gitmodules = ss:FindFirstChild(".gitmodules")
check(".gitmodules content", gitmodules and gitmodules.Value:find('[submodule "ReplicatedStorage/Packages/Lib"]', 1, true) and gitmodules.Value:find("url = https://example.com/lib.git", 1, true))
check("commit with submodule", run("commit", "-m", "add lib"))
local tree = Handlers.read_object(Handlers.read_commit(Handlers.get_ref("HEAD")).tree)
check("clean after submodule commit", out("status"):find("nothing to commit", 1, true) ~= nil)
check("submodule status", out("submodule", "status"):find("^ " .. libV1 .. " ReplicatedStorage/Packages/Lib") ~= nil)
check("submodule is clean inside", out("-C", "ReplicatedStorage/Packages/Lib", "status"):find("nothing to commit", 1, true) ~= nil)

-- a real gitlink in the tree
local function find_gitlink(treeSha, path)
	local first, rest = path:match("^([^/]+)/?(.*)$")
	for _, entry in ipairs(Handlers.parse_tree(Handlers.read_object(treeSha).content)) do
		if entry.name == first then
			if rest == "" then return entry end
			return find_gitlink(entry.sha, rest)
		end
	end
end
local link = find_gitlink(Handlers.read_commit(Handlers.get_ref("HEAD")).tree, "ReplicatedStorage/Packages/Lib")
check("tree has mode 160000 gitlink", link and link.mode == "160000" and link.sha == libV1)

-- the submodule moves on: the place sees a modified submodule
remoteHead = libV2
check("update --remote", run("submodule", "update", "--remote"))
check("submodule at v2", subFolder.ReplicatedStorage.Lib.Source == "return 2\n")
check("place sees new submodule commit", out("status"):find("ReplicatedStorage/Packages/Lib", 1, true) ~= nil)
check("submodule status +", out("submodule", "status"):find("^%+" .. libV2) ~= nil)
check("diff shows subproject commit", out("diff"):find("Subproject commit " .. libV2, 1, true) ~= nil)
run("add", "ReplicatedStorage/Packages/Lib")
check("commit submodule bump", run("commit", "-m", "bump lib"))

-- going back in the place's history: update puts the submodule back
run("switch", "--detach", "HEAD~1")
check("submodule recorded at v1 after checkout", Handlers.read_index()["ReplicatedStorage/Packages/Lib"].sha == libV1)
run("submodule", "update")
check("submodule update checks out recorded commit", subFolder.ReplicatedStorage.Lib.Source == "return 1\n")
run("switch", "master")
run("submodule", "update")
check("back to v2", subFolder.ReplicatedStorage.Lib.Source == "return 2\n")

-- foreach, deinit, update --init
check("foreach", out("submodule", "foreach", "git", "rev-parse", "HEAD"):find("Entering 'ReplicatedStorage/Packages/Lib'\n" .. libV2, 1, true) ~= nil)
check("deinit", run("submodule", "deinit", "ReplicatedStorage/Packages/Lib") and #subFolder:GetChildren() == 0)
check("status after deinit", out("submodule", "status"):find("^%-") ~= nil)
check("place clean after deinit", out("status"):find("nothing to commit", 1, true) ~= nil)
check("update --init", run("submodule", "update", "--init") and subFolder:FindFirstChild("ReplicatedStorage") and subFolder.ReplicatedStorage.Lib.Source == "return 2\n")

-- a commit inside the submodule
subFolder.ReplicatedStorage.Lib.Source = "return 3\n"
check("commit in submodule", run("-C", "ReplicatedStorage/Packages/Lib", "commit", "-am", "local change"))
check("place sees submodule commit", out("status"):find("ReplicatedStorage/Packages/Lib", 1, true) ~= nil)

-- merging two submodule bumps: the newer commit wins when one contains the other
local merge = loadModule("libs/merge.lua")
local function link(sha) return {["RS/Lib"] = {sha = sha, mode = "160000"}} end
local opts = {read_blob = function() return nil end, write_blob = function() return "x" end,
	is_ancestor = function(a, b) return a == "o" and b == "t" end}
local result, conflicts = merge.merge_indexes(link("b"), link("o"), link("t"), opts)
check("submodule merge takes the newer commit", result["RS/Lib"].sha == "t" and #conflicts == 0)
opts.is_ancestor = function() return false end
result, conflicts = merge.merge_indexes(link("b"), link("o"), link("t"), opts)
check("diverged submodules conflict", #conflicts == 1 and conflicts[1].reason:find("submodule", 1, true))

print = realPrint
if failures > 0 then error(failures .. " check(s) failed") end
print("all worktree checks passed")
