-- End to end test of the git commands (init/add/commit/branch/merge/tag/reset, and clone/pull/push against a fake server).
local arguments = loadModule("arguments.lua")
loadModule("git.lua")
local Handlers = loadModule("libs/git_handlers.lua")
local Utilities = loadModule("libs/utilities.lua")
local instances = loadModule("libs/instances.lua")
local HS = game:GetService("HttpService")
local ws = game:GetService("Workspace")

local realPrint = print
local failures = 0
local function check(name, cond)
	if not cond then
		failures += 1
		realPrint("FAIL: " .. name)
	end
end

local output = {}
print = function(...) table.insert(output, table.concat({...}, " ")) end
loadModule("libs/output.lua").set(function(...) print(...) end, function(...) print(...) end)

-- returns success and everything the command printed (plus the error message when it failed)
local function run(...)
	output = {}
	local ok, err = pcall(arguments.execute, "git", ...)
	if not ok then table.insert(output, tostring(err)) end
	return ok, table.concat(output, "\n")
end

local function find(path)
	local o = game
	for seg in path:gmatch("[^/]+") do
		o = o:FindFirstChild(seg)
		if not o then return nil end
	end
	return o
end

--------------------------------------------------------------- utilities
check("scp url", Utilities.normalize_url("git@github.com:me/repo.git") == "https://github.com/me/repo.git")
check("bare url", Utilities.normalize_url("github.com/me/repo/") == "https://github.com/me/repo")

local bin = "\0\1\255\254abc\200"
local wrapped = instances.serialize_property(bin)
check("binary strings survive", instances.deserialize_property(wrapped, "string") == bin)

--------------------------------------------------------------- local workflow
local lines = {}
for i = 1, 20 do lines[i] = "line " .. i end
local folder = Instance.new("Folder"); folder.Name = "Stuff"; folder.Parent = ws
local main = Instance.new("Script"); main.Name = "Main"; main.Parent = folder
main.Source = table.concat(lines, "\n") .. "\n"
local cfg = Instance.new("StringValue"); cfg.Name = "Config"; cfg.Value = "base"; cfg.Parent = folder

check("init", run("init"))
check("add", run("add", "."))
local ok, out = run("commit", "-m", "base")
check("commit", ok and out:find("root%-commit"))
check("clean after commit", select(2, run("status")):find("nothing to commit"))

check("branch", run("branch", "feature"))
check("switch", run("switch", "feature"))
local feature = table.clone(lines); feature[2] = "FEATURE line 2"
find("Workspace/Stuff/Main").Source = table.concat(feature, "\n") .. "\n"
find("Workspace/Stuff/Config").Value = "feature-value"
local extra = Instance.new("Script"); extra.Name = "FeatureOnly"; extra.Source = "-- hi\n"; extra.Parent = find("Workspace/Stuff")
ok, out = run("diff")
check("diff shows script lines", out:find("FEATURE line 2") and out:find("feature%-value"))
run("add", ".")
check("commit on feature", run("commit", "-m", "feature work"))

check("switch back", run("switch", "master"))
check("feature-only instance removed", find("Workspace/Stuff/FeatureOnly") == nil)
local master = table.clone(lines); master[18] = "MASTER line 18"
find("Workspace/Stuff/Main").Source = table.concat(master, "\n") .. "\n"
check("commit on master", run("commit", "-am", "master work"))

