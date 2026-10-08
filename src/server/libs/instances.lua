local instances = {}

--// quick definitions
local HttpService = game:GetService("HttpService")

local Utilities = require(script.Parent.utilities)
local Handlers = require(script.Parent.git_handlers)
local hashlib = require(script.Parent.hashlib)
local bash = require(script.Parent.Parent.bash)

local ROGIT_ID = "_rogit_id"

--// While `git doctor` runs this collects everything the serializer could not handle (see serialize_instance).
local active_report = nil

local function note(kind, className, propName, detail)
    if not active_report then return end
    local bucket = active_report[kind]
    local key = className .. "." .. propName
    local entry = bucket[key]
    if not entry then
        entry = {count = 0, detail = detail}
        bucket[key] = entry
    end
    entry.count += 1
end

--[[
Helper to round numbers to avoid floating point jitter in Git.
]]
local FLOAT_MAX = 3.4028234663852886e38

local function round(num)
    if typeof(num) ~= "number" then return num end
    --// JSON cannot represent NaN/inf, clamp them to something that round-trips.
    if num ~= num then return 0 end
    if num == math.huge then return FLOAT_MAX end
    if num == -math.huge then return -FLOAT_MAX end
    -- Round to 6 decimal places and return as number
    local rounded = tonumber(string.format("%.6f", num))
    if rounded == 0 then return 0 end -- Clean -0 to 0
    return rounded
end

--[[
Serializes a property to a table, that can be converted to JSON.
]]
function instances.serialize_property(prop)
    assert(prop ~= nil, "No property parsed to serialize!")

    local type = typeof(prop)
    local r = prop

    if type == "number" then
        r = round(prop)
    elseif type == "string" then
        --// JSON only holds valid UTF-8, anything else (e.g. union/mesh data) is stored as base64.
        if not utf8.len(prop) then
            r = {__b64 = hashlib.bin_to_base64(prop)}
        end
    elseif type == "Vector3int16" then
        r = {X = prop.X, Y = prop.Y, Z = prop.Z}
    elseif type == "Vector2int16" then
        r = {X = prop.X, Y = prop.Y}
    elseif type == "Faces" then
        r = {Top = prop.Top, Bottom = prop.Bottom, Left = prop.Left, Right = prop.Right, Back = prop.Back, Front = prop.Front}
    elseif type == "Axes" then
        r = {X = prop.X, Y = prop.Y, Z = prop.Z}
    elseif type == "Ray" then
        r = {Origin = instances.serialize_property(prop.Origin), Direction = instances.serialize_property(prop.Direction)}
    elseif type == "BrickColor" then
        r = tostring(prop)
    elseif type == "CFrame" then
        r = {pos = instances.serialize_property(prop.Position), rX = instances.serialize_property(prop.rightVector), rY = instances.serialize_property(prop.upVector), rZ = instances.serialize_property(-prop.lookVector)}
    elseif type == "Vector3" then
        r = {X = round(prop.X), Y = round(prop.Y), Z = round(prop.Z)}
    elseif type == "Vector2" then
        r = {X = round(prop.X), Y = round(prop.Y)}
    elseif type == "Color3" then
        r = {R = round(prop.R), G = round(prop.G), B = round(prop.B)}
    elseif type == "EnumItem" then
        r = {string.split(tostring(prop), ".")[2], string.split(tostring(prop), ".")[3]} 
    elseif type == "UDim" then
        r = {Scale = round(prop.Scale), Offset = round(prop.Offset)}
    elseif type == "UDim2" then
        r = {X = instances.serialize_property(prop.X), Y = instances.serialize_property(prop.Y)}
    elseif type == "Rect" then
        r = {Min = instances.serialize_property(prop.Min), Max = instances.serialize_property(prop.Max)}
    elseif type == "NumberRange" then
        r = {Min = round(prop.Min), Max = round(prop.Max)}
    elseif type == "PhysicalProperties" then
        r = {Density = round(prop.Density), Friction = round(prop.Friction), Elasticity = round(prop.Elasticity), FrictionWeight = round(prop.FrictionWeight), ElasticityWeight = round(prop.ElasticityWeight)}
    elseif type == "Font" then
        r = {Family = prop.Family, Weight = instances.serialize_property(prop.Weight), Style = instances.serialize_property(prop.Style)}
    elseif type == "NumberSequenceKeypoint" then
        r = {Time = round(prop.Time), Value = round(prop.Value), Envelope = round(prop.Envelope)}
    elseif type == "ColorSequenceKeypoint" then
        r = {Time = round(prop.Time), Value = instances.serialize_property(prop.Value)}
    elseif type == "NumberSequence" then
        local keypoints = {}
        for _, kp in ipairs(prop.Keypoints) do
            table.insert(keypoints, instances.serialize_property(kp))
        end
        r = {Keypoints = keypoints}
    elseif type == "ColorSequence" then
        local keypoints = {}
        for _, kp in ipairs(prop.Keypoints) do
            table.insert(keypoints, instances.serialize_property(kp))
        end
        r = {Keypoints = keypoints}
    elseif type == "Instance" then
        local guid = prop:GetAttribute(ROGIT_ID)
        if not guid then
            guid = HttpService:GenerateGUID(false)
            prop:SetAttribute(ROGIT_ID, guid)
        end
        r = {Guid = guid}
    elseif type == "Content" then
        --// Content is either nothing, a uri (rbxassetid://..) or a reference to an EditableImage/EditableMesh
        local ok, result = pcall(function()
            local sourceType = prop.SourceType
            if sourceType == Enum.ContentSourceType.Uri then
                return {Uri = prop.Uri}
            elseif sourceType == Enum.ContentSourceType.Object and typeof(prop.Object) == "Instance" then
                return {Object = instances.serialize_property(prop.Object)}
            end
            return {}
        end)
        if not ok then return nil, type end
        r = result
    elseif type == "buffer" then
        r = {__b64 = hashlib.bin_to_base64(buffer.tostring(prop))}
    else
        if type ~= "boolean" and type ~= "table" then
            --// A datatype we don't know how to store. Storing its tostring() would only save something we can never load back.
            return nil, type
        end
    end

    return r
