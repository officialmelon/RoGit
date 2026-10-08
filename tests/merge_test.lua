local merge = loadModule("libs/merge.lua")
local fails = 0
local function eq(name, got, want)
	if got ~= want then fails += 1; print("FAIL", name, "got:", tostring(got), "want:", tostring(want)) end
end
local base = "a\nb\nc\nd\ne\n"
eq("noop", merge.merge_text(base, base, base), base)
eq("ours only", merge.merge_text(base, "a\nB\nc\nd\ne\n", base), "a\nB\nc\nd\ne\n")
eq("disjoint", merge.merge_text(base, "A\nb\nc\nd\ne\n", "a\nb\nc\nd\nE\n"), "A\nb\nc\nd\nE\n")
eq("same edit", merge.merge_text(base, "a\nX\nc\nd\ne\n", "a\nX\nc\nd\ne\n"), "a\nX\nc\nd\ne\n")
eq("conflict", merge.merge_text(base, "a\nX\nc\nd\ne\n", "a\nY\nc\nd\ne\n"), nil)
eq("conflict ours", merge.merge_text(base, "a\nX\nc\nd\ne\n", "a\nY\nc\nd\ne\n", "ours"), "a\nX\nc\nd\ne\n")
eq("conflict theirs", merge.merge_text(base, "a\nX\nc\nd\ne\n", "a\nY\nc\nd\ne\n", "theirs"), "a\nY\nc\nd\ne\n")
eq("insert both ends", merge.merge_text(base, "top\n"..base, base.."bottom\n"), "top\n"..base.."bottom\n")
eq("delete + edit elsewhere", merge.merge_text(base, "a\nc\nd\ne\n", "a\nb\nc\nd\nE\n"), "a\nc\nd\nE\n")
eq("delete same", merge.merge_text(base, "a\nc\nd\ne\n", "a\nc\nd\ne\n"), "a\nc\nd\ne\n")
eq("both insert same spot differently", merge.merge_text(base, "a\nx\nb\nc\nd\ne\n", "a\ny\nb\nc\nd\ne\n"), nil)
eq("no trailing newline", merge.merge_text("a\nb", "A\nb", "a\nB"), "A\nB")
eq("empty base", merge.merge_text("", "x\n", "x\ny\n"), nil)
-- bigger random-ish: two disjoint edits in 500 lines
local lines = {}
for i = 1, 500 do lines[i] = "line " .. i .. "\n" end
local big = table.concat(lines)
local o, t = table.clone(lines), table.clone(lines)
o[10] = "OURS\n"; o[400] = "OURS2\n"
t[200] = "THEIRS\n"; table.insert(t, 300, "inserted\n")
local expectLines = table.clone(lines)
expectLines[10] = "OURS\n"; expectLines[400] = "OURS2\n"; expectLines[200] = "THEIRS\n"; table.insert(expectLines, 300, "inserted\n")
eq("big", merge.merge_text(big, table.concat(o), table.concat(t)), table.concat(expectLines))

