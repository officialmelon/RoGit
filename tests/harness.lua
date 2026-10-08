-- Minimal Roblox mock so roGit modules can run under plain Luau (see tests/build.py).
-- Provides just enough of Instance/game/HttpService (with a tiny JSON codec) for the git commands to run.
local SRC = SRC_ROOT
SOURCES = SOURCES or {}
GLOBALS = getfenv()

---------------------------------------------------------------- JSON
local function jencode(v)
	local t = type(v)
	if t == "nil" then return "null"
	elseif t == "boolean" then return tostring(v)
	elseif t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then error("Can't convert to JSON") end
		if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
		return string.format("%.17g", v)
	elseif t == "string" then
		if not utf8.len(v) then error("Can't convert invalid utf8 to JSON") end
		return '"' .. v:gsub('[%c"\\]', function(c)
			local m = {['"']='\\"', ['\\']='\\\\', ['\n']='\\n', ['\r']='\\r', ['\t']='\\t'}
			return m[c] or string.format("\\u%04x", c:byte())
		end) .. '"'
	elseif t == "table" then
		local n = 0
		for _ in pairs(v) do n += 1 end
		if n == #v then
			local out = {}
			for i = 1, #v do out[i] = jencode(v[i]) end
			return "[" .. table.concat(out, ",") .. "]"
		end
		local keys = {}
		for k in pairs(v) do table.insert(keys, tostring(k)) end
		table.sort(keys)
		local out = {}
		for _, k in ipairs(keys) do
			local val = v[k]
			if val == nil then val = v[tonumber(k)] end
			table.insert(out, jencode(k) .. ":" .. jencode(val))
		end
		return "{" .. table.concat(out, ",") .. "}"
	end
	error("Can't convert " .. t .. " to JSON")
end