end

--[[
    Serializes a property back into an Instance property.
]]
function instances.deserialize_property(prop, propType)
    if type(prop) == "table" and prop.__b64 ~= nil then
        local bin = hashlib.base64_to_bin(prop.__b64)
        return propType == "buffer" and buffer.fromstring(bin) or bin
    end

    if propType == "Content" then
        if type(prop) == "string" then
            --// older commits stored content as a plain string
            return prop ~= "" and Content.fromUri(prop) or Content.none
        elseif type(prop) == "table" and prop.Uri then
            return Content.fromUri(prop.Uri)
        end
        --// object references are linked later, once every instance exists (see resolve_instance_refs)
        return Content.none
    end

    if propType == "BrickColor" then
        return BrickColor.new(prop)
    elseif propType == "CFrame" then
        local pos = instances.deserialize_property(prop.pos, "Vector3")
        local rX = instances.deserialize_property(prop.rX, "Vector3")
        local rY = instances.deserialize_property(prop.rY, "Vector3")
        local rZ = instances.deserialize_property(prop.rZ, "Vector3")
        return CFrame.fromMatrix(pos, rX, rY, rZ)
    elseif propType == "Vector3" then
        return Vector3.new(prop.X, prop.Y, prop.Z)
    elseif propType == "Vector2" then
        return Vector2.new(prop.X, prop.Y)
    elseif propType == "Color3" then
        if prop.R then
            return Color3.new(prop.R, prop.G, prop.B)
        else
            -- Backwards compatibility for HSV
            return Color3.fromHSV(prop[1], prop[2], prop[3])
        end
    elseif propType == "EnumItem" then
        return Enum[prop[1]][prop[2]]
    elseif propType == "UDim" then
        return UDim.new(prop.Scale, prop.Offset)
    elseif propType == "UDim2" then
        return UDim2.new(instances.deserialize_property(prop.X, "UDim"), instances.deserialize_property(prop.Y, "UDim"))
    elseif propType == "Rect" then
        return Rect.new(instances.deserialize_property(prop.Min, "Vector2"), instances.deserialize_property(prop.Max, "Vector2"))
    elseif propType == "NumberRange" then
        return NumberRange.new(prop.Min, prop.Max)
    elseif propType == "PhysicalProperties" then
        return PhysicalProperties.new(prop.Density, prop.Friction, prop.Elasticity, prop.FrictionWeight, prop.ElasticityWeight)
    elseif propType == "Font" then
        return Font.new(prop.Family, instances.deserialize_property(prop.Weight, "EnumItem"), instances.deserialize_property(prop.Style, "EnumItem"))
    elseif propType == "Vector3int16" then
        return Vector3int16.new(prop.X, prop.Y, prop.Z)
    elseif propType == "Vector2int16" then
        return Vector2int16.new(prop.X, prop.Y)
    elseif propType == "Faces" then
        local faces = {}
        for _, face in ipairs({"Top", "Bottom", "Left", "Right", "Back", "Front"}) do
            if prop[face] then table.insert(faces, Enum.NormalId[face]) end
        end
        return Faces.new(table.unpack(faces))
    elseif propType == "Axes" then
        local axes = {}
        for _, axis in ipairs({"X", "Y", "Z"}) do
            if prop[axis] then table.insert(axes, Enum.Axis[axis]) end
        end
        return Axes.new(table.unpack(axes))
    elseif propType == "Ray" then
        return Ray.new(instances.deserialize_property(prop.Origin, "Vector3"), instances.deserialize_property(prop.Direction, "Vector3"))
    elseif propType == "NumberSequenceKeypoint" then
        return NumberSequenceKeypoint.new(prop.Time, prop.Value, prop.Envelope)
    elseif propType == "ColorSequenceKeypoint" then
        return ColorSequenceKeypoint.new(prop.Time, instances.deserialize_property(prop.Value, "Color3"))
    elseif propType == "NumberSequence" then
        local keypoints = {}
        for _, kp in ipairs(prop.Keypoints) do
            table.insert(keypoints, instances.deserialize_property(kp, "NumberSequenceKeypoint"))
        end
        return NumberSequence.new(keypoints)
    elseif propType == "ColorSequence" then
        local keypoints = {}
        for _, kp in ipairs(prop.Keypoints) do
            table.insert(keypoints, instances.deserialize_property(kp, "ColorSequenceKeypoint"))
        end
        return ColorSequence.new(keypoints)
    end
    return prop
end

--// Property lists never change for a class, so look them up once instead of per instance.
local class_property_cache = {}

local INTERNAL_TO_PUBLIC = {
    size = "Size",
    color = "Color",
    color3uint8 = "Color",
    formFactorRaw = "FormFactor",
    shape = "Shape",
    MaterialVariantSerialized = "MaterialVariant",
}

local function get_class_properties(className)
    local cached = class_property_cache[className]
    if cached then return cached end

    local list = {}
    local ok, classProperties = pcall(function()
        return game:GetService("ReflectionService"):GetPropertiesOfClass(className)
    end)

    if ok then
        for _, propertyData in ipairs(classProperties) do
            --// Often the 'true' serialized property is lowercase (e.g. 'size') or internal (e.g. 'Color3uint8')
            --// We try to map it to its public PascalCase member if possible.
            local internalName = propertyData.Name
            local publicName = INTERNAL_TO_PUBLIC[internalName] or (internalName:sub(1,1):upper() .. internalName:sub(2))
            if internalName == "Color3uint8" then publicName = "Color" end

            if (propertyData.Serialized == true or publicName == "Color" or publicName == "Size") and publicName ~= "Parent" then
                table.insert(list, {publicName = publicName, internalName = internalName})
            end
        end
        class_property_cache[className] = list
    end

    return list