-- properties
local H = game:GetService("HttpService")
local function blob(props) return H:JSONEncode(props) end
local P = function(name, value, vt) return {name = name, value = value, valueType = vt or typeof(value)} end
local b = blob({P("ClassName","Part"), P("Name","X"), P("Transparency",0), P("Source","a\nb\nc\n")})
local o2 = blob({P("ClassName","Part"), P("Name","X"), P("Transparency",0.5), P("Source","A\nb\nc\n")})
local t2 = blob({P("ClassName","Part"), P("Name","Y"), P("Transparency",0), P("Source","a\nb\nC\n")})
local json, bad = merge.merge_properties(b, o2, t2)
local dec = H:JSONDecode(json)
local m = {}
for _, p in ipairs(dec) do m[p.name] = p.value end
eq("prop name", m.Name, "Y"); eq("prop transp", m.Transparency, 0.5); eq("prop source", m.Source, "A\nb\nC\n")
local o3 = blob({P("ClassName","Part"), P("Name","Z"), P("Transparency",0), P("Source","a\nb\nc\n")})
local j2, bad2 = merge.merge_properties(b, o3, t2)
eq("prop conflict", j2, nil); eq("prop conflict names", table.concat(bad2, ","), "Name")
-- attributes / tags
local ab = blob({P("ClassName","Part"), {name="_attributes", valueType="_attributes", value={{name="a",value=1,valueType="number"}}}, {name="_tags", valueType="_tags", value={"x"}}})
local ao = blob({P("ClassName","Part"), {name="_attributes", valueType="_attributes", value={{name="a",value=1,valueType="number"},{name="b",value=2,valueType="number"}}}, {name="_tags", valueType="_tags", value={"x","y"}}})
local at = blob({P("ClassName","Part"), {name="_attributes", valueType="_attributes", value={{name="a",value=5,valueType="number"}}}})
local jj = merge.merge_properties(ab, ao, at)
local d = H:JSONDecode(jj); local got = {}
for _, p in ipairs(d) do
	if p.name == "_attributes" then for _, a in ipairs(p.value) do got[#got+1] = a.name .. "=" .. a.value end
	elseif p.name == "_tags" then got[#got+1] = "tags:" .. table.concat(p.value, "+") end
end
-- theirs removed tag x, ours added y: the result keeps only y
eq("attrs/tags", table.concat(got, ";"), "a=5;b=2;tags:y")

-- indexes
local store = {}
local function wb(c) local k = "sha" .. #store; store[k] = c; store[#store+1] = c; return k end
local function rb(sha) return store[sha] end
local function mk(props) local c = blob(props); local k = "s:" .. c; store[k] = c; return {sha = k, mode = "100644"} end
local function read(sha) return store[sha] end
local baseI = {["Workspace/.properties"] = mk({P("ClassName","Workspace")}), ["Workspace/A"] = mk({P("ClassName","Part"),P("Name","A")}), ["Workspace/B"] = mk({P("ClassName","Part"),P("Name","B")})}
local oursI = {["Workspace/.properties"] = baseI["Workspace/.properties"], ["Workspace/A"] = mk({P("ClassName","Part"),P("Name","A2")}), ["Workspace/B"] = baseI["Workspace/B"], ["Workspace/Ours"] = mk({P("ClassName","Part"),P("Name","Ours")})}
local theirsI = {["Workspace/.properties"] = baseI["Workspace/.properties"], ["Workspace/A"] = baseI["Workspace/A"], ["Workspace/Theirs"] = mk({P("ClassName","Folder"),P("Name","Theirs")}), ["Workspace/Theirs/Kid"] = mk({P("ClassName","Part"),P("Name","Kid")})}
-- theirs deleted B
local idx, conflicts = merge.merge_indexes(baseI, oursI, theirsI, {read_blob = read, write_blob = function(c) local k = "s:" .. c; store[k] = c; return k end})
local names = {}
for p in pairs(idx) do names[#names+1] = p end
table.sort(names)
eq("index paths", table.concat(names, ","), "Workspace/.properties,Workspace/A,Workspace/Ours,Workspace/Theirs/.properties,Workspace/Theirs/Kid")
eq("index conflicts", #conflicts, 0)
-- modify/delete conflict
local oursB = {["Workspace/.properties"] = baseI["Workspace/.properties"], ["Workspace/A"] = baseI["Workspace/A"], ["Workspace/B"] = mk({P("ClassName","Part"),P("Name","B2")})}
local idx2, conf2 = merge.merge_indexes(baseI, oursB, theirsI, {read_blob = read, write_blob = function(c) local k = "s:" .. c; store[k] = c; return k end})
eq("mod/del conflict", #conf2, 1)
local idx3, conf3 = merge.merge_indexes(baseI, oursB, theirsI, {prefer="ours", read_blob = read, write_blob = function(c) local k = "s:" .. c; store[k] = c; return k end})
eq("mod/del prefer ours", idx3["Workspace/B"] ~= nil and #conf3 == 0, true)
print(fails == 0 and "ALL PASS" or ("FAILURES: " .. fails))
if fails > 0 then error("merge tests failed") end