local function jdecode(s)
	local pos = 1
	local function ws() pos = s:find("[^ \n\r\t]", pos) or #s + 1 end
	local value
	local function str()
		local out = {}
		pos += 1
		while true do
			local c = s:sub(pos, pos)
			if c == '"' then pos += 1 break
			elseif c == "\\" then
				local n = s:sub(pos + 1, pos + 1)
				local m = {n="\n", r="\r", t="\t", b="\b", f="\f"}
				if n == "u" then
					out[#out + 1] = utf8.char(tonumber(s:sub(pos + 2, pos + 5), 16)); pos += 6
				else
					out[#out + 1] = m[n] or n; pos += 2
				end
			else out[#out + 1] = c; pos += 1 end
		end
		return table.concat(out)
	end
	function value()
		ws()
		local c = s:sub(pos, pos)
		if c == "{" then
			local r = {}
			pos += 1; ws()
			if s:sub(pos, pos) == "}" then pos += 1 return r end
			while true do
				ws(); local k = str(); ws(); pos += 1
				r[k] = value(); ws()
				local d = s:sub(pos, pos); pos += 1
				if d == "}" then break end
			end
			return r
		elseif c == "[" then
			local r = {}
			pos += 1; ws()
			if s:sub(pos, pos) == "]" then pos += 1 return r end
			while true do
				r[#r + 1] = value(); ws()
				local d = s:sub(pos, pos); pos += 1
				if d == "]" then break end
			end
			return r
		elseif c == '"' then return str()
		elseif s:sub(pos, pos + 3) == "true" then pos += 4 return true
		elseif s:sub(pos, pos + 4) == "false" then pos += 5 return false
		elseif s:sub(pos, pos + 3) == "null" then pos += 4 return nil
		else
			local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
			pos += #num
			return tonumber(num)
		end
	end
	return value()
end

---------------------------------------------------------------- Instances
local Services = {}
local classParents = {
	Folder = "Instance", StringValue = "Instance", Part = "Instance",
	Script = "LuaSourceContainer", LocalScript = "LuaSourceContainer", ModuleScript = "LuaSourceContainer",
	LuaSourceContainer = "Instance", Workspace = "Instance",
}
local InstMT = {}
local methods = {}
local nextId = 0

local function isA(cls, target)
	while cls do
		if cls == target then return true end
		cls = classParents[cls]
	end
	return false
end

function methods.IsA(self, c) return isA(rawget(self, "ClassName"), c) or c == "Instance" end
function methods.GetChildren(self) return table.clone(rawget(self, "_children")) end
function methods.GetDescendants(self)
	local out = {}
	local function walk(n) for _, c in ipairs(rawget(n, "_children")) do out[#out + 1] = c; walk(c) end end
	walk(self)
	return out
end
function methods.FindFirstChild(self, name)
	for _, c in ipairs(rawget(self, "_children")) do if rawget(c, "Name") == name then return c end end
end
function methods.Destroy(self)
	local p = rawget(self, "Parent")
	if p then
		local ch = rawget(p, "_children")
		table.remove(ch, table.find(ch, self))
	end
	rawset(self, "Parent", nil)
	for _, c in ipairs(table.clone(rawget(self, "_children"))) do methods.Destroy(c) end
end
function methods.ClearAllChildren(self) for _, c in ipairs(table.clone(rawget(self, "_children"))) do methods.Destroy(c) end end
function methods.GetFullName(self)
	local p = rawget(self, "Parent")
	if p and p ~= game then return methods.GetFullName(p) .. "." .. rawget(self, "Name") end
	return rawget(self, "Name")
end
function methods.IsDescendantOf(self, anc)
	local p = rawget(self, "Parent")
	while p do if p == anc then return true end p = rawget(p, "Parent") end
	return false
end
function methods.GetAttribute(self, k) return rawget(self, "_attrs")[k] end
function methods.SetAttribute(self, k, v) rawget(self, "_attrs")[k] = v end
function methods.GetAttributes(self) return table.clone(rawget(self, "_attrs")) end
function methods.GetTags(self) return table.clone(rawget(self, "_tags")) end
function methods.AddTag(self, t) table.insert(rawget(self, "_tags"), t) end

InstMT.__index = function(self, k)
	local m = methods[k]
	if m then return m end
	local v = rawget(self, k)
	if v ~= nil then return v end
	local f = methods.FindFirstChild(self, k)
	if f then return f end
	return nil
end
InstMT.__newindex = function(self, k, v)
	if k == "Parent" then
		local old = rawget(self, "Parent")
		if old then local ch = rawget(old, "_children"); table.remove(ch, table.find(ch, self)) end
		rawset(self, "Parent", v)
		if v then table.insert(rawget(v, "_children"), self) end
	else
		rawset(self, k, v)
	end
end

local function newInstance(className)
	local inst = setmetatable({}, InstMT)
	rawset(inst, "ClassName", className)
	rawset(inst, "Name", className)
	rawset(inst, "_children", {})
	rawset(inst, "_attrs", {})
	rawset(inst, "_tags", {})
	if className == "StringValue" then rawset(inst, "Value", "") end
	if isA(className, "LuaSourceContainer") then rawset(inst, "Source", "") end
	return inst
end

game = newInstance("DataModel")
rawset(game, "Name", "Game")
function game.GetService(self, name)
	local s = methods.FindFirstChild(self, name)
	if s then return s end
	if name == "HttpService" then return HttpServiceMock end
	if name == "ReflectionService" then
		return { GetPropertiesOfClass = function(_, cls)
			return { {Name = "Name", Serialized = true}, {Name = "Value", Serialized = (cls == "StringValue")}, {Name = "Parent", Serialized = true} }
		end }
	end
	if name == "RunService" then return { IsStudio = function() return true end } end
	local svc = newInstance(name)
	rawset(svc, "Name", name)
	svc.Parent = game
	return svc
end
-- game is an Instance but GetService must be reachable as a method
methods.GetService = game.GetService
rawset(game, "GetService", nil)

HttpServiceMock = {
	JSONEncode = function(_, v) return jencode(v) end,
	JSONDecode = function(_, s) return jdecode(s) end,
	GenerateGUID = function() nextId += 1 return string.format("GUID-%08d", nextId) end,
	RequestAsync = function() error("no network in tests") end,
}
-- the HttpService must be gettable
local rawGetService = methods.GetService
methods.GetService = function(self, name)
	if name == "HttpService" then return HttpServiceMock end
	if name == "ReflectionService" then
		return { GetPropertiesOfClass = function(_, cls)
			return { {Name = "Name", Serialized = true}, {Name = "Value", Serialized = (cls == "StringValue")} }
		end }
	end
	return rawGetService(self, name)
end

Instance = { new = function(c) return newInstance(c) end }
typeof = function(v)
	if type(v) == "table" and getmetatable(v) == InstMT then return "Instance" end
	return type(v)
end
warn = function(...) print("WARN:", ...) end
task = { wait = function() end, spawn = function(f, ...) f(...) end, delay = function() end }

---------------------------------------------------------------- module loader
local cache = {}
local function proxyFor(path, isDir)
	local p = { __path = path, __dir = isDir }
	return setmetatable(p, {
		__index = function(_, k)
			if k == "Parent" then
				local parent = path:match("^(.*)/[^/]+$")
				if not parent or #parent < #SRC then return nil end
				return proxyFor(parent, true)
			end
			if isDir then
				for _, ext in ipairs({".lua", ".luau"}) do
					if SOURCES[path .. "/" .. k .. ext] then return proxyFor(path .. "/" .. k .. ext, false) end
				end
				if k == "libs" then return proxyFor(path .. "/" .. k, true) end
			end
			return nil
		end,
	})
end

function require(mod)
	local path = mod.__path
	if cache[path] ~= nil then return cache[path] end
	local src = assert(SOURCES[path], "no source " .. path)
	local fn = assert(loadstring(src, "=" .. path))
	local env = setmetatable({ script = mod }, { __index = GLOBALS })
	setfenv(fn, env)
	local r = fn()
	cache[path] = r == nil and true or r
	return cache[path]
end

function loadModule(rel) return require(proxyFor(SRC .. "/" .. rel, false)) end
Harness = { jencode = jencode, jdecode = jdecode, newInstance = newInstance, methods = methods, InstMT = InstMT }