end

--[[
Some instances keep their data outside of properties (pixels, vertices...), it is only reachable through methods.
Each handler stores that data in one extra pseudo property (`_editableImage`, ...) of the instance's blob:
  read(instance)         -> value (JSON friendly table)
  write(instance, value) -> restores it
  create(value)          -> optional, builds the instance when Instance.new can't
]]
local SPECIAL = {}
local NONE = 0xFFFFFFFF

--// A 16 MB image is 2048x2048, anything bigger would make commits unusably slow.
local MAX_IMAGE_BYTES = 16 * 1024 * 1024

local function id_list(...)
    local first = ...
    if type(first) == "table" then return first end
    return {...}
end

local function sorted_ids(list)
    local ids = table.clone(list)
    table.sort(ids)
    return ids
end

--// ---------------------------------------------------------------- EditableImage
--// The pixels (RGBA, 4 bytes each) are expensive to base64, so the result is reused while the pixels are unchanged.
local image_cache = setmetatable({}, {__mode = "k"})

local function fingerprint(buf)
    local len = buffer.len(buf)
    local hash = len
    for offset = 0, len - 4, 4 do
        hash = (hash * 31 + buffer.readu32(buf, offset)) % 4294967296
    end
    return hash
end

SPECIAL.EditableImage = {
    key = "_editableImage",

    read = function(image)
        local size = image.Size
        local width, height = math.floor(size.X), math.floor(size.Y)
        if width <= 0 or height <= 0 then
            return {Width = math.max(width, 0), Height = math.max(height, 0)}
        end
        assert(width * height * 4 <= MAX_IMAGE_BYTES, string.format("image is too large to store (%dx%d, the limit is 2048x2048)", width, height))

        local pixels = image:ReadPixelsBuffer(Vector2.new(0, 0), Vector2.new(width, height))
        local hash = fingerprint(pixels)

        local cached = image_cache[image]
        if cached and cached.hash == hash and cached.width == width and cached.height == height then
            return cached.value
        end

        local value = {Width = width, Height = height, Data = hashlib.bin_to_base64(buffer.tostring(pixels))}
        image_cache[image] = {hash = hash, width = width, height = height, value = value}
        return value
    end,

    write = function(image, value)
        local width, height = value.Width, value.Height
        pcall(function() image.Size = Vector2.new(width, height) end)
        if not value.Data or width <= 0 or height <= 0 then return end

        --// don't touch an image that already matches (checking out is a lot cheaper then)
        local ok, current = pcall(SPECIAL.EditableImage.read, image)
        if ok and current.Data == value.Data then return end

        image:WritePixelsBuffer(Vector2.new(0, 0), Vector2.new(width, height), buffer.fromstring(hashlib.base64_to_bin(value.Data)))
    end,

    create = function(value)
        local width, height = value and value.Width or 1, value and value.Height or 1
        return game:GetService("AssetService"):CreateEditableImage({Size = Vector2.new(math.max(width, 1), math.max(height, 1))})
    end,
}