ok, out = run("merge", "feature")
check("merge succeeds", ok and out:find("Merge made"))
local merged = find("Workspace/Stuff/Main").Source
check("both script edits merged", merged:find("FEATURE line 2", 1, true) and merged:find("MASTER line 18", 1, true))
check("config merged", find("Workspace/Stuff/Config").Value == "feature-value")
check("new instance merged", find("Workspace/Stuff/FeatureOnly") ~= nil)
check("clean after merge", select(2, run("status")):find("nothing to commit"))
check("merge commit has two parents", #Handlers.read_commit(Handlers.get_ref("HEAD")).parents == 2)

check("branch c1", run("switch", "-c", "c1"))
find("Workspace/Stuff/Config").Value = "c1-value"
run("commit", "-am", "c1")
run("switch", "master")
find("Workspace/Stuff/Config").Value = "master-value"
run("commit", "-am", "master config")
ok, out = run("merge", "c1")
check("conflicting merge stops", not ok and out:find("CONFLICT") and out:find("Automatic merge failed"))
check("conflict keeps our version in the place", find("Workspace/Stuff/Config").Value == "master-value")
check("status shows the unmerged path", select(2, run("status")):find("both modified:%s+Workspace/Stuff/Config"))
check("commit refused while unmerged", not run("commit", "-m", "nope"))
check("merge --abort", run("merge", "--abort"))
check("abort leaves a clean tree", select(2, run("status")):find("nothing to commit"))
ok = run("merge", "c1", "-X", "theirs")
check("-X theirs settles it", ok and find("Workspace/Stuff/Config").Value == "c1-value")

check("tag", run("tag", "v1"))
check("annotated tag", run("tag", "-a", "v2", "-m", "two"))
check("tag list", select(2, run("tag")) == "v1\nv2")
check("detached checkout", run("checkout", "v1"))
check("detached status", select(2, run("status")):find("HEAD detached"))
run("switch", "master")

local before = Handlers.get_ref("HEAD")
check("reset --hard HEAD~1", run("reset", "--hard", "HEAD~1"))
check("reset moved HEAD", Handlers.get_ref("HEAD") ~= before and Handlers.get_ref("HEAD") == Handlers.resolve_revision(before .. "~1"))
check("reset restored instances", find("Workspace/Stuff/Config").Value == "master-value")

--------------------------------------------------------------- remote (fake smart-HTTP server)
local function pkt(s) return string.format("%04x", #s + 4) .. s end

local serverObjects = {}
for sha, obj in pairs(Handlers.collectObjects(Handlers.resolve_revision("master"), nil)) do serverObjects[sha] = obj end
for sha, obj in pairs(Handlers.collectObjects(Handlers.resolve_revision("feature"), nil)) do serverObjects[sha] = obj end
local c_master = Handlers.resolve_revision("master")
local c_feature = Handlers.resolve_revision("feature")

local server = {
	refs = { ["refs/heads/master"] = c_master, ["refs/heads/dev"] = c_master, ["refs/heads/feature"] = c_feature },
	head = "refs/heads/master",
}
local lastWants, lastHaves = {}, {}
local uploadPackRequests = 0
local pushed = {}

HS.RequestAsync = function(_, req)
	if req.Method == "GET" then
		local names = {}
		for n in pairs(server.refs) do names[#names + 1] = n end
		table.sort(names)
		local body = pkt("# service=git-upload-pack\n") .. "0000"
		body ..= pkt(server.refs[server.head] .. " HEAD\0side-band-64k ofs-delta symref=HEAD:" .. server.head .. "\n")
		for _, n in ipairs(names) do body ..= pkt(server.refs[n] .. " " .. n .. "\n") end
		return { StatusCode = 200, Body = body .. "0000" }
	end

	if req.Url:find("receive%-pack") then
		local body, pos = req.Body, 1
		local report = pkt("unpack ok\n")
		while true do
			local len = tonumber(body:sub(pos, pos + 3), 16)
			if len == 0 then break end
			local line = body:sub(pos + 4, pos + len - 1):match("^([^%z\n]+)")
			local old, new, ref = line:match("^(%x+) (%x+) (.+)$")
			table.insert(pushed, {old = old, new = new, ref = ref})
			report ..= pkt("ok " .. ref .. "\n")
			pos += len
		end
		return { StatusCode = 200, Body = pkt("\1" .. report .. "0000") .. "0000" }
	end

	local wants, haves, body, pos = {}, {}, req.Body, 1
	while pos <= #body do
		local len = tonumber(body:sub(pos, pos + 3), 16)
		if len == 0 then pos += 4 else
			local line = body:sub(pos + 4, pos + len - 1)
			if line:match("^want ") then table.insert(wants, line:match("^want (%x+)")) end
			if line:match("^have ") then table.insert(haves, line:match("^have (%x+)")) end
			pos += len
		end
	end
	lastWants, lastHaves = wants, haves
	uploadPackRequests += 1

	local out, seen, stack = {}, {}, table.clone(wants)
	while #stack > 0 do
		local sha = table.remove(stack)
		if not seen[sha] and serverObjects[sha] then
			seen[sha] = true
			local o = serverObjects[sha]
			out[sha] = o
			if o.type == "commit" then
				stack[#stack + 1] = o.content:match("^tree (%x+)")
				for p in o.content:gmatch("\nparent (%x+)") do stack[#stack + 1] = p end
			elseif o.type == "tree" then
				for _, e in ipairs(Handlers.parse_tree(o.content)) do stack[#stack + 1] = e.sha end
			end
		end
	end
	local pack = Handlers.buildPackfile(out)
	local resp = pkt("NAK\n")
	for i = 1, #pack, 8000 do resp ..= pkt("\1" .. pack:sub(i, i + 7999)) end
	return { StatusCode = 200, Body = resp .. "0000" }
end

-- push from the repository we have
check("add remote", run("remote", "add", "origin", "git@example.com:me/place.git"))
check("remote url normalised", select(2, run("remote", "-v")):find("https://example.com/me/place.git", 1, true))
local currentMaster = Handlers.resolve_revision("master")
server.refs["refs/heads/master"] = Handlers.resolve_revision("master~1")
ok, out = run("push", "-u", "origin")
check("push", ok and out:find("master"))
check("push sent the right ref", pushed[1] and pushed[1].ref == "refs/heads/master" and pushed[1].new == currentMaster)
check("push updated tracking ref", Handlers.get_ref("refs/remotes/origin/master") == currentMaster)
check("push --delete", run("push", "origin", "--delete", "dev") and pushed[#pushed].new == ("0"):rep(40))

-- wipe the place and clone it again
server.refs["refs/heads/master"] = currentMaster
for sha, obj in pairs(Handlers.collectObjects(currentMaster, nil)) do serverObjects[sha] = obj end
local rememberedMain = find("Workspace/Stuff/Main").Source
game:GetService("ServerStorage"):FindFirstChild(".git"):Destroy()
find("Workspace/Stuff"):Destroy()
Handlers.clear_objects_cache()

ok, out = run("clone", "https://example.com/me/place")
check("clone", ok and out:find("cloned"))
check("clone checked out the symref branch", Handlers.get_current_branch() == "master")
check("clone restored instances", find("Workspace/Stuff/Main") and find("Workspace/Stuff/Main").Source == rememberedMain)
check("clone keeps other branches", Handlers.get_ref("refs/remotes/origin/feature") == c_feature)
check("clone is clean", select(2, run("status")):find("up to date with 'origin/master'"))

-- switching to a remote-only branch creates a tracking branch
ok = run("switch", "feature")
check("switch to remote branch", ok and Handlers.get_current_branch() == "feature")
run("switch", "master")

-- pull after the remote moved on
find("Workspace/Stuff/Main").Source = rememberedMain .. "-- more\n"
run("commit", "-am", "newer")
local newer = Handlers.get_ref("HEAD")
for sha, obj in pairs(Handlers.collectObjects(newer, nil)) do serverObjects[sha] = obj end
run("reset", "--hard", "HEAD~1")
server.refs["refs/heads/master"] = newer
local requestsBefore = uploadPackRequests
ok, out = run("pull")
check("pull fast-forwards", ok and out:find("Fast%-forward") and Handlers.get_ref("HEAD") == newer)
check("pull doesn't download commits we already own", uploadPackRequests == requestsBefore)
check("pull updated instances", find("Workspace/Stuff/Main").Source == rememberedMain .. "-- more\n")
check("pull again is a no-op", select(2, run("pull")):find("Already up to date"))

print = realPrint
if failures > 0 then
	error(failures .. " check(s) failed")
end
print("all workflow checks passed")
