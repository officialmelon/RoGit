-- Signed commits/tags, hooks, the Studio "editor" (commit/tag messages, rebase -i).
local arguments = loadModule("arguments.lua")
local git = loadModule("git.lua")
local Handlers = loadModule("libs/git_handlers.lua")
local editor = loadModule("libs/editor.lua")
local hooks = loadModule("libs/hooks.lua")
local repo = loadModule("libs/repo.lua")
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
local function head() return Handlers.get_ref("HEAD") end
local function subject(rev) return Handlers.read_commit(Handlers.resolve_revision(rev)).message:match("^[^\n]*") end

-- a fake plugin for settings, and the bits of Roblox key generation uses
local settings = {}
local fakePlugin = {
	GetSetting = function(_, key) return settings[key] end,
	SetSetting = function(_, key, value) settings[key] = value end,
	OpenScript = function() end,
}
git.setPlugin(fakePlugin)
Random = { new = function() return { NextNumber = function() return math.random() end } end }
settings.user_email = "dev@example.com"
settings.user_name = "Dev"

-- hooks are ModuleScripts; here their Source is run directly
hooks.loader = function(module) return loadstring(module.Source)() end

local code = Instance.new("Folder"); code.Name = "Code"; code.Parent = ws
local main = Instance.new("Script"); main.Name = "Main"; main.Source = "print(1)\n"; main.Parent = code
run("init")
run("add", ".")
run("commit", "-m", "base")

------------------------------------------------------------------ signing
local ok, msg = run("commit", "--allow-empty", "-S", "-m", "signed without key")
check("signing without a key explains how to get one", not ok and msg:find("signing-key generate", 1, true))

ok, msg = run("signing-key", "generate")
check("generate a key", ok and msg:find("ssh-ed25519 AAAA", 1, true) and msg:find("SHA256:", 1, true))
local public_line = msg:match("(ssh%-ed25519 %S+)")