--// ---------------------------------------------------------------- EditableMesh
--// Layout of the packed data (all little endian 32 bit):
--//   positions (3 floats) | normals (3 floats) | uvs (2 floats) | colors (3 floats + alpha) | faces (12 uints)
--// A face holds 3 vertex, 3 normal, 3 uv and 3 color indexes into those lists (0xFFFFFFFF = not set).
SPECIAL.EditableMesh = {
    key = "_editableMesh",

    read = function(mesh)
        local vertexIds = sorted_ids(id_list(mesh:GetVertices()))
        local normalIds = sorted_ids(id_list(mesh:GetNormals()))
        local uvIds = sorted_ids(id_list(mesh:GetUVs()))
        local colorIds = sorted_ids(id_list(mesh:GetColors()))
        local faceIds = sorted_ids(id_list(mesh:GetFaces()))

        local function index_of(ids)
            local map = {}
            for i, id in ipairs(ids) do map[id] = i - 1 end
            return map
        end
        local vertexIndex, normalIndex, uvIndex, colorIndex = index_of(vertexIds), index_of(normalIds), index_of(uvIds), index_of(colorIds)

        local counts = {V = #vertexIds, N = #normalIds, U = #uvIds, C = #colorIds, F = #faceIds}
        local floats = counts.V * 3 + counts.N * 3 + counts.U * 2 + counts.C * 4
        local buf = buffer.create((floats + counts.F * 12) * 4)
        local cursor = 0

        local function writeFloat(n)
            buffer.writef32(buf, cursor, n)
            cursor += 4
        end
        local function writeUint(n)
            buffer.writeu32(buf, cursor, n)
            cursor += 4
        end

        for _, id in ipairs(vertexIds) do
            local p = mesh:GetPosition(id)
            writeFloat(p.X); writeFloat(p.Y); writeFloat(p.Z)
        end
        for _, id in ipairs(normalIds) do
            local n = mesh:GetNormal(id)
            writeFloat(n.X); writeFloat(n.Y); writeFloat(n.Z)
        end
        for _, id in ipairs(uvIds) do
            local uv = mesh:GetUV(id)
            writeFloat(uv.X); writeFloat(uv.Y)
        end
        for _, id in ipairs(colorIds) do
            local c = mesh:GetColor(id)
            writeFloat(c.R); writeFloat(c.G); writeFloat(c.B)
            writeFloat(mesh:GetColorAlpha(id))
        end

        local function writeCorners(ids, map)
            for corner = 1, 3 do
                local id = ids and ids[corner]
                writeUint(id ~= nil and map[id] or NONE)
            end
        end
        for _, face in ipairs(faceIds) do
            writeCorners(id_list(mesh:GetFaceVertices(face)), vertexIndex)
            writeCorners(select(2, pcall(function() return id_list(mesh:GetFaceNormals(face)) end)), normalIndex)
            writeCorners(select(2, pcall(function() return id_list(mesh:GetFaceUVs(face)) end)), uvIndex)
            writeCorners(select(2, pcall(function() return id_list(mesh:GetFaceColors(face)) end)), colorIndex)
        end

        counts.Data = hashlib.bin_to_base64(buffer.tostring(buf))
        return counts
    end,

    write = function(mesh, value)
        local ok, current = pcall(SPECIAL.EditableMesh.read, mesh)
        if ok and current.Data == value.Data then return end

        --// start from an empty mesh
        for _, id in ipairs(id_list(mesh:GetVertices())) do pcall(mesh.RemoveVertex, mesh, id) end
        for _, id in ipairs(id_list(mesh:GetNormals())) do pcall(mesh.RemoveNormal, mesh, id) end
        for _, id in ipairs(id_list(mesh:GetUVs())) do pcall(mesh.RemoveUV, mesh, id) end
        for _, id in ipairs(id_list(mesh:GetColors())) do pcall(mesh.RemoveColor, mesh, id) end

        local buf = buffer.fromstring(hashlib.base64_to_bin(value.Data))
        local cursor = 0
        local function readFloat()
            local n = buffer.readf32(buf, cursor)
            cursor += 4
            return n
        end
        local function readUint()
            local n = buffer.readu32(buf, cursor)
            cursor += 4
            return n
        end

        local vertexIds, normalIds, uvIds, colorIds = {}, {}, {}, {}
        for i = 1, value.V do vertexIds[i] = mesh:AddVertex(Vector3.new(readFloat(), readFloat(), readFloat())) end
        for i = 1, value.N do normalIds[i] = mesh:AddNormal(Vector3.new(readFloat(), readFloat(), readFloat())) end
        for i = 1, value.U do uvIds[i] = mesh:AddUV(Vector2.new(readFloat(), readFloat())) end
        for i = 1, value.C do
            local color = Color3.new(readFloat(), readFloat(), readFloat())
            colorIds[i] = mesh:AddColor(color, readFloat())
        end

        local function readCorners(map)
            local ids, complete = {}, true
            for corner = 1, 3 do
                local index = readUint()
                if index == NONE then
                    complete = false
                else
                    ids[corner] = map[index + 1]
                end
            end
            return complete and ids or nil
        end

        for _ = 1, value.F do
            local vertices = readCorners(vertexIds)
            local normals = readCorners(normalIds)
            local uvs = readCorners(uvIds)
            local colors = readCorners(colorIds)
            if vertices then
                local face = mesh:AddTriangle(vertices[1], vertices[2], vertices[3])
                if normals then pcall(mesh.SetFaceNormals, mesh, face, normals) end
                if uvs then pcall(mesh.SetFaceUVs, mesh, face, uvs) end
                if colors then pcall(mesh.SetFaceColors, mesh, face, colors) end
            end
        end
    end,

    create = function()
        return game:GetService("AssetService"):CreateEditableMesh()
    end,
}

--// ---------------------------------------------------------------- Terrain
--// Voxels are stored in chunks of 32x32x32 cells (128 studs). Each chunk is run length encoded:
--// runs of (count u16, material index u8, solid occupancy u8, water occupancy u8), materials index the chunk's palette.
--// Reading the whole terrain is expensive, so the result is kept until Studio records an edit (or a command asks again).
local TERRAIN_CHUNK = 32
local TERRAIN_MAX_CHUNK_READS = 6000
local TERRAIN_MATERIALS = {
    "Asphalt", "Basalt", "Brick", "Cobblestone", "Concrete", "CrackedLava", "Glacier", "Grass", "Ground", "Ice",
    "LeafyGrass", "Limestone", "Mud", "Pavement", "Rock", "Salt", "Sand", "Sandstone", "Slate", "Snow", "WoodPlanks",
}

local terrain_cache = {dirty = true, value = nil}
local terrain_watching = false

--[[
Forget the cached terrain, the next serialization reads the voxels again.
]]
function instances.invalidate_terrain()
    terrain_cache.dirty = true
end

local function watch_terrain()
    if terrain_watching then return end
    terrain_watching = true
    local ok, history = pcall(function() return game:GetService("ChangeHistoryService") end)
    if not ok then return end
    for _, name in ipairs({"OnUndo", "OnRedo", "OnRecordingFinished"}) do
        pcall(function()
            history[name]:Connect(function() terrain_cache.dirty = true end)
        end)
    end
end

local function chunk_region(cx, cy, cz)
    local size = TERRAIN_CHUNK * 4
    local min = Vector3.new(cx * size, cy * size, cz * size)
    return Region3.new(min, min + Vector3.new(size, size, size))
end

--[[
Reads one chunk as (materials, solid occupancy, water occupancy) 3D arrays.
]]
local function read_chunk(terrain, cx, cy, cz)
    local region = chunk_region(cx, cy, cz)
    local ok, channels = pcall(function()
        return terrain:ReadVoxelChannels(region, 4, {"SolidMaterial", "SolidOccupancy", "LiquidOccupancy"})
    end)
    if ok and channels and channels.SolidMaterial then
        return channels.SolidMaterial, channels.SolidOccupancy, channels.LiquidOccupancy
    end
    local materials, occupancies = terrain:ReadVoxels(region, 4)
    return materials, occupancies, nil
end

local function encode_chunk(materials, solids, liquids)
    local palette, paletteIndex = {}, {}
    local runs = {}
    local count = 0
    local lastM, lastO, lastL, run = nil, nil, nil, 0
    local filled = 0

    local function flush()
        if run > 0 then
            table.insert(runs, {run, lastM, lastO, lastL})
        end
    end

    for x = 1, #materials do
        local mx, ox, lx = materials[x], solids[x], liquids and liquids[x]
        for y = 1, #mx do
            local my, oy, ly = mx[y], ox[y], lx and lx[y]
            for z = 1, #my do
                local material = my[z]
                local name = typeof(material) == "EnumItem" and material.Name or tostring(material)
                local occupancy = math.clamp(math.floor((oy[z] or 0) * 255 + 0.5), 0, 255)
                local water = ly and math.clamp(math.floor((ly[z] or 0) * 255 + 0.5), 0, 255) or 0
                if name == "Air" then occupancy = 0 end
                if name == "Water" and not ly then
                    --// old style water: a material of its own
                    water, occupancy, name = occupancy, 0, "Air"
                end

                local index = paletteIndex[name]
                if not index then
                    table.insert(palette, name)
                    index = #palette - 1
                    paletteIndex[name] = index
                end

                if occupancy > 0 or water > 0 then filled += 1 end
                if index == lastM and occupancy == lastO and water == lastL and run < 65535 then
                    run += 1
                else
                    flush()
                    lastM, lastO, lastL, run = index, occupancy, water, 1
                end
                count += 1
            end
        end
    end
    flush()

    if filled == 0 then return nil, 0 end

    local buf = buffer.create(#runs * 5)
    for i, r in ipairs(runs) do
        local offset = (i - 1) * 5
        buffer.writeu16(buf, offset, r[1])
        buffer.writeu8(buf, offset + 2, r[2])
        buffer.writeu8(buf, offset + 3, r[3])
        buffer.writeu8(buf, offset + 4, r[4])
    end
    return {P = palette, D = hashlib.bin_to_base64(buffer.tostring(buf))}, filled
end

--[[
Expands a stored chunk back into 3D arrays (all air when chunk is nil).
]]
local function decode_chunk(chunk)
    local n = TERRAIN_CHUNK
    local materials, solids, liquids = table.create(n), table.create(n), table.create(n)
    for x = 1, n do
        materials[x], solids[x], liquids[x] = table.create(n), table.create(n), table.create(n)
        for y = 1, n do
            materials[x][y], solids[x][y], liquids[x][y] = table.create(n, Enum.Material.Air), table.create(n, 0), table.create(n, 0)
        end
    end
    if not chunk then return materials, solids, liquids end

    local palette = {}
    for i, name in ipairs(chunk.P) do
        local ok, material = pcall(function() return Enum.Material[name] end)
        palette[i - 1] = ok and material or Enum.Material.Air
    end

    local buf = buffer.fromstring(hashlib.base64_to_bin(chunk.D))
    local cell = 0
    for offset = 0, buffer.len(buf) - 5, 5 do
        local run = buffer.readu16(buf, offset)
        local material = palette[buffer.readu8(buf, offset + 2)]
        local solid = buffer.readu8(buf, offset + 3) / 255
        local water = buffer.readu8(buf, offset + 4) / 255
        for _ = 1, run do
            local x = cell // (n * n) + 1
            local y = (cell // n) % n + 1
            local z = cell % n + 1
            materials[x][y][z], solids[x][y][z], liquids[x][y][z] = material, solid, water
            cell += 1
        end
    end
    return materials, solids, liquids
end

local function write_chunk(terrain, cx, cy, cz, chunk)
    local materials, solids, liquids = decode_chunk(chunk)
    local region = chunk_region(cx, cy, cz)
    local ok = pcall(function()
        terrain:WriteVoxelChannels(region, 4, {SolidMaterial = materials, SolidOccupancy = solids, LiquidOccupancy = liquids})
    end)
    if not ok then
        --// older API: water is a material of its own
        for x = 1, #materials do
            for y = 1, #materials[x] do
                for z = 1, #materials[x][y] do
                    if solids[x][y][z] == 0 and liquids[x][y][z] > 0 then
                        materials[x][y][z], solids[x][y][z] = Enum.Material.Water, liquids[x][y][z]
                    end
                end
            end
        end
        terrain:WriteVoxels(region, 4, materials, solids)
    end
end

--[[
Which chunks to look at. A "RoGitTerrainBounds" attribute ("x1,y1,z1,x2,y2,z2" in studs) wins,
otherwise rings of chunks around the origin are scanned until every cell Terrain:CountCells() knows about was found.
Returns an iterator over chunk coordinates, and the expected number of filled cells (or nil).
]]
local function terrain_chunks(terrain)
    local bounds = terrain:GetAttribute("RoGitTerrainBounds")
    if type(bounds) == "string" then
        local v = {}
        for number in bounds:gmatch("-?%d+%.?%d*") do table.insert(v, tonumber(number)) end
        if #v == 6 then
            local size = TERRAIN_CHUNK * 4
            local list = {}
            for cx = math.floor(math.min(v[1], v[4]) / size), math.floor(math.max(v[1], v[4]) / size) do
                for cy = math.floor(math.min(v[2], v[5]) / size), math.floor(math.max(v[2], v[5]) / size) do
                    for cz = math.floor(math.min(v[3], v[6]) / size), math.floor(math.max(v[3], v[6]) / size) do
                        table.insert(list, {cx, cy, cz})
                    end
                end
            end
            return list, nil, true
        end
    end

    local ok, cells = pcall(function() return terrain:CountCells() end)
    local expected = ok and tonumber(cells) or nil
    return nil, expected, false
end

local function read_terrain_voxels(terrain)
    local chunks = {}
    local list, expected, explicit = terrain_chunks(terrain)

    if explicit then
        for _, c in ipairs(list) do
            local data = encode_chunk(read_chunk(terrain, c[1], c[2], c[3]))
            if data then
                data.X, data.Y, data.Z = c[1], c[2], c[3]
                table.insert(chunks, data)
            end
            Utilities.roYield()
        end
        return chunks, true
    end

    if expected == 0 then
        terrain_cache.known = {}
        return chunks, true
    end

    local read, found, reads = {}, 0, 0
    local function visit(cx, cy, cz)
        cx, cy, cz = cx + 0, cy + 0, cz + 0 --// no "-0" chunks (a loop from -0 to 0 produces those)
        local key = cx .. "," .. cy .. "," .. cz
        if read[key] then return end
        read[key] = true
        reads += 1
        local data, filled = encode_chunk(read_chunk(terrain, cx, cy, cz))
        if data then
            data.X, data.Y, data.Z = cx, cy, cz
            table.insert(chunks, data)
            found += filled
        end
        Utilities.roYield()
    end
    local function done()
        return expected ~= nil and found >= expected
    end

    --// 1. where terrain was last time, then around it (edits usually happen next to existing terrain)
    if terrain_cache.known and next(terrain_cache.known) then
        for _, c in pairs(terrain_cache.known) do
            visit(c[1], c[2], c[3])
        end
        local frontier = table.clone(chunks)
        while not done() and #frontier > 0 and reads < TERRAIN_MAX_CHUNK_READS do
            local nextFrontier = {}
            local before = #chunks
            for _, c in ipairs(frontier) do
                for dx = -1, 1 do for dy = -1, 1 do for dz = -1, 1 do
                    visit(c.X + dx, c.Y + dy, c.Z + dz)
                end end end
            end
            for i = before + 1, #chunks do table.insert(nextFrontier, chunks[i]) end
            frontier = nextFrontier
        end
    end

    --// 2. rings around the origin, 1536 studs of height (-512 .. 1024)
    if not done() then
        for radius = 0, 64 do
            for cx = -radius, radius do
                for cz = -radius, radius do
                    if math.max(math.abs(cx), math.abs(cz)) == radius then
                        for cy = -4, 7 do
                            visit(cx, cy, cz)
                        end
                    end
                end
            end
            if done() or reads >= TERRAIN_MAX_CHUNK_READS or (not expected and radius >= 8) then
                break
            end
        end
    end

    terrain_cache.known = {}
    for _, c in ipairs(chunks) do
        terrain_cache.known[c.X .. "," .. c.Y .. "," .. c.Z] = {c.X, c.Y, c.Z}
    end

    if not done() and expected then
        warn("roGit: only part of the terrain could be located. Set a \"RoGitTerrainBounds\" attribute on Terrain (\"x1,y1,z1,x2,y2,z2\" in studs) to store all of it.")
    end
    return chunks, done()
end

SPECIAL.Terrain = {
    key = "_terrain",

    read = function(terrain)
        watch_terrain()
        if not terrain_cache.dirty and terrain_cache.value and terrain_cache.terrain == terrain then
            return terrain_cache.value
        end

        local colors = {}
        for _, name in ipairs(TERRAIN_MATERIALS) do
            local ok, color = pcall(function() return terrain:GetMaterialColor(Enum.Material[name]) end)
            if ok and color then
                colors[name] = instances.serialize_property(color)
            end
        end

        local chunks = read_terrain_voxels(terrain)
        table.sort(chunks, function(a, b)
            if a.X ~= b.X then return a.X < b.X end
            if a.Y ~= b.Y then return a.Y < b.Y end
            return a.Z < b.Z
        end)

        local value = {Colors = colors, Chunks = chunks}
        terrain_cache.value, terrain_cache.terrain, terrain_cache.dirty = value, terrain, false
        return value
    end,

    write = function(terrain, value)
        for name, color in pairs(value.Colors or {}) do
            pcall(function() terrain:SetMaterialColor(Enum.Material[name], instances.deserialize_property(color, "Color3")) end)
        end

        --// compare against what's there (the cached read when nothing was edited since)
        local ok, current = pcall(SPECIAL.Terrain.read, terrain)
        current = ok and current or {Chunks = {}}
        local wrote = false

        local function key(c) return c.X .. "," .. c.Y .. "," .. c.Z end
        local now = {}
        for _, c in ipairs(current.Chunks or {}) do now[key(c)] = c end

        --// rewrite chunks that differ, and empty the ones the commit doesn't have
        local wanted = {}
        for _, c in ipairs(value.Chunks or {}) do
            wanted[key(c)] = true
            local existing = now[key(c)]
            if not existing or existing.D ~= c.D or table.concat(existing.P, ",") ~= table.concat(c.P, ",") then
                write_chunk(terrain, c.X, c.Y, c.Z, c)
                wrote = true
                Utilities.roYield()
            end
        end
        for k, c in pairs(now) do
            if not wanted[k] then
                write_chunk(terrain, c.X, c.Y, c.Z, nil)
                wrote = true
                Utilities.roYield()
            end
        end
        if wrote then
            terrain_cache.dirty = true
        end
    end,
}

--// ---------------------------------------------------------------- Path2D
SPECIAL.Path2D = {
    key = "_controlPoints",

    read = function(path)
        local points = {}
        for _, point in ipairs(path:GetControlPoints()) do
            table.insert(points, {
                Position = instances.serialize_property(point.Position),
                LeftTangent = instances.serialize_property(point.LeftTangent),
                RightTangent = instances.serialize_property(point.RightTangent),
            })
        end
        return {Points = points}
    end,

    write = function(path, value)
        local points = {}
        for _, point in ipairs(value.Points or {}) do
            table.insert(points, Path2DControlPoint.new(
                instances.deserialize_property(point.Position, "UDim2"),
                instances.deserialize_property(point.LeftTangent, "UDim2"),
                instances.deserialize_property(point.RightTangent, "UDim2")
            ))
        end
        path:SetControlPoints(points)
    end,
}

--// Classes where roGit knows it can't store everything. `git doctor` lists these.
instances.KNOWN_LIMITS = {}

--// Properties that are real and settable but missing from the reflected "serialized" list.
local EXTRA_PROPERTIES = {
    {class = "Model", names = {"WorldPivot"}},
    {class = "BasePart", names = {"PivotOffset"}},
}

local PSEUDO_KEYS = {}
for _, handler in pairs(SPECIAL) do
    PSEUDO_KEYS[handler.key] = handler
end

--[[
Creates an instance of a class. Most come from Instance.new, a few (EditableImage/EditableMesh) only exist through AssetService.
`props` is the decoded property list the instance is about to receive. Returns nil if the class can't be created.
]]
function instances.create_instance(className, props)
    local ok, inst = pcall(Instance.new, className)
    if ok then return inst end

    local handler = SPECIAL[className]
    if handler and handler.create then
        local value = nil
        for _, prop in ipairs(props or {}) do
            if prop.name == handler.key then value = prop.value end
        end
        local created, result = pcall(handler.create, value)
        if created and typeof(result) == "Instance" then return result end
    end
    return nil
end

--[[
Names of the properties that currently hold a value which can also be "nothing" (an instance reference or
custom physical properties). When the blob being applied doesn't have them, they were cleared.
]]
function instances.nullable_properties(instance)
    local names = {}
    for _, entry in ipairs(get_class_properties(instance.ClassName)) do
        local ok, value = pcall(function() return instance[entry.publicName] end)
        if ok and value ~= nil then
            local kind = typeof(value)
            if kind == "Instance" or kind == "PhysicalProperties" then
                table.insert(names, entry.publicName)
            end
        end
    end
    return names
end

--[[
Is this property entry one of the pseudo properties above (and not something to assign with `instance[name] = value`)?
]]
function instances.is_pseudo_property(propData)
    return PSEUDO_KEYS[propData.name] ~= nil and propData.valueType == propData.name
end

--[[
Restores the data of a pseudo property. Returns true on success.
]]
function instances.apply_pseudo_property(instance, propData)
    local handler = PSEUDO_KEYS[propData.name]
    if not handler or type(propData.value) ~= "table" then return false end
    local ok, err = pcall(handler.write, instance, propData.value)
    if not ok then
        warn("roGit: couldn't restore " .. instance.ClassName .. " '" .. instance.Name .. "': " .. tostring(err))
    end
    return ok
end

--[[
Serializes instance & instance properties
]]
function instances.serialize_instance(instance, report)
    assert(typeof(instance) == "Instance", "no instance passed or instance is not a Instance")

    active_report = report
    local className = instance.ClassName
    local instanceProperties = {}

    table.insert(instanceProperties, {
        name = "ClassName",
        value = className,
        valueType = "string"
    })

    local added = {}
    local function add_property(publicName, internalName)
        if added[publicName] then return end
        local ok, err = pcall(function()
            local val = instance[publicName]
            if val == nil and internalName and publicName ~= internalName then
                val = instance[internalName]
            end

            if val ~= nil then
                local serialized, unsupportedType = instances.serialize_property(val)
                if serialized == nil then
                    note("unsupported", className, publicName, unsupportedType)
                    return
                end
                added[publicName] = true
                table.insert(instanceProperties, {
                    name = publicName,
                    value = serialized,
                    valueType = typeof(val)
                })
            end
        end)
        if not ok then
            note("unreadable", className, publicName, tostring(err))
        end
    end

    for _, entry in ipairs(get_class_properties(className)) do
        add_property(entry.publicName, entry.internalName)
    end
    for _, extra in ipairs(EXTRA_PROPERTIES) do
        if instance:IsA(extra.class) then
            for _, name in ipairs(extra.names) do
                add_property(name)
            end
        end
    end

    if instance:IsA("LuaSourceContainer") then
        --// what the script editor shows wins (with drafts/collaborative editing it can differ from .Source)
        pcall(function()
            local document = game:GetService("ScriptEditorService"):FindScriptDocument(instance)
            local text = document and document:GetText()
            if type(text) == "string" then
                for i, prop in ipairs(instanceProperties) do
                    if prop.name == "Source" then table.remove(instanceProperties, i) break end
                end
                added.Source = nil
                table.insert(instanceProperties, {name = "Source", value = text, valueType = "string"})
                added.Source = true
            end
        end)
        pcall(function()
            if not added.Source then
                local val = (instance :: any).Source
                if val ~= nil then
                    table.insert(instanceProperties, {
                        name = "Source",
                        value = val,
                        valueType = "string"
                    })
                end
            end
        end)
    end

    --// Data that only exists behind methods (pixels, meshes, ...)
    local handler = SPECIAL[className]
    if handler then
        local ok, value = pcall(handler.read, instance)
        if ok then
            table.insert(instanceProperties, {name = handler.key, value = value, valueType = handler.key})
            note("special", className, "", handler.key)
        else
            note("failed", className, handler.key, tostring(value))
            warn("roGit: couldn't read the data of " .. className .. " '" .. instance.Name .. "': " .. tostring(value))
        end
    end
    if instances.KNOWN_LIMITS[className] then
        note("limits", className, "", instances.KNOWN_LIMITS[className])
    end

    local attributes = instance:GetAttributes()
    local attrKeys = {}
    for k in pairs(attributes) do table.insert(attrKeys, k) end
    table.sort(attrKeys)

    local attrData = {}
    for _, k in ipairs(attrKeys) do
        local v = attributes[k]
        local serialized, unsupportedType = instances.serialize_property(v)
        if serialized == nil then
            note("unsupported", className, "@" .. k, unsupportedType)
        else
            table.insert(attrData, {
                name = k,
                value = serialized,
                valueType = typeof(v)
            })
        end
    end

    if #attrData > 0 then
        table.insert(instanceProperties, {
            name = "_attributes",
            value = attrData,
            valueType = "_attributes"
        })
    end

    local tags = instance:GetTags()
    if #tags > 0 then
        table.sort(tags)
        table.insert(instanceProperties, {
            name = "_tags",
            value = tags,
            valueType = "_tags"
        })
    end

    --// Final stable sort of all properties (including internal ones)
    table.sort(instanceProperties, function(a, b)
        return a.name < b.name
    end)

    active_report = nil
    return HttpService:JSONEncode(instanceProperties)
end

--[[
Stages an instance into the index.
]]
function instances.stage_instance(instance, index, seen_ids, assignedVirtualPath)
        seen_ids = seen_ids or {}
    local fullPath = assignedVirtualPath

    local hasValidChildren = false
    for _, child in ipairs(instance:GetChildren()) do
        if child ~= bash.getGitFolderRoot() and not Handlers.is_ignored(child:GetFullName()) and not child:IsDescendantOf(bash.getGitFolderRoot()) then
            hasValidChildren = true
            break
        end
    end

    if hasValidChildren then
        fullPath = fullPath .. "/.properties"
    end

    local current_id = instance:GetAttribute(ROGIT_ID)
    if current_id then
        if seen_ids[current_id] then
            current_id = HttpService:GenerateGUID(false)
            instance:SetAttribute(ROGIT_ID, current_id)
        end
        seen_ids[current_id] = true
    else
        current_id = HttpService:GenerateGUID(false)
        instance:SetAttribute(ROGIT_ID, current_id)
        seen_ids[current_id] = true
    end

    local serialized = instances.serialize_instance(instance)
    local blobSha = Handlers.write_blob(serialized)

    index[fullPath] = {
        mode = "100644",
        sha = blobSha
    }
end

--[[
Stage instances into the index recursively.
]]
function instances.stage_recursive(instance, index, seen_ids, perf, parentVirtualPath)
    if Handlers.is_ignored(instance:GetFullName()) then return end
    seen_ids = seen_ids or {}
    perf = perf or { last_yield = os.clock() }

    local myVirtualPath = instance.Name
    if parentVirtualPath then
        myVirtualPath = parentVirtualPath .. "/" .. Utilities.escape_name(instance.Name)
    end
    
    -- Root services passed to stage_recursive initially get their own name as path
    if not parentVirtualPath then
        myVirtualPath = instance.Name
        -- Ensure root services and certain singletons have stable IDs
        local forcedID = nil
        if instance.Parent == game then
            forcedID = "SERVICE_" .. instance.Name
        elseif instance.Name == "Camera" and instance:IsA("Camera") and instance.Parent and instance.Parent:IsA("Workspace") then
            forcedID = "SERVICE_Camera"
        elseif instance.Name == "Terrain" and instance:IsA("Terrain") and instance.Parent and instance.Parent:IsA("Workspace") then
            forcedID = "SERVICE_Terrain"
        end

        if forcedID then
            if instance:GetAttribute(ROGIT_ID) ~= forcedID then
                instance:SetAttribute(ROGIT_ID, forcedID)
            end
        elseif not instance:GetAttribute(ROGIT_ID) then
            instance:SetAttribute(ROGIT_ID, HttpService:GenerateGUID(true))
        end
    else
        myVirtualPath = parentVirtualPath
    end

    instances.stage_instance(instance, index, seen_ids, myVirtualPath)
    Utilities.roYield()

    local valid_children = {}
    for _, child in ipairs(instance:GetChildren()) do
        if child ~= bash.getGitFolderRoot() and not child:IsDescendantOf(bash.getGitFolderRoot()) then
            -- Ensure child has an ID for stable sorting tie-breaking
            local id = child:GetAttribute(ROGIT_ID)
            if not id then
                id = HttpService:GenerateGUID(false)
                child:SetAttribute(ROGIT_ID, id)
            end
            table.insert(valid_children, child)
        end
    end

    -- Deterministic sort: Name first, then ROGIT_ID as a tie-breaker
    table.sort(valid_children, function(a, b)
        if a.Name ~= b.Name then
            return a.Name < b.Name
        end
        return (a:GetAttribute(ROGIT_ID) or "") < (b:GetAttribute(ROGIT_ID) or "")
    end)
    
    local sibling_counts = {}
    for _, child in ipairs(valid_children) do
        sibling_counts[child.Name] = (sibling_counts[child.Name] or 0) + 1
    end

    local current_indices = {}
    for _, child in ipairs(valid_children) do
        local n = child.Name
        current_indices[n] = (current_indices[n] or 0) + 1
        
        local childVirtualName = Utilities.escape_name(n)
        if sibling_counts[n] > 1 then
            childVirtualName = childVirtualName .. " [" .. tostring(current_indices[n]) .. "]"
        end
        
        local childVirtualPath = myVirtualPath .. "/" .. childVirtualName
        instances.stage_recursive(child, index, seen_ids, perf, childVirtualPath)
    end
end

return instances