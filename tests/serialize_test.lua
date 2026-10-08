-- Serializer tests: special instances (EditableImage/EditableMesh/Path2D), Content references, unsupported types and `git doctor`.
local arguments = loadModule("arguments.lua")
loadModule("git.lua")
local instances = loadModule("libs/instances.lua")
local Remote = loadModule("libs/git_remote.lua")
local Handlers = loadModule("libs/git_handlers.lua")
local HS = game:GetService("HttpService")
local ws = game:GetService("Workspace")

local realPrint = print
local failures = 0
local function check(name, cond)
	if not cond then failures += 1 realPrint("FAIL: " .. name) end
end

------------------------------------------------------------------ mocks for the datatypes involved
local function datatype(name, fields) fields.__typeof = name return fields end
Vector2 = { new = function(x, y) return datatype("Vector2", {X = x, Y = y}) end }
Vector3 = { new = function(x, y, z) return datatype("Vector3", {X = x, Y = y, Z = z}) end }
Color3 = { new = function(r, g, b) return datatype("Color3", {R = r, G = g, B = b}) end }
Enum = { ContentSourceType = { None = "None", Uri = "Uri", Object = "Object" } }
Content = {
	none = datatype("Content", {SourceType = "None"}),
	fromUri = function(uri) return datatype("Content", {SourceType = "Uri", Uri = uri}) end,
	fromObject = function(obj) return datatype("Content", {SourceType = "Object", Object = obj}) end,
}

-- Instance.new refuses these two, exactly like in Studio they have to come from AssetService
local plainNew = Instance.new
Instance.new = function(class)
	if class == "EditableImage" or class == "EditableMesh" then error("Unable to create an Instance of type \"" .. class .. "\"") end
	return plainNew(class)
end
local creations = 0
local AssetService = {
	CreateEditableImage = function(_, opts)
		creations += 1
		local img = plainNew("EditableImage")
		img.Size = opts and opts.Size or Vector2.new(1, 1)
		return img
	end,
	CreateEditableMesh = function()
		creations += 1
		return plainNew("EditableMesh")
	end,
}
local baseGetService = Harness.methods.GetService
Harness.methods.GetService = function(self, name)
	if name == "AssetService" then return AssetService end
	return baseGetService(self, name)
end

-- EditableImage: RGBA pixels in a buffer
local pixelStore = setmetatable({}, {__mode = "k"})
classMethods.EditableImage = {
	ReadPixelsBuffer = function(self, _, size)
		local data = pixelStore[self] or buffer.create(size.X * size.Y * 4)
		return buffer.fromstring(buffer.tostring(data))
	end,
	WritePixelsBuffer = function(self, _, size, buf) pixelStore[self] = buffer.fromstring(buffer.tostring(buf)) end,
}

-- EditableMesh: id based vertex/face API
local meshData = setmetatable({}, {__mode = "k"})
local function mesh(self)
	if not meshData[self] then meshData[self] = {v = {}, n = {}, uv = {}, c = {}, f = {}, nextId = 100} end
	return meshData[self]
