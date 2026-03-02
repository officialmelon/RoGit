local instances = {}

--// quick definitions
local HttpService = game:GetService("HttpService")

local Utilities = require(script.Parent.utilities)
local Handlers = require(script.Parent.git_handlers)
local bash = require(script.Parent.Parent.bash)

local ROGIT_ID = "_rogit_id"

--[[
Helper to round numbers to avoid floating point jitter in Git.
]]
local function round(num)
    if typeof(num) ~= "number" then return num end
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
        r = tostring(prop)
    else
        if typeof(prop) == "userdata" or typeof(prop) == "function" or typeof(prop) == "thread" then
            r = tostring(prop)
        end
    end

    return r
end

--[[
    Serializes a property back into an Instance property.
]]
function instances.deserialize_property(prop, propType)
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

--[[
Serializes instance & instance properties
]]
function instances.serialize_instance(instance)
    assert(typeof(instance) == "Instance", "no instance passed or instance is not a Instance")

    local instancePropertiesClassList = game:GetService("ReflectionService"):GetPropertiesOfClass(instance.ClassName)
    local instanceProperties = {}
    
    local skipList = {
        Parent = true,
    }

    table.insert(instanceProperties, {
        name = "ClassName",
        value = instance.ClassName,
        valueType = "string"
    })

    for _, propertyData in ipairs(instancePropertiesClassList) do
        if propertyData.Serialized == true and not skipList[propertyData.Name] then
            -- If we have both lowercase and PascalCase (e.g. 'size' vs 'Size'), pick PascalCase for readability
            -- But usually Serialized == true is the 'true' internal name.
            -- To avoid a 4500-file diff where 'Size' becomes 'size', we'll try to keep the human version if it's the same type.
            pcall(function()
                local val = instance[propertyData.Name]
                if val ~= nil then
                    table.insert(instanceProperties, {
                        name = propertyData.Name,
                        value = instances.serialize_property(val),
                        valueType = typeof(val)
                    })
                end
            end)
        end
    end

    -- No immediate sort here, we'll sort at the end
    
    if instance:IsA("LuaSourceContainer") then
        pcall(function()
            local found = false
            for _, prop in ipairs(instanceProperties) do
                if prop.name == "Source" then
                    found = true
                    break
                end
            end
            if not found then
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
    
    -- Serialization is now handled inside the loop for standard props

    local attributes = instance:GetAttributes()
    local attrKeys = {}
    for k in pairs(attributes) do table.insert(attrKeys, k) end
    table.sort(attrKeys)

    local attrData = {}
    for _, k in ipairs(attrKeys) do
        local v = attributes[k]
        table.insert(attrData, {
            name = k,
            value = instances.serialize_property(v),
            valueType = typeof(v)
        })
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

    -- Final stable sort of all properties (including internal ones)
    table.sort(instanceProperties, function(a, b)
        return a.name < b.name
    end)

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
        myVirtualPath = parentVirtualPath .. "/" .. instance.Name
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
        
        local childVirtualName = n
        if sibling_counts[n] > 1 then
            childVirtualName = n .. " [" .. tostring(current_indices[n]) .. "]"
        end
        
        local childVirtualPath = myVirtualPath .. "/" .. childVirtualName
        instances.stage_recursive(child, index, seen_ids, perf, childVirtualPath)
    end
end

return instances