main.Source = "print(2)\n"
check("signed commit", run("commit", "-a", "-S", "-m", "signed"))
local raw = Handlers.read_object(head()).content
check("commit has a gpgsig header", raw:find("\ngpgsig -----BEGIN SSH SIGNATURE-----\n ", 1, true) ~= nil)
check("signed commit still reads normally", subject("HEAD") == "signed" and #Handlers.read_commit(head()).parents == 1)
ok, msg = run("verify-commit", "HEAD")
check("verify-commit", ok and msg:find('Good "git" signature for dev@example.com with ED25519 key SHA256:', 1, true))
check("unsigned commit fails verification", not run("verify-commit", "HEAD~1"))
check("log --show-signature / %G?", out("log", "--format=%G? %s", "-2") == "G signed\nN base")

-- tampering breaks the signature
local tampered = raw:gsub("\n\nsigned", "\n\nsigned (changed)")
local fake_sha = Handlers.write_object("commit", tampered)
check("tampered commit is BAD", select(1, repo.verify_signature(fake_sha)) == "B")

-- everything signed by default
run("config", "--global", "commit.gpgsign", "true")
main.Source = "print(3)\n"
run("commit", "-am", "auto signed")
check("commit.gpgsign signs", select(1, repo.verify_signature(head())) == "G")
run("config", "--global", "--unset", "commit.gpgsign")

check("signed tag", run("tag", "-s", "v1", "-m", "release"))
check("verify-tag", out("verify-tag", "v1"):find("Good", 1, true))

-- for the independent check in tests/verify_signature.py
realPrint("SIGNED_COMMIT_BEGIN")
realPrint(raw)
realPrint("SIGNED_COMMIT_END")
realPrint("PUBLIC_KEY " .. tostring(public_line))

------------------------------------------------------------------ hooks
local hookFolder = game:GetService("ServerStorage"):FindFirstChild(".git"):FindFirstChild("hooks")
local function makeHook(name, source)
	local module = Instance.new("ModuleScript")
	module.Name = name
	module.Source = source
	module.Parent = hookFolder
	return module
end

HookState = {}
local preCommit = makeHook("pre-commit", [[
	return function(context)
		if HookState.blockCommits then return false, "commits are blocked" end
		return true
	end
]])
HookState.blockCommits = true
main.Source = "print(4)\n"
ok, msg = run("commit", "-am", "blocked")
check("pre-commit can stop a commit", not ok and msg:find("pre-commit' hook declined: commits are blocked", 1, true))
check("--no-verify skips hooks", run("commit", "-am", "unblocked", "--no-verify"))
HookState.blockCommits = false
preCommit:Destroy()

makeHook("commit-msg", [[
	return function(context)
		return "[tagged] " .. context.message
	end
]])
main.Source = "print(5)\n"
run("commit", "-am", "message")
check("commit-msg can rewrite the message", subject("HEAD") == "[tagged] message")
hookFolder:FindFirstChild("commit-msg"):Destroy()

makeHook("post-commit", [[
	return function(context)
		HookState.postCommitRan = (HookState.postCommitRan or 0) + 1
		context.git("tag", "after-commit")
	end
]])
main.Source = "print(6)\n"
run("commit", "-am", "post")
check("post-commit runs and can run git", HookState.postCommitRan == 1 and Handlers.get_ref("refs/tags/after-commit") == head())
hookFolder:FindFirstChild("post-commit"):Destroy()

check("git hook create", run("hook", "create", "pre-push") and hookFolder:FindFirstChild("pre-push") ~= nil)
check("git hook list", out("hook", "list") == "pre-push")
check("git hook run", run("hook", "run", "pre-push"))
check("git hook remove", run("hook", "remove", "pre-push") and hookFolder:FindFirstChild("pre-push") == nil)

------------------------------------------------------------------ editor: tag message
editor.provider = function(text, name)
	if name == "TAG_EDITMSG" then return "Release two\n" .. text end
	return text
end
check("tag -a without -m opens the editor", run("tag", "-a", "v2"))
local tagObj = Handlers.read_object(Handlers.get_ref("refs/tags/v2"))
check("tag message from the editor", tagObj.content:find("\n\nRelease two\n", 1, true) ~= nil and not tagObj.content:find("--", 1, true))

------------------------------------------------------------------ rebase -i
for n = 1, 4 do
	local value = Instance.new("StringValue"); value.Name = "S" .. n; value.Value = "step " .. n; value.Parent = code
	run("add", ".")
	run("commit", "-m", "step " .. n)
end
local base = Handlers.resolve_revision("HEAD~4")
local todoSeen = nil
editor.provider = function(text, name)
	if name == "git-rebase-todo" then
		todoSeen = text
		local lines = {}
		for line in text:gmatch("[^\n]+") do
			if not line:find("^%-%-") then table.insert(lines, line) end
		end
		-- reorder: drop step 1, reword step 2, squash step 4 into step 3
		local function sha(n) return lines[n]:match("^pick (%x+)") end
		return table.concat({
			"drop " .. sha(1),
			"reword " .. sha(2),
			"pick " .. sha(3),
			"fixup " .. sha(4),
		}, "\n")
	elseif name == "COMMIT_EDITMSG" then
		return "step 2 (reworded)\n"
	end
	return text
end
ok, msg = run("rebase", "-i", "HEAD~4")
check("rebase -i shows the todo", todoSeen and todoSeen:find("^pick %x+ step 1\npick %x+ step 2\npick %x+ step 3\npick %x+ step 4\n") ~= nil)
check("rebase -i succeeds", ok and msg:find("Successfully rebased", 1, true))
check("rebase -i result", subject("HEAD") == "step 3" and subject("HEAD~1") == "step 2 (reworded)" and Handlers.resolve_revision("HEAD~2") == base)
check("dropped commit's instance is gone", code:FindFirstChild("S1") == nil)
check("fixup folded its change in", code:FindFirstChild("S3") ~= nil and code:FindFirstChild("S4") ~= nil and code:FindFirstChild("S2") ~= nil)

-- edit stops, then continue
editor.provider = function(text, name)
	if name == "git-rebase-todo" then
		local first = text:match("^pick (%x+)")
		return "edit " .. first .. "\n" .. text:gsub("^[^\n]*\n", "")
	end
	return text
end
ok, msg = run("rebase", "-i", "HEAD~2")
check("edit stops the rebase", ok and msg:find("You can amend the commit now", 1, true))
check("status during edit", out("status"):find("rebasing", 1, true))
check("amend during edit", run("commit", "--amend", "-m", "step 2 (amended)"))
ok, msg = run("rebase", "--continue")
check("continue after edit", ok and msg:find("Successfully rebased", 1, true))
check("amended message kept", subject("HEAD~1") == "step 2 (amended)" and subject("HEAD") == "step 3")
editor.provider = nil

------------------------------------------------------------------ trace / activity log
local traced = out("-c", "rogit.trace=1", "commit", "--allow-empty", "-m", "traced")
check("trace shows commands", traced:find("built-in: git commit --allow-empty -m traced", 1, true) ~= nil)
check("trace shows timing", traced:find("trace perf:", 1, true) ~= nil)
check("trace kinds filter", not out("-c", "rogit.trace=http", "status"):find("trace run", 1, true))
check("no trace by default", not out("status"):find("trace", 1, true))

run("this-is-not-a-command")
run("switch", "does-not-exist")
local activity = out("activity", "-n", "3")
check("activity lists recent commands", activity:find("git switch does-not-exist", 1, true) and activity:find("failed", 1, true))
check("activity newest first", activity:find("git switch does%-not%-exist") < activity:find("git this%-is%-not%-a%-command"))
check("activity --failed", not out("activity", "--failed"):find("  ok  ", 1, true))
check("activity --grep", out("activity", "--grep=traced"):find("-m traced", 1, true) ~= nil)
run("config", "rogit.activityLog", "false")
local before = out("activity", "--all")
run("status")
check("activity can be turned off", out("activity", "--all") == before)
check("activity --clear", run("activity", "--clear") and out("activity") == "No activity recorded yet.")

print = realPrint
if failures > 0 then error(failures .. " check(s) failed") end
print("all tools checks passed")