end
local function addTo(list, value) local m = list; m.nextId = (m.nextId or 100) + 1 return m.nextId end
local function collection(field, adder)
	return {
		add = function(self, ...) local d = mesh(self); d.nextId += 1; d[field][d.nextId] = adder(...); return d.nextId end,
		list = function(self) local out = {} for id in pairs(mesh(self)[field]) do out[#out + 1] = id end return out end,
		get = function(self, id) return mesh(self)[field][id] end,
		remove = function(self, id) mesh(self)[field][id] = nil end,
	}
end
local V, N, U, C = collection("v", function(p) return p end), collection("n", function(p) return p end), collection("uv", function(p) return p end), collection("c", function(c, a) return {color = c, alpha = a} end)
classMethods.EditableMesh = {
	AddVertex = V.add, GetVertices = V.list, GetPosition = V.get,
	RemoveVertex = function(self, id)
		local d = mesh(self)
		d.v[id] = nil
		for faceId, face in pairs(d.f) do -- like the real API, faces using the vertex go away with it
			for _, vertexId in ipairs(face.v) do if vertexId == id then d.f[faceId] = nil break end end
		end
	end,
	AddNormal = N.add, GetNormals = N.list, GetNormal = N.get, RemoveNormal = N.remove,
	AddUV = U.add, GetUVs = U.list, GetUV = U.get, RemoveUV = U.remove,
	AddColor = C.add, GetColors = C.list,
	GetColor = function(self, id) return C.get(self, id).color end,
	GetColorAlpha = function(self, id) return C.get(self, id).alpha end,
	RemoveColor = C.remove,
	AddTriangle = function(self, a, b, c) local d = mesh(self); d.nextId += 1; d.f[d.nextId] = {v = {a, b, c}} return d.nextId end,
	GetFaces = function(self) local out = {} for id in pairs(mesh(self).f) do out[#out + 1] = id end return out end,
	GetFaceVertices = function(self, f) return mesh(self).f[f].v end,
	GetFaceNormals = function(self, f) return mesh(self).f[f].n or {} end,
	GetFaceUVs = function(self, f) return mesh(self).f[f].uv or {} end,
	GetFaceColors = function(self, f) return mesh(self).f[f].c or {} end,
	SetFaceNormals = function(self, f, ids) mesh(self).f[f].n = ids end,
	SetFaceUVs = function(self, f, ids) mesh(self).f[f].uv = ids end,
	SetFaceColors = function(self, f, ids) mesh(self).f[f].c = ids end,
}
classMethods.Path2D = {
	GetControlPoints = function(self) return rawget(self, "_points") or {} end,
	SetControlPoints = function(self, pts) rawset(self, "_points", pts) end,
}
UDim2 = { new = function(a, b) return datatype("UDim2", {X = a, Y = b}) end }
UDim = { new = function(s, o) return datatype("UDim", {Scale = s, Offset = o}) end }
Path2DControlPoint = { new = function(p, l, r) return {Position = p, LeftTangent = l, RightTangent = r} end }

extraProps.ImageLabel = {"ImageContent"}
extraProps.Path2D = {}

local function props_of(json) return HS:JSONDecode(json) end
local function find_prop(props, name) for _, p in ipairs(props) do if p.name == name then return p end end end

------------------------------------------------------------------ EditableImage
local image = AssetService:CreateEditableImage({Size = Vector2.new(4, 2)})
image.Name = "Tex"
local pixels = buffer.create(4 * 2 * 4)
for i = 0, 31 do buffer.writeu8(pixels, i, (i * 7) % 256) end
image:WritePixelsBuffer(Vector2.new(0, 0), Vector2.new(4, 2), pixels)

local json1 = instances.serialize_instance(image)
local json2 = instances.serialize_instance(image)
check("image serialization is stable", json1 == json2)
local entry = find_prop(props_of(json1), "_editableImage")
check("image data stored", entry and entry.value.Width == 4 and entry.value.Height == 2 and #entry.value.Data > 0)

buffer.writeu8(pixels, 3, 99)
image:WritePixelsBuffer(Vector2.new(0, 0), Vector2.new(4, 2), pixels)
check("changed pixels change the blob", instances.serialize_instance(image) ~= json1)
image:WritePixelsBuffer(Vector2.new(0, 0), Vector2.new(4, 2), (function() local b = buffer.create(32) for i = 0, 31 do buffer.writeu8(b, i, (i * 7) % 256) end return b end)())

local props = props_of(json1)
local copy = instances.create_instance("EditableImage", props)
check("image comes from AssetService", copy ~= nil and creations >= 1)
Remote.applyProperties(copy, props)
check("image restored", buffer.tostring(pixelStore[copy]) == buffer.tostring(pixelStore[image]))
check("image size restored", copy.Size.X == 4 and copy.Size.Y == 2)

------------------------------------------------------------------ EditableMesh
local m = AssetService:CreateEditableMesh()
local a = m:AddVertex(Vector3.new(0, 0, 0))
local b = m:AddVertex(Vector3.new(1, 0, 0))
local c = m:AddVertex(Vector3.new(0, 1, 0))
local n = m:AddNormal(Vector3.new(0, 0, 1))
local uvA, uvB, uvC = m:AddUV(Vector2.new(0, 0)), m:AddUV(Vector2.new(1, 0)), m:AddUV(Vector2.new(0, 1))
local col = m:AddColor(Color3.new(1, 0.5, 0.25), 0.75)
local face = m:AddTriangle(a, b, c)
m:SetFaceNormals(face, {n, n, n})
m:SetFaceUVs(face, {uvA, uvB, uvC})
m:SetFaceColors(face, {col, col, col})
m:AddTriangle(a, c, b) -- a second face without normals/uvs

local meshJson = instances.serialize_instance(m)
local meshEntry = find_prop(props_of(meshJson), "_editableMesh")
check("mesh counts", meshEntry and meshEntry.value.V == 3 and meshEntry.value.N == 1 and meshEntry.value.U == 3 and meshEntry.value.C == 1 and meshEntry.value.F == 2)

local meshCopy = instances.create_instance("EditableMesh", props_of(meshJson))
Remote.applyProperties(meshCopy, props_of(meshJson))
check("mesh round trips", instances.serialize_instance(meshCopy) == meshJson)
-- applying again onto a mesh that already matches changes nothing, applying onto a different mesh rebuilds it
local other = AssetService:CreateEditableMesh()
other:AddVertex(Vector3.new(5, 5, 5))
Remote.applyProperties(other, props_of(meshJson))
check("mesh overwritten", instances.serialize_instance(other) == meshJson)

------------------------------------------------------------------ Path2D
local path = plainNew("Path2D")
rawset(path, "_points", {Path2DControlPoint.new(UDim2.new(UDim.new(0, 1), UDim.new(0, 2)), UDim2.new(UDim.new(0, 0), UDim.new(0, 0)), UDim2.new(UDim.new(0.5, 3), UDim.new(0, 0)))})
local pathJson = instances.serialize_instance(path)
local pathCopy = plainNew("Path2D")
Remote.applyProperties(pathCopy, props_of(pathJson))
check("path2d round trips", instances.serialize_instance(pathCopy) == pathJson)

------------------------------------------------------------------ Content
local label = plainNew("ImageLabel")
label.Name = "Label"
label.ImageContent = Content.fromObject(image)
local labelProps = props_of(instances.serialize_instance(label))
local contentEntry = find_prop(labelProps, "ImageContent")
check("content object serialized as reference", contentEntry and contentEntry.value.Object and contentEntry.value.Object.Guid ~= nil)

local label2 = plainNew("ImageLabel")
image.Parent = ws
label2.Parent = ws
Remote.applyProperties(label2, labelProps)
Remote.resolve_instance_refs()
check("content reference relinked", label2.ImageContent and label2.ImageContent.SourceType == "Object" and label2.ImageContent.Object == image)

label.ImageContent = Content.fromUri("rbxassetid://123")
local uriProps = props_of(instances.serialize_instance(label))
local label3 = plainNew("ImageLabel")
Remote.applyProperties(label3, uriProps)
check("content uri round trips", label3.ImageContent.Uri == "rbxassetid://123")

------------------------------------------------------------------ unsupported datatypes are skipped, not stored as junk
local weird = plainNew("StringValue")
weird.Name = "Weird"
weird:SetAttribute("good", 5)
weird:SetAttribute("bad", datatype("SomeFutureType", {}))
local weirdProps = props_of(instances.serialize_instance(weird))
local attrs = find_prop(weirdProps, "_attributes")
check("good attribute kept, unknown attribute skipped", attrs and #attrs.value == 1 and attrs.value[1].name == "good")

------------------------------------------------------------------ git doctor + a full commit/restore cycle
weird.Parent = ws
local mesh_holder = plainNew("Folder")
mesh_holder.Name = "Holder"
mesh_holder.Parent = ws
m.Name = "Mesh"
m.Parent = mesh_holder
image.Parent = mesh_holder
image.Name = "Tex"
label.Parent = mesh_holder

print = function() end
local output = {}
local function run(...)
	local lines = {}
	print = function(...) table.insert(lines, table.concat({...}, " ")) end
	local ok, err = pcall(arguments.execute, "git", ...)
	print = function() end
	return ok, ok and table.concat(lines, "\n") or tostring(err)
end

local ok, doctor = run("doctor")
check("doctor runs", ok)
check("doctor lists special handling", doctor:find("EditableImage x1") and doctor:find("EditableMesh x1"))
check("doctor lists unknown attribute type", doctor:find("@bad", 1, true) and doctor:find("SomeFutureType", 1, true))

run("init")
run("add", ".")
check("commit with editable instances", run("commit", "-m", "editable"))

-- scribble over everything, then restore from the commit
buffer.writeu8(pixelStore[image], 0, 255)
m:AddVertex(Vector3.new(9, 9, 9))
local expectedMesh = meshJson
check("mesh now differs", instances.serialize_instance(m) ~= expectedMesh)
local status = select(2, run("status"))
check("status notices pixel/mesh edits", status:find("Holder/Tex", 1, true) and status:find("Holder/Mesh", 1, true))
check("reset --hard", run("reset", "--hard"))
check("pixels restored by checkout", buffer.readu8(pixelStore[image], 0) == (0 * 7) % 256)
local restoredMesh = ws.Holder.Mesh
check("mesh restored by checkout", find_prop(props_of(instances.serialize_instance(restoredMesh)), "_editableMesh").value.Data == meshEntry.value.Data)

------------------------------------------------------------------ awkward instance names
local Utilities = loadModule("libs/utilities.lua")
for _, name in ipairs({"A/B", "", ".", "..", ".git", ".GIT", ".properties", "100%", "%2F", "%25", "%00", "a%2Fb/c", "%2E", "plain name", "Weird [1]"}) do
	local escaped = Utilities.escape_name(name)
	check("escape roundtrip '" .. name .. "'", Utilities.unescape_name(escaped) == name)
	check("escaped '" .. name .. "' is a valid tree entry", escaped ~= "" and not escaped:find("/", 1, true) and escaped ~= "." and escaped ~= ".." and escaped:lower() ~= ".git" and escaped ~= ".properties")
end
check("ordinary names untouched", Utilities.escape_name("Part") == "Part" and Utilities.escape_name("100%") == "100%")

local names = plainNew("Folder")
names.Name = "Names"
names.Parent = ws
for i, weird in ipairs({"A/B", "", ".git", ".properties", "50%2F"}) do
	local sv = plainNew("StringValue")
	sv.Name = weird
	sv.Value = "v" .. i
	sv.Parent = names
end

check("partial add of an awkward name", run("add", "Workspace/Names/A%2FB"))
local index = Handlers.read_index()
check("partial add stores the instance at its own path", index["Workspace/Names/A%2FB"] ~= nil and index["Workspace/Names"] == nil)
check("partial add also stores the parents", index["Workspace/Names/.properties"] ~= nil and index["Workspace/.properties"] ~= nil)

check("add all", run("add", "."))
check("commit awkward names", run("commit", "-m", "names"))
for i, weird in ipairs({"A/B", "", ".git", ".properties", "50%2F"}) do
	local found
	for _, child in ipairs(names:GetChildren()) do if child.Name == weird then found = child end end
	found.Value = "changed"
end
check("reset restores awkward names", run("reset", "--hard"))
local values = {}
for _, child in ipairs(ws.Names:GetChildren()) do values[child.Name] = child.Value end
check("all awkward names came back", values["A/B"] == "v1" and values[""] == "v2" and values[".git"] == "v3" and values[".properties"] == "v4" and values["50%2F"] == "v5")

print = realPrint
if failures > 0 then error(failures .. " check(s) failed") end
print("all serialize checks passed")
