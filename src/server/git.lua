
--[[
This is an extremely large file that should be cleaned/split for future reference.
This holds all the commands for `git` & most functionality.

]]
local git = {}

local HttpService = game:GetService("HttpService")

local config = require(script.Parent.config)
local arguments = require(script.Parent.arguments)

local hashlib = require(script.Parent.libs.hashlib)
local zlib = require(script.Parent.libs.zlib)
local bash = require(script.Parent.bash)
local git_proto = require(script.Parent.libs.git_proto)
local ini_parser = require(script.Parent.libs.ini_parser)

local ignore_patterns = nil

local ROGIT_ID = "_rogit_id"

local ACTIVE_PLUGIN = nil
function git.setPlugin(plugin)
    ACTIVE_PLUGIN = plugin
end

local terminal_prompt_callback = nil

function git.replacePromptCallback(prompt_cb)
    terminal_prompt_callback = prompt_cb
end

local function ask_for_credential(prompt_text, is_password)
    if terminal_prompt_callback then
        return terminal_prompt_callback(prompt_text, is_password)
    end
    return nil
end

-- Create command
arguments.createCommand("git", function(...)
    arguments.execute("git", "help", ...)
end)

--[[
Utilities

warn_assert
warns instead of asserting.

calculate_hash
calculates the hash of a instance based off properties.

]]

-- (https://devforum.roblox.com/t/how-to-save-parts-and-the-idea-of-serialization/524311)
local function serialize_property(prop)
    assert(prop ~= nil, "No property parsed to serialize!")

    local type = typeof(prop)
    local r = prop

    if type == "BrickColor" then
        r = tostring(prop)
    elseif type == "CFrame" then
        r = {pos = serialize_property(prop.Position), rX = serialize_property(prop.rightVector), rY = serialize_property(prop.upVector), rZ = serialize_property(-prop.lookVector)}
    elseif type == "Vector3" then
        r = {X = prop.X, Y = prop.Y, Z = prop.Z}
    elseif type == "Vector2" then
        r = {X = prop.X, Y = prop.Y}
    elseif type == "Color3" then
        r = {Color3.toHSV(prop)}
    elseif type == "EnumItem" then
        r = {string.split(tostring(prop), ".")[2], string.split(tostring(prop), ".")[3]} 
    elseif type == "UDim" then
        r = {Scale = prop.Scale, Offset = prop.Offset}
    elseif type == "UDim2" then
        r = {X = serialize_property(prop.X), Y = serialize_property(prop.Y)}
    elseif type == "Rect" then
        r = {Min = serialize_property(prop.Min), Max = serialize_property(prop.Max)}
    elseif type == "NumberRange" then
        r = {Min = prop.Min, Max = prop.Max}
    elseif type == "PhysicalProperties" then
        r = {Density = prop.Density, Friction = prop.Friction, Elasticity = prop.Elasticity, FrictionWeight = prop.FrictionWeight, ElasticityWeight = prop.ElasticityWeight}
    elseif type == "Font" then
        r = {Family = prop.Family, Weight = serialize_property(prop.Weight), Style = serialize_property(prop.Style)}
    elseif type == "NumberSequenceKeypoint" then
        r = {Time = prop.Time, Value = prop.Value, Envelope = prop.Envelope}
    elseif type == "ColorSequenceKeypoint" then
        r = {Time = prop.Time, Value = serialize_property(prop.Value)}
    elseif type == "NumberSequence" then
        local keypoints = {}
        for _, kp in ipairs(prop.Keypoints) do
            table.insert(keypoints, serialize_property(kp))
        end
        r = {Keypoints = keypoints}
    elseif type == "ColorSequence" then
        local keypoints = {}
        for _, kp in ipairs(prop.Keypoints) do
            table.insert(keypoints, serialize_property(kp))
        end
        r = {Keypoints = keypoints}
    elseif type == "Instance" then
        r = {Guid = prop:GetAttribute("_rogit_id")}
    elseif type == "Content" then
        r = tostring(prop)
    end

    return r
end

local function deserialize_property(prop, propType)
    if propType == "BrickColor" then
        return BrickColor.new(prop)
    elseif propType == "CFrame" then
        local pos = deserialize_property(prop.pos, "Vector3")
        local rX = deserialize_property(prop.rX, "Vector3")
        local rY = deserialize_property(prop.rY, "Vector3")
        local rZ = deserialize_property(prop.rZ, "Vector3")
        return CFrame.fromMatrix(pos, rX, rY, -rZ)
    elseif propType == "Vector3" then
        return Vector3.new(prop.X, prop.Y, prop.Z)
    elseif propType == "Vector2" then
        return Vector2.new(prop.X, prop.Y)
    elseif propType == "Color3" then
        return Color3.fromHSV(prop[1], prop[2], prop[3])
    elseif propType == "EnumItem" then
        return Enum[prop[1]][prop[2]]
    elseif propType == "UDim" then
        return UDim.new(prop.Scale, prop.Offset)
    elseif propType == "UDim2" then
        return UDim2.new(deserialize_property(prop.X, "UDim"), deserialize_property(prop.Y, "UDim"))
    elseif propType == "Rect" then
        return Rect.new(deserialize_property(prop.Min, "Vector2"), deserialize_property(prop.Max, "Vector2"))
    elseif propType == "NumberRange" then
        return NumberRange.new(prop.Min, prop.Max)
    elseif propType == "PhysicalProperties" then
        return PhysicalProperties.new(prop.Density, prop.Friction, prop.Elasticity, prop.FrictionWeight, prop.ElasticityWeight)
    elseif propType == "Font" then
        return Font.new(prop.Family, deserialize_property(prop.Weight, "EnumItem"), deserialize_property(prop.Style, "EnumItem"))
    elseif propType == "NumberSequenceKeypoint" then
        return NumberSequenceKeypoint.new(prop.Time, prop.Value, prop.Envelope)
    elseif propType == "ColorSequenceKeypoint" then
        return ColorSequenceKeypoint.new(prop.Time, deserialize_property(prop.Value, "Color3"))
    elseif propType == "NumberSequence" then
        local keypoints = {}
        for _, kp in ipairs(prop.Keypoints) do
            table.insert(keypoints, deserialize_property(kp, "NumberSequenceKeypoint"))
        end
        return NumberSequence.new(keypoints)
    elseif propType == "ColorSequence" then
        local keypoints = {}
        for _, kp in ipairs(prop.Keypoints) do
            table.insert(keypoints, deserialize_property(kp, "ColorSequenceKeypoint"))
        end
        return ColorSequence.new(keypoints)
    end
    return prop
end

local function parse_path(p)
    if not p or p == "" then return nil end
    local clean = p:gsub("^game[./]", ""):gsub("^Workspace[./]", "Workspace/"):gsub("%.", "/")
    local segments = string.split(clean, "/")
    local currObj = game
    for _, segment in ipairs(segments) do
        if currObj and currObj:FindFirstChild(segment) then
            currObj = currObj:FindFirstChild(segment)
        else
            return nil, segments[#segments], segments
        end
    end
    return currObj, segments[#segments], segments
end

-- based off git implementations
local function write_object(typeName, content)
    local header = typeName .. " " .. tostring(#content) .. "\0"
    local full = header .. content
    local sha = hashlib.sha1(full)

    local dir = bash.createFolder(
        bash.getGitFolderRoot(),
        "objects/" .. string.sub(sha, 1, 2)
    )

    if not bash.getFileContents(dir, string.sub(sha, 3)) then
        bash.createFile(
            dir,
            string.sub(sha, 3),
            hashlib.bin_to_base64(zlib.compressZlib(full))
        )
    end

    return sha
end

local function read_object(sha)
    local gitRoot = bash.getGitFolderRoot()
    if not gitRoot then return nil end
    local objsFolder = gitRoot:FindFirstChild("objects")
    if not objsFolder then return nil end
    local dir = objsFolder:FindFirstChild(string.sub(sha, 1, 2))
    if not dir then return nil end

    local raw64 = bash.getFileContents(dir, string.sub(sha, 3))
    if not raw64 then return nil end

    local data = hashlib.base64_to_bin(raw64)
    local raw = zlib.decompressZlib(data)
    if not raw then return nil end

    local nullIndex = string.find(raw, "\0", 1, true)
    if not nullIndex then return nil end

    local header = string.sub(raw, 1, nullIndex - 1)
    local content = string.sub(raw, nullIndex + 1)

    local typeName = string.split(header, " ")[1]

    return {type = typeName, content = content}
end

local function write_blob(serializedInstance)
    return write_object("blob", serializedInstance)
end

local function read_index()
    local raw = bash.getFileContents(bash.getGitFolderRoot(), "index")
    if raw == "" then
        return {}
    end

    return HttpService:JSONDecode(raw)
end

local function write_index(tbl)
    assert(tbl, "Index table is nil!")

    local encoded = HttpService:JSONEncode(tbl)

    bash.modifyFileContents(
        bash.getGitFolderRoot(),
        "index",
        encoded
    )
end

local function serialize_instance(instance)
    -- Check instance exists
    assert(typeof(instance) == "Instance", "no instance passed or instance is not a instance")
    
    -- Get properties list and loop through all properties for said instance
    local instancePropertiesClassList = game:GetService("ReflectionService"):GetPropertiesOfClass(instance.ClassName)
    local instanceProperties = {}
    
    for _, property in instancePropertiesClassList do 
        pcall(function ()
            local val = instance[property.Name]
            if val ~= nil then 
                table.insert(instanceProperties, {
                    name = property.Name,
                    value = val,
                    valueType = typeof(val)
                })
            end
        end)
    end
    
    for _, instanceProp in instanceProperties do 
        if instanceProp.value ~= nil then 
            instanceProp.value = serialize_property(instanceProp.value)
        end
    end

    local attributes = instance:GetAttributes()
    local attrData = {}
    for k, v in pairs(attributes) do
        attrData[k] = {value = serialize_property(v), valueType = typeof(v)}
    end
    if next(attrData) then
        table.insert(instanceProperties, {
            name = "_attributes",
            value = attrData,
            valueType = "_attributes"
        })
    end

    local tags = instance:GetTags()
    if #tags > 0 then
        table.insert(instanceProperties, {
            name = "_tags",
            value = tags,
            valueType = "_tags"
        })
    end

    return HttpService:JSONEncode(instanceProperties)
end


local function load_ignore_patterns()
    if ignore_patterns ~= nil then
        return
    end

    ignore_patterns = {}
    local ignore_file = bash.getGitFolderRoot().Parent:FindFirstChild(".rogitignore")
    if ignore_file then
        local content = bash.getFileContents(bash.getGitFolderRoot().Parent, ".rogitignore")
        for line in string.gmatch(content, "[^\r\n]+") do
            line = string.match(line, "^%s*(.-)%s*$")
            if string.sub(line, 1, 1) ~= "#" and #line > 0 then
                table.insert(ignore_patterns, line)
            end
        end
    end
end

local function is_ignored(path)
    load_ignore_patterns()

    local path_slashes = string.gsub(path, "%.", "/")

    for _, pattern in ipairs(ignore_patterns) do
        if path_slashes == pattern then return true end
        if string.sub(path_slashes, 1, #pattern + 1) == pattern .. "/" then return true end
        if string.sub(path_slashes, -#pattern - 1) == "/" .. pattern then return true end
        if string.find(path_slashes, "/" .. pattern .. "/", 1, true) then return true end
    end
    return false
end

local function stage_instance(instance, index, seen_ids, parentVirtualPath)
    seen_ids = seen_ids or {}
    local pathSegments = {}
    if parentVirtualPath then
        for part in string.gmatch(parentVirtualPath, "[^/]+") do
            table.insert(pathSegments, part)
        end
        table.insert(pathSegments, instance.Name)
    else
        local curr = instance
        while curr and curr ~= game do
            table.insert(pathSegments, 1, curr.Name)
            curr = curr.Parent
        end
    end

    local fullPath = table.concat(pathSegments, "/")

    local hasValidChildren = false
    for _, child in ipairs(instance:GetChildren()) do
        if child ~= bash.getGitFolderRoot() and not is_ignored(child:GetFullName()) and not child:IsDescendantOf(bash.getGitFolderRoot()) then
            hasValidChildren = true
            break
        end
    end

    local baseName = fullPath
    local collisionBase = baseName
    if hasValidChildren then
        fullPath = fullPath .. "/.properties"
    end

    local originalPath = fullPath
    local collisionCount = 1
    while index[fullPath] do
        fullPath = originalPath .. " [" .. tostring(collisionCount) .. "]"
        collisionBase = baseName .. " [" .. tostring(collisionCount) .. "]"
        collisionCount += 1
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

    local serialized = serialize_instance(instance)
    local blobSha = write_blob(serialized)

    index[fullPath] = {
        mode = "100644",
        sha = blobSha
    }
    
    return collisionBase
end

local function stage_recursive(instance, index, seen_ids, perf, parentVirtualPath)
    if is_ignored(instance:GetFullName()) then return end
    seen_ids = seen_ids or {}
    perf = perf or { last_yield = os.clock() }

    local newVirtualPath = stage_instance(instance, index, seen_ids, parentVirtualPath)
    
    if os.clock() - perf.last_yield > 0.03 then
        task.wait()
        perf.last_yield = os.clock()
    end

    for _, child in ipairs(instance:GetChildren()) do
        if child ~= bash.getGitFolderRoot() and not child:IsDescendantOf(bash.getGitFolderRoot()) then
            stage_recursive(child, index, seen_ids, perf, newVirtualPath)
        end
    end
end

local function write_tree(index)
    local tree_structure = {}
    
    for path, data in pairs(index) do 
        local segments = string.split(path, "/")
        local current_level = tree_structure
        for i=1, #segments - 1 do 
            local segment = segments[i]
            if segment ~= "" then
                current_level[segment] = current_level[segment] or {}
                current_level = current_level[segment]
            end
        end
        local fileName = segments[#segments]
        if fileName ~= "" then
            current_level[fileName] = {
                type = "blob",
                sha = data.sha,
                mode = data.mode
            }
        end
    end

    local function build_tree_objects(structure)
        local tree_content = ""
        local entries = {}

        for name, item in pairs(structure) do
            table.insert(entries, {name=name, item=item})
        end

        table.sort(entries, function(a, b)
            local isTreeA = a.item.type ~= "blob"
            local isTreeB = b.item.type ~= "blob"
            local nameA = isTreeA and (a.name .. "/") or a.name
            local nameB = isTreeB and (b.name .. "/") or b.name
            return nameA < nameB
        end)

        for _, entry in ipairs(entries) do
            local name = entry.name
            local item = entry.item
            local sha

            if item.type == "blob" then
                sha=item.sha
                tree_content = tree_content .. item.mode .. " " .. name .. "\0" .. hashlib.hex_to_bin(sha)
            else
                sha = build_tree_objects(item)
                tree_content = tree_content .. "40000 " .. name .. "\0" .. hashlib.hex_to_bin(sha)
            end
        end

        return write_object("tree", tree_content)
    end
    
    return build_tree_objects(tree_structure)
end

local function collectObjects(localSha, remoteSha)
    local objects = {}
    local visited = {}

    local function markReachable(sha)
        if not sha or sha == ("0"):rep(40) or visited[sha] then return end
        visited[sha] = true
        local obj = read_object(sha)
        if not obj then return end
        if obj.type == "commit" then
            local treeSha = obj.content:match("^tree (%x+)")
            if treeSha then markReachable(treeSha) end
            for parent in obj.content:gmatch("\nparent (%x+)") do
                markReachable(parent)
            end
        elseif obj.type == "tree" then
            local content = obj.content
            local pos = 1
            while pos <= #content do
                local spacePos = content:find(" ", pos, true)
                local nullPos = content:find("\0", spacePos, true)
                local rawSha = content:sub(nullPos + 1, nullPos + 20)
                local entrySha = ("%02x"):rep(20):format(rawSha:byte(1, 20))
                pos = nullPos + 21
                markReachable(entrySha)
            end
        end
    end

    if remoteSha and remoteSha ~= ("0"):rep(40) then
        markReachable(remoteSha)
    end

    local function addObject(sha)
        if not sha or sha == ("0"):rep(40) or visited[sha] then return end
        visited[sha] = true
        local obj = read_object(sha)
        if not obj then return end
        objects[sha] = {type=obj.type, content=obj.content}
        if obj.type == "commit" then
            local treeSha = obj.content:match("^tree (%x+)")
            if treeSha then addObject(treeSha) end
            for parent in obj.content:gmatch("\nparent (%x+)") do
                addObject(parent)
            end
        elseif obj.type == "tree" then
            local content = obj.content
            local pos = 1
            while pos <= #content do
                local spacePos = content:find(" ", pos, true)
                local nullPos = content:find("\0", spacePos, true)
                assert(spacePos and nullPos, "fatal: malformed tree object " .. sha)
                local rawSha = content:sub(nullPos + 1, nullPos + 20)
                local entrySha = ("%02x"):rep(20):format(rawSha:byte(1, 20))
                pos = nullPos + 21
                addObject(entrySha)
            end
        end
    end

    addObject(localSha)
    return objects
end

local function buildPackfile(objects)
    local entries = {}
    local count = 0

    local typeMap = {commit = 1, tree = 2, blob = 3, tag = 4}

    for _, obj in pairs(objects) do
        local typeNum = typeMap[obj.type]

        if typeNum then
            local header = git_proto.encodeObjectHeader(typeNum, #obj.content)
            local compressed = zlib.compressZlib(obj.content)

            table.insert(entries, header .. compressed)
            count += 1
        end
    end

    local packData = "PACK"
    .. git_proto.writeU32BE(2)
    .. git_proto.writeU32BE(count)
    .. table.concat(entries)

    local checksum = hashlib.hex_to_bin(hashlib.sha1(packData))
    return packData .. checksum

end

local function get_ref(ref_path)
    local file = bash.getDirectoryOrFile(bash.getGitFolderRoot(), ref_path)
    if not file then return nil end

    local content = bash.getFileContents(file.Parent, file.Name)
    if content and string.sub(content, 1, 5) == "ref: " then
        return get_ref(string.sub(content, 6))
    else
        return content
    end
end

local function update_ref(ref_path, sha)
    local function do_update(full_path, sha_content)
        local segments = string.split(full_path, "/")
        local filename = table.remove(segments)
        
        local parent_folder = bash.getGitFolderRoot()
        if #segments > 0 then
            local dir_path = table.concat(segments, "/")
            parent_folder = bash.getDirectoryOrFile(parent_folder, dir_path)
        end

        if parent_folder and parent_folder:FindFirstChild(filename) then
            bash.modifyFileContents(parent_folder, filename, sha_content)
        else
            bash.createFile(parent_folder, filename, sha_content)
        end
    end

    local function get_file_content_by_path(path)
        local file = bash.getDirectoryOrFile(bash.getGitFolderRoot(), path)
        if file then
            return bash.getFileContents(file.Parent, file.Name)
        end
        return nil
    end

    local content = get_file_content_by_path(ref_path)

    if content and string.sub(content, 1, 5) == "ref: " then
        local symbolic_path = string.sub(content, 6)
        do_update(symbolic_path, sha)
    else
        do_update(ref_path, sha)
    end
end

local function get_content_lines(sha)
    if not sha then return 0 end

    local blob = read_object(sha)
    if not blob or blob.type ~= "blob" then return 0 end

    local success, props = pcall(function() return HttpService:JSONDecode(blob.content) end)
    if not success then return 1 end

    local className = ""
    for _, prop in ipairs(props) do
        if prop.name == "ClassName" then
            className = prop.value
            break
        end
    end
    
    if className == "Script" or className == "LocalScript" or className == "ModuleScript" then
        local source = ""
        for _, prop in ipairs(props) do
            if prop.name == "Source" then
                source = prop.value or ""
                break
            end
        end
        if source == "" then return 1 end
        local _, count = string.gsub(source, "\n", "")
        return count + 1
    else
        return 1
    end
end

local function return_urls(url: string, service: string?)
    local svc = service or "git-upload-pack"
    return {url .. "/info/refs?service=" .. svc, url .. "/" .. svc}
end

local function b64Encode(data)
    local b = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local res = {}
    for i = 1, #data, 3 do
        local n = 0
        local c1, c2, c3 = string.byte(data, i, i + 2)
        n = bit32.bor(bit32.lshift(c1 or 0, 16), bit32.lshift(c2 or 0, 8), c3 or 0)
        table.insert(res, string.sub(b, bit32.rshift(n, 18) + 1, bit32.rshift(n, 18) + 1))
        table.insert(res, string.sub(b, bit32.band(bit32.rshift(n, 12), 63) + 1, bit32.band(bit32.rshift(n, 12), 63) + 1))
        table.insert(res, c2 and string.sub(b, bit32.band(bit32.rshift(n, 6), 63) + 1, bit32.band(bit32.rshift(n, 6), 63) + 1) or "=")
        table.insert(res, c3 and string.sub(b, bit32.band(n, 63) + 1, bit32.band(n, 63) + 1) or "=")
    end
    return table.concat(res)
end

local function getConfigValue(key)
    local sensitive_keys = {
        ["user.name"] = true,
        ["user.email"] = true,
        ["user.token"] = true,
        ["user.password"] = true
    }

    local root = bash.getGitFolderRoot()
    local loaded_conf = {}
    if root then
        local config_content = bash.getFileContents(root, "config")
        if type(config_content) == "string" and config_content ~= "" then
            loaded_conf = ini_parser.parseIni(config_content)
        end
    end
    local conf = loaded_conf

    local userName = conf.user and conf.user.name
    local userEmail = conf.user and conf.user.email
    if not userName and ACTIVE_PLUGIN then
        pcall(function() userName = ACTIVE_PLUGIN:GetSetting("user.name") end)
    end
    if not userEmail and ACTIVE_PLUGIN then
        pcall(function() userEmail = ACTIVE_PLUGIN:GetSetting("user.email") end)
    end

    if key == "user.name" then return userName end
    if key == "user.email" then return userEmail end

    if sensitive_keys[key] and ACTIVE_PLUGIN then
        local val = ACTIVE_PLUGIN:GetSetting(key)
        if val then return val end
    end

    local key_parts = string.split(key, ".")
    if loaded_conf[key_parts[1]] then
        local val = loaded_conf[key_parts[1]][key_parts[2]]
        if type(val) == "string" then
            val = val:gsub('^"(.*)"$', '%1'):gsub("^'(.*)'$", "%1")
        end
        return val
    end
    return nil
end

local function get_current_branch()
    local root = bash.getGitFolderRoot()
    if not root then return nil end
    local head = bash.getFileContents(root, "HEAD")
    if not head then return nil end
    return head:match("ref: refs/heads/(.+)")
end

local memory_credentials = {}

local function getAuthHeader(url)
    if memory_credentials[url] then
        return "Basic " .. b64Encode("x:" .. memory_credentials[url])
    end
    local token = getConfigValue("user.token") or getConfigValue("user.password")
    if token then
        return "Basic " .. b64Encode("x:" .. token)
    end
    return nil
end

local function url_request_with_retry(req_options)
    local ok, res = pcall(function() return HttpService:RequestAsync(req_options) end)
    if not ok then return false, res end

    if res.StatusCode == 401 or res.StatusCode == 404 then
        local username = ask_for_credential("Username for '" .. (req_options.Url:match("^(https?://[^/]+)") or req_options.Url) .. "':", false)
        if not username or username == "" then
            return true, res
        end
        
        local password = ask_for_credential("Password for '" .. (req_options.Url:match("^(https?://[^/]+)") or req_options.Url) .. "':", true)
        
        if password and password ~= "" then
            local base_url = req_options.Url:match("^(https?://[^/]+)") or req_options.Url
            memory_credentials[base_url] = password
            
            req_options.Headers = req_options.Headers or {}
            req_options.Headers["Authorization"] = "Basic " .. b64Encode(username .. ":" .. password)
            
            ok, res = pcall(function() return HttpService:RequestAsync(req_options) end)
            if not ok then return false, res end
        end
    end
    return true, res
end

local function discoverRefs(url: string, service: string?)
	local req = {
        Url = return_urls(url, "git-upload-pack")[1],
        Method = "GET",
        Headers = {
            ["Authorization"] = getAuthHeader(url:match("^(https?://[^/]+)") or url)
        }
    }
    
    local ok, res = url_request_with_retry(req)

    if not ok or res.StatusCode ~= 200 then
        -- Cleanup if auth failed or repo not found
        -- bash.trackingRoot = previous_trackingRoot -- This line is likely from a higher-level clone function and not relevant here.
        -- dir:Destroy() -- This line is likely from a higher-level clone function and not relevant here.
        error("fatal: repository '" .. url .. "' not found or access denied")
    end
    
	assert(res.StatusCode == 200, "Discovery failed: " .. res.StatusCode .. " (Check repository URL and credentials)")

	local buf = buffer.fromstring(res.Body)
	local cursor = 0
	local refs = {}

	while cursor < buffer.len(buf) do
		local data, next = git_proto.decodePkt(buf, cursor)
		cursor = next
		if data then
			local sha, name = git_proto.parseRef(data)
			if sha and name then
				refs[name] = sha
			end
		end
	end

	return refs
end

local function fetchPackfile(url: string, sha: string)
	local wantPkt = git_proto.encodePkt(buffer.fromstring("want " .. sha .. " side-band-64k ofs-delta\n"))
	local donePkt = git_proto.encodePkt(buffer.fromstring("done\n"))
	local body = buffer.tostring(wantPkt) .. buffer.tostring(git_proto.flush()) .. buffer.tostring(donePkt)

	local req = {
		Url = return_urls(url)[2],
		Method = "POST",
		Headers = {
			["Content-Type"] = "application/x-git-upload-pack-request",
			["Accept"] = "application/x-git-upload-pack-result",
            ["Authorization"] = getAuthHeader(url:match("^(https?://[^/]+)") or url)
		},
		Body = body,
	}
    
    local ok, res = url_request_with_retry(req)
    assert(ok, "Upload-pack request error")
	assert(res.StatusCode == 200, "Upload-pack failed: " .. res.StatusCode)

	local resBuf = buffer.fromstring(res.Body)
	local cursor = 0
	local pieces = {}
	local totalSize = 0

	while cursor < buffer.len(resBuf) do
		local data, next = git_proto.decodePkt(resBuf, cursor)
		cursor = next
		if data then
			local channel = buffer.readu8(data, 0)
			if channel == 1 then
				local size = buffer.len(data) - 1
				local piece = buffer.create(size)
				buffer.copy(piece, 0, data, 1, size)
				table.insert(pieces, piece)
				totalSize += size
			elseif channel == 2 then
				local msg = buffer.tostring(data):sub(2)
				for line in msg:gmatch("[^\r\n]+") do
					local trimmed = line:match("^%s*(.-)%s*$")
					if trimmed and (trimmed:find("done") or trimmed:find("Total")) then
						print("remote: " .. trimmed)
					end
				end
			elseif channel == 3 then
				error("remote error: " .. buffer.tostring(data))
			end
		end
	end

	local fullPack = buffer.create(totalSize)
	local write = 0
	for _, piece in pieces do
		buffer.copy(fullPack, write, piece, 0, buffer.len(piece))
		write += buffer.len(piece)
	end

	return fullPack
end

local function unpackObjects(fullPack)
	local version, objCount, cursor = git_proto.parsePackHeader(fullPack, 0)
	print(string.format("Packfile v%d — %d objects", version, objCount))
	local parsedCount = 0
	local objectsByOffset = {}
	local typesByOffset = {}
	local objectsBySha = {}
	local last_yield = os.clock()

	for i = 1, objCount do
		if os.clock() - last_yield > 0.03 then
			task.wait()
			last_yield = os.clock()
		end
		local objOffset = cursor
		local objType, _size, next = git_proto.parseObjectHeader(fullPack, cursor)
		cursor = next

		local baseOffset
		local refShaHex

		if objType == 6 then
			local b = buffer.readu8(fullPack, cursor)
			cursor += 1
			baseOffset = bit32.band(b, 0x7F)
			while bit32.band(b, 0x80) ~= 0 do
				b = buffer.readu8(fullPack, cursor)
				cursor += 1
				baseOffset = bit32.bor(bit32.lshift(baseOffset + 1, 7), bit32.band(b, 0x7F))
			end
		elseif objType == 7 then
			local shaBytes = buffer.create(20)
			buffer.copy(shaBytes, 0, fullPack, cursor, 20)
			refShaHex = ""
			for j = 0, 19 do
				refShaHex = refShaHex .. ("%02x"):format(buffer.readu8(shaBytes, j))
			end
			cursor += 20
		end

		local remaining = buffer.len(fullPack) - cursor
		local slice = buffer.create(remaining)
		buffer.copy(slice, 0, fullPack, cursor, remaining)

		local decompressed, bytesLeft = zlib.decompressZlib(buffer.tostring(slice))

		local resolved
		local actualType
		if objType == 6 then
			local base = objectsByOffset[objOffset - baseOffset]
			assert(base, "Missing base object at offset " .. (objOffset - baseOffset))
			resolved = git_proto.applyDelta(base, decompressed)
			actualType = typesByOffset[objOffset - baseOffset]
		elseif objType == 7 then
			local baseWrapper = objectsBySha[refShaHex]
			-- sometimes forward references occur in packfiles (thin packs), wait or assert.
			assert(baseWrapper, "Missing base object for REF_DELTA: " .. refShaHex)
			resolved = git_proto.applyDelta(baseWrapper.content, decompressed)
			actualType = baseWrapper.objType
		else
			resolved = decompressed
			actualType = objType
		end

		objectsByOffset[objOffset] = resolved
		typesByOffset[objOffset] = actualType
		parsedCount += 1

		cursor = buffer.len(fullPack) - bytesLeft

		local typePrefix = ({[1]="commit",[2]="tree",[3]="blob",[4]="tag"})[actualType]
		if typePrefix and resolved then
			local header = typePrefix .. " " .. #resolved .. "\0"
			local sha = hashlib.sha1(header .. resolved)
			objectsBySha[sha] = {objType = actualType, content = resolved}
		end

	end

	return objectsByOffset, objectsBySha
end

local function peekPropertiesBlob(objectsBySha, treeSha)
    local treeObj = objectsBySha[treeSha]
    if not treeObj then return nil end

    local content = treeObj.content
    local pos = 1
    while pos <= #content do
        local spacePos = content:find(" ", pos, true)
        local nullPos = content:find("\0", spacePos, true)
        local entryName = content:sub(spacePos + 1, nullPos - 1)
        local rawSha = content:sub(nullPos + 1, nullPos + 20)
        local entrySha = ("%02x"):rep(20):format(rawSha:byte(1, 20))
        pos = nullPos + 21

        if entryName == ".properties" then
            local blobObj = objectsBySha[entrySha]
            if blobObj then
                local ok, props = pcall(function() return HttpService:JSONDecode(blobObj.content) end)
                if ok then return props end
            end
            return nil
        end
    end
    return nil
end

local function applyProperties(instance, props)
    for _, propData in ipairs(props) do
        if propData.name == "_attributes" and propData.valueType == "_attributes" then
            for attrName, attrData in pairs(propData.value) do
                local val = deserialize_property(attrData.value, attrData.valueType)
                if val ~= nil then
                    pcall(function() instance:SetAttribute(attrName, val) end)
                end
            end
        elseif propData.name == "_tags" and propData.valueType == "_tags" then
            for _, tag in ipairs(propData.value) do
                pcall(function() instance:AddTag(tag) end)
            end
        elseif propData.name ~= "ClassName" and propData.name ~= "Parent" then
            local val = deserialize_property(propData.value, propData.valueType)
            if val ~= nil then
                if propData.name == "MeshId" and instance:IsA("MeshPart") then
                    pcall(function()
                        local InsertService = game:GetService("InsertService")
                        local loadedMesh = InsertService:CreateMeshPartAsync(val, instance.CollisionFidelity, instance.RenderFidelity)
                        instance:ApplyMesh(loadedMesh)
                    end)
                else
                    pcall(function()
                        instance[propData.name] = val
                    end)
                end
            end
        end
    end
end

local function findByRogitId(parent, rogitId)
    for _, child in ipairs(parent:GetChildren()) do
        if child:GetAttribute(ROGIT_ID) == rogitId then
            return child
        end
    end
    return nil
end

local function extractRogitId(props)
    for _, propData in ipairs(props) do
        if propData.name == "_attributes" and propData.valueType == "_attributes" then
            local entry = propData.value[ROGIT_ID]
            if entry then
                return entry.value
            end
        end
    end
    return nil
end

local function writeTree(objectsBySha, treeSha, parent, treePath)
    local treeObj = objectsBySha[treeSha]
    assert(treeObj, "Missing tree: " .. treeSha)

    local content = treeObj.content
    local pos = 1

    while pos <= #content do
        local spacePos = content:find(" ", pos, true)
        local mode = content:sub(pos, spacePos - 1)

        local nullPos = content:find("\0", spacePos, true)
        local name = content:sub(spacePos + 1, nullPos - 1)

        local rawSha = content:sub(nullPos + 1, nullPos + 20)
        local sha = ("%02x"):rep(20):format(rawSha:byte(1, 20))
        pos = nullPos + 21

        local entryPath = treePath and (treePath .. "/" .. name) or name

        if mode == "40000" then
            local childProps = peekPropertiesBlob(objectsBySha, sha)
            local className = nil
            local uuid = nil
            if childProps then
                for _, propData in ipairs(childProps) do
                    if propData.name == "ClassName" then
                        className = propData.value
                    end
                end
                uuid = extractRogitId(childProps)
            end

            local target = uuid and findByRogitId(parent, uuid) or parent:FindFirstChild(name)
            if not target then
                if className then
                    local ok, inst = pcall(Instance.new, className)
                    if ok then
                        target = inst
                        target.Name = name
                        target.Parent = parent
                    else
                        target = bash.createFolder(parent, name)
                    end
                else
                    target = bash.createFolder(parent, name)
                end
            end

            if uuid then
                target:SetAttribute(ROGIT_ID, uuid)
            end

            if childProps then
                applyProperties(target, childProps)
            end

            writeTree(objectsBySha, sha, target, entryPath)
        else
            local blobObj = objectsBySha[sha]
            if not blobObj then
                continue
            elseif name == ".properties" then
                local ok, props = pcall(function() return HttpService:JSONDecode(blobObj.content) end)
                if ok then
                    applyProperties(parent, props)
                end
            else
                local ok, props = pcall(function() return HttpService:JSONDecode(blobObj.content) end)
                if not ok then
                    continue
                end

                local className = "Part"
                for _, propData in ipairs(props) do
                    if propData.name == "ClassName" then
                        className = propData.value
                        break
                    end
                end

                local uuid = extractRogitId(props)
                local newInstance = uuid and findByRogitId(parent, uuid) or nil

                if not newInstance then
                    local ok2, inst = pcall(Instance.new, className)
                    if not ok2 then
                        continue
                    end
                    newInstance = inst
                    newInstance.Name = name
                    newInstance.Parent = parent
                end

                applyProperties(newInstance, props)
            end
        end
    end
end


function git.replaceOutputCallback(callback, warncallback, errcallback)
    print = callback
    warn = warncallback
    error = errcallback
end

local function is_valid_branch_name(name)
    if not name or name == "" then return false end
    if name:match("^-") then return false end
    if name:match("[%s~^:?*[\\]]") then return false end
    if name:match("%.%.") then return false end
    return true
end

--[[
Commands:
version
v

Outputs the version to the console.
]]
arguments.createArgument("git", "version", "v", function ()
    print(config.version)
end)

--[[
Commands:
help
h

Outputs all possible commands.
TODO: Implement descriptions
]]
arguments.createArgument("git", "help", "h", function (...)
    local args = {...}
    if #args > 0 then
        local cmd = args[1]
        local help_messages = {
            add = "git-add - Add file contents to the index.\n\nUsage: git add [options] [--] <pathspec>...\n\n    -n, --dry-run     dry run\n    -f, --force       allow adding otherwise ignored files",
            commit = "git-commit - Record changes to the repository.\n\nUsage: git commit [-m <msg>]\n\n    -m, --message <msg>   commit message",
            push = "git-push - Update remote refs along with associated objects.\n\nUsage: git push [<options>] [<repository> [<refspec>...]]\n\n    -u, --set-upstream    set upstream for git pull/status",
            pull = "git-pull - Fetch from and integrate with another repository or a local branch.\n\nUsage: git pull [<options>] [<repository> [<refspec>...]]",
            status = "git-status - Show the working tree status.\n\nUsage: git status",
            branch = "git-branch - List, create, or delete branches.\n\nUsage: git branch [<branchname>]\n       git branch -d <branchname>\n       git branch -m <oldbranch> <newbranch>",
            switch = "git-switch - Switch branches.\n\nUsage: git switch [<options>] <branch>\n\n    -c, --create <branch>  create and switch to a new branch",
            clone = "git-clone - Clone a repository into a new directory.\n\nUsage: git clone <repository>",
            fetch = "git-fetch - Download objects and refs from another repository.\n\nUsage: git fetch [<options>] [<repository>]",
            reset = "git-reset - Reset current HEAD to the specified state.\n\nUsage: git reset [--soft | --mixed | --hard] [<commit>]\n\n    --hard       reset HEAD, index and working tree",
            rm = "git-rm - Remove files from the working tree and from the index.\n\nUsage: git rm [-r] <file>...",
            diff = "git-diff - Show changes between commits, commit and working tree, etc.\n\nUsage: git diff",
            merge = "git-merge - Join two or more development histories together.\n\nUsage: git merge <commit-or-branch>",
            rebase = "git-rebase - Reapply commits on top of another base tip.\n\nUsage: git rebase\n\nfatal: 'rebase' requires interactive graph rewrites which are complex in Luau. Please use 'git merge' instead.",
            mv = "git-mv - Move or rename a file, a directory, or a symlink.\n\nUsage: git mv <source> <destination>",
            restore = "git-restore - Restore working tree files.\n\nUsage: git restore <pathspec>",
            remote = "git-remote - Manage set of tracked repositories.\n\nUsage: git remote [-v | --verbose]\n       git remote add [-f] <name> <url>\n       git remote remove <name>\n       git remote set-url <name> <newurl>",
            init = "git-init - Create an empty Git repository or reinitialize an existing one.\n\nUsage: git init [-q | --quiet] [-b <branch-name>]",
            log = "git-log - Show commit logs.\n\nUsage: git log [<options>]",
            config = "git-config - Get and set repository or global options.\n\nUsage: git config [--global] <name> [<value>]",
            version = "git-version - Show the RoGit version information.\n\nUsage: git version"
        }

        if cmd == "-a" or cmd == "--all" then
            local cmds = {}
            for k, _ in pairs(arguments.returnAllArguments()) do
                table.insert(cmds, k)
            end
            table.sort(cmds)
            print("available subcommands:\n  " .. table.concat(cmds, "\n  "))
            return
        elseif cmd == "-g" or cmd == "--guides" then
            print("RoGit concept guides are not yet implemented.")
            return
        elseif cmd == "git" then
            -- Fall through to main help message!
        elseif help_messages[cmd] then
            print(help_messages[cmd])
            return
        else
            print("No manual entry for git-" .. cmd)
            return
        end
    end

    print([=[usage: git [--version] [--help] [-C <path>] [-c <name>=<value>]
           [--exec-path[=<path>]] [--html-path] [--man-path] [--info-path]
           [-p | --paginate | -P | --no-pager] [--no-replace-objects] [--bare]
           [--git-dir=<path>] [--work-tree=<path>] [--namespace=<name>]
           <command> [<args>]

These are common Git commands used in various situations:

start a working area (see also: git help tutorial)
   clone     Clone a repository into a new directory
work on the current change (see also: git help everyday)
   add       Add file contents to the index
   mv        Move or rename a file, a directory, or a symlink
   restore   Restore working tree files
   rm        Remove files from the working tree and from the index

examine the history and state (see also: git help revisions)
   diff      Show changes between commits, commit and working tree, etc
   log       Show commit logs
   status    Show the working tree status

grow, mark and tweak your common history
   branch    List, create, or delete branches
   commit    Record changes to the repository
   merge     Join two or more development histories together
   rebase    Reapply commits on top of another base tip (NOT IMPLEMENTED YET)
   reset     Reset current HEAD to the specified state

collaborate (see also: git help workflows)
   fetch     Download objects and refs from another repository
   pull      Fetch from and integrate with another repository or a local branch
   push      Update remote refs along with associated objects
   remote    Manage set of tracked repositories

Other commands:
   init      Create an empty Git repository or reinitialize an existing one
   config    Get and set repository or global options

'git help -a' and 'git help -g' list available subcommands and some
concept guides. See 'git help <command>' or 'git help <concept>'
to read about a specific subcommand or concept.
See 'git help git' for an overview of the system.]=])
end)

arguments.createArgument("git", "diff", "", function()
    assert(bash.getGitFolderRoot(), "fatal: not a git repository")
    local index = read_index()
    
    local has_diff = false
    for path, data in pairs(index) do
        local target_path = path:match("^(.-)/%.properties$") or path
        local segments = string.split(target_path, "/")
        local currObj = game
        for _, segment in ipairs(segments) do
            if currObj and currObj:FindFirstChild(segment) then
                currObj = currObj:FindFirstChild(segment)
            else
                currObj = nil
                break
            end
        end

        if not currObj then
            print("\27[31mD\27[0m  " .. path)
            has_diff = true
        else
            local serialized = serialize_instance(currObj)
            local current_sha = hashlib.sha1(serialized)
            if current_sha ~= data.sha then
                print("\27[33mM\27[0m  " .. path)
                print("--- a/" .. path)
                print("+++ b/" .. path)
                print("@@ -1 +1 @@")
                print("- " .. data.sha:sub(1,7) .. " (Index state)")
                print("+ " .. current_sha:sub(1,7) .. " (Workspace state)")
                has_diff = true
            end
        end
    end
    if not has_diff then
        print("Everything up-to-date with index.")
    end
end)

arguments.createArgument("git", "rebase", "", function()
    print("fatal: 'rebase' requires interactive graph rewrites which are complex in Luau. Please use 'git merge' instead.")
end)

arguments.createArgument("git", "merge", "", function(...)
    local tuple = {...}
    local branch = tuple[1]

    if not branch then
        print("fatal: No commit specified and merge.defaultToUpstream not set.")
        return
    end

    local root = bash.getGitFolderRoot()
    if not root then
        print("fatal: not a git repository (or any of the parent directories): .git")
        return
    end
    
    local target_sha = get_ref("refs/heads/" .. branch) or get_ref("refs/remotes/origin/" .. branch)
    if not target_sha or target_sha == "" then
        print("merge: " .. branch .. " - not something we can merge")
        return
    end
    
    print("Updating " .. get_ref("HEAD"):sub(1,7) .. ".." .. target_sha:sub(1,7))
    print("Fast-forward")
    arguments.execute("git", "reset", "--hard", target_sha)
end)

arguments.createArgument("git", "mv", "", function(...)
    local tuple = {...}
    local source = tuple[1]
    local destination = tuple[2]

    if not source or not destination then
        print("fatal: bad source, source=")
        return
    end

    assert(bash.getGitFolderRoot(), "fatal: not a git repository")
    
    local source_path_cleaned = source:gsub("^game[./]", ""):gsub("%.", "/")
    local dest_path_cleaned = destination:gsub("^game[./]", ""):gsub("%.", "/")
    
    local sourceObj = parse_path(source_path_cleaned)
    assert(sourceObj, "fatal: bad source, source=" .. source_path_cleaned)
    
    local destObj, destName, destSegments = parse_path(dest_path_cleaned)
    if destObj then
        sourceObj.Parent = destObj
    else
        local parentPath = table.concat(destSegments, "/", 1, #destSegments - 1)
        local parentObj = parse_path(parentPath)
        assert(parentObj, "fatal: destination parent does not exist")
        sourceObj.Parent = parentObj
        sourceObj.Name = destName
    end
    
    print("Moved '" .. source_path_cleaned .. "' to '" .. dest_path_cleaned .. "'")
    arguments.execute("git", "add", ".")
end)

arguments.createArgument("git", "restore", "", function(...)
    local tuple = {...}
    if #tuple == 0 then
        print("fatal: you must specify path(s) to restore")
        return
    end

    assert(bash.getGitFolderRoot(), "fatal: not a git repository")
    local index = read_index()
    local path = tuple[1] -- Use tuple[1] as the path argument
    
    local is_all = (path == ".")
    local target_path_base = ""
    if not is_all then
        local _, _, segments = parse_path(path)
        target_path_base = table.concat(segments or {}, "/")
    end
    
    local found = false
    for idx_path, data in pairs(index) do
        local entry_path = idx_path:match("^(.-)/%.properties$") or idx_path
        if is_all or entry_path == target_path_base or entry_path:sub(1, #target_path_base + 1) == target_path_base .. "/" then
            found = true
            
            local targetObj = parse_path(entry_path)
            if targetObj then
                local obj = read_object(data.sha)
                if obj and obj.type == "blob" then
                    local ok, props = pcall(function() return HttpService:JSONDecode(obj.content) end)
                    if ok then
                        applyProperties(targetObj, props)
                    end
                end
            end
        end
    end
    
    if found then
        print("Restored " .. path)
    else
        print("error: pathspec '" .. path .. "' did not match any files")
    end
end)
--[[
Commands:
add
a

Adds files to be commited
]]

arguments.createArgument("git", "add", "a", function (...)
    assert(bash.getGitFolderRoot(),
        "fatal: not a git repository (or any of the parent directories): .git")

    local args = {...}
    local force = false
    local dry_run = false
    local paths = {}

    for _, arg in ipairs(args) do
        if arg == "-f" or arg == "--force" then
            force = true
        elseif arg == "-n" or arg == "--dry-run" then
            dry_run = true
        elseif arg == "-A" or arg == "--all" then
            table.insert(paths, ".")
        else
            table.insert(paths, arg)
        end
    end

    if #paths == 0 then
        print("Nothing specified, nothing added.")
        print("hint: Maybe you wanted to say 'git add .'?")
        return
    end

    local has_dot = false
    for _, p in ipairs(paths) do
        if p == "." then
            has_dot = true
            break
        end
    end

    if has_dot then
        local index = read_index()
        local seen_ids = {}
        for _, service in ipairs(bash.trackingRoot) do
            if force or not is_ignored(service:GetFullName()) then
                if dry_run then
                    print("add '" .. service:GetFullName() .. "'")
                    for _, desc in ipairs(service:GetDescendants()) do
                        if desc ~= bash.getGitFolderRoot() and not desc:IsDescendantOf(bash.getGitFolderRoot()) then
                            print("add '" .. desc:GetFullName() .. "'")
                        end
                    end
                else
                    stage_recursive(service, index, seen_ids)
                end
            end
        end
        if not dry_run then
            write_index(index)
        end
        return
    end

    local index = read_index()
    local seen_ids = {}

    for _, target in ipairs(paths) do
        local currObj = parse_path(target)

        if not currObj then
            print("fatal: pathspec '" .. target .. "' did not match any files")
            return
        end

        if dry_run then
            print("add '" .. currObj:GetFullName() .. "'")
        else
            stage_recursive(currObj, index, seen_ids)
        end
    end

    if not dry_run then
        write_index(index)
    end
end)


local function fetch(remote_name)
    print("Fetching " .. remote_name)

    local config_content = bash.getFileContents(bash.getGitFolderRoot(), "config")
    local loaded_conf = ini_parser.parseIni(config_content)

    local section_name = 'remote "' .. remote_name .. '"'
    local remote_section = loaded_conf[section_name]
    assert(remote_section and remote_section.url, "fatal: '" .. remote_name .. "' does not appear to be a git repository")
    
    local url = remote_section.url

    local refs = discoverRefs(url)
    
    local output = { "From " .. url }
    for name, sha in pairs(refs) do
        if name ~= "HEAD" then
            local branch_name = name:match("refs/heads/(.+)")
            if branch_name then
                table.insert(output, string.format(" * [new branch]      %-15s -> %s/%s", branch_name, remote_name, branch_name))
                update_ref("refs/remotes/" .. remote_name .. "/" .. branch_name, sha)
            end
        end
    end
    print(table.concat(output, "\n"))

    for name, sha in pairs(refs) do
        if name ~= "HEAD" then
            local pack = fetchPackfile(url, sha)
            local _, objectsBySha = unpackObjects(pack)
            for objSha, obj in pairs(objectsBySha) do
                local typeName = ({[1]="commit", [2]="tree", [3]="blob", [4]="tag"})[obj.objType]
                if typeName then
                    write_object(typeName, obj.content)
                end
            end
        end
    end
end

--[[
commands:
pull

pulls latest commit.
]]

arguments.createArgument("git", "pull", "", function (...)
    assert(bash.getGitFolderRoot(), "fatal: not a git repository (or any of the parent directories): .git")

    local tuple = {...}
    local remote_name = tuple[1] or "origin"
    local branch_name = tuple[2] or get_current_branch() or "master"

    local config_content = bash.getFileContents(bash.getGitFolderRoot(), "config")
    local loaded_conf = ini_parser.parseIni(config_content)
    local section_name = 'remote "' .. remote_name .. '"'
    local remote_section = loaded_conf[section_name]
    assert(remote_section and remote_section.url, "fatal: '" .. remote_name .. "' does not appear to be a git repository")
    local url = remote_section.url

    local refs = discoverRefs(url)
    local remoteSha = refs["refs/heads/" .. branch_name] or refs["HEAD"]
    assert(remoteSha, "fatal: couldn't find remote ref 'refs/heads/" .. branch_name .. "'")

    local localSha = get_ref("HEAD")
    if localSha == remoteSha then
        print("Already up to date.")
        return
    end

    local fullPack = fetchPackfile(url, remoteSha)
    local _, objectsBySha = unpackObjects(fullPack)

    for objSha, obj in pairs(objectsBySha) do
        local typeName = ({[1]="commit", [2]="tree", [3]="blob", [4]="tag"})[obj.objType]
        if typeName then
            write_object(typeName, obj.content)
        end
    end

    local headCommit = objectsBySha[remoteSha]
    assert(headCommit, "HEAD commit not found in packfile")
    local treeSha = headCommit.content:match("^tree (%x+)")
    assert(treeSha, "Could not parse tree SHA from commit")

    local treeObj = objectsBySha[treeSha]
    assert(treeObj, "Missing root tree: " .. treeSha)

    local content = treeObj.content
    local pos = 1
    while pos <= #content do
        local spacePos = content:find(" ", pos, true)
        local mode = content:sub(pos, spacePos - 1)
        local nullPos = content:find("\0", spacePos, true)
        local name = content:sub(spacePos + 1, nullPos - 1)
        local rawSha = content:sub(nullPos + 1, nullPos + 20)
        local sha = ("%02x"):rep(20):format(rawSha:byte(1, 20))
        pos = nullPos + 21

        if mode == "40000" then
            local serviceParent = game:FindFirstChild(name)
            if not serviceParent then
                pcall(function()
                    serviceParent = game:GetService(name)
                end)
            end
            if serviceParent then
                local childProps = peekPropertiesBlob(objectsBySha, sha)
                if childProps then
                    applyProperties(serviceParent, childProps)
                end
                writeTree(objectsBySha, sha, serviceParent, name)
            end
        end
    end

    update_ref("HEAD", remoteSha)
    update_ref("refs/remotes/" .. remote_name .. "/" .. branch_name, remoteSha)

    print("Updating " .. (localSha or "0000000"):sub(1, 7) .. ".." .. remoteSha:sub(1, 7))
end)

arguments.createArgument("git", "rm", "", function (...)
    local tuple = {...}
    local is_cached = false
    local recursive = false
    local _force = false
    local paths = {}

    for _, arg in ipairs(tuple) do
        if arg == "--cached" then
            is_cached = true
        elseif arg == "-r" then
            recursive = true
        elseif arg == "-f" or arg == "--force" then
            _force = true
        else
            table.insert(paths, arg)
        end
    end

    if #paths == 0 then
        print("fatal: No pathspec was given. Which files should I remove?")
        return
    end

    local index = read_index()
    local removed = {}

    for _, path_to_remove in ipairs(paths) do
        if path_to_remove:sub(1, 5) == "game." or path_to_remove:sub(1, 5) == "game/" then
            path_to_remove = path_to_remove:sub(6)
        end
        path_to_remove = path_to_remove:gsub("%.", "/")

        if recursive then
            for path, _ in pairs(index) do
                if path == path_to_remove or path:sub(1, #path_to_remove + 1) == path_to_remove .. "/" then
                    index[path] = nil
                    table.insert(removed, path)
                end
            end
        else
            if index[path_to_remove] then
                index[path_to_remove] = nil
                table.insert(removed, path_to_remove)
            else
                warn("fatal: pathspec '" .. path_to_remove .. "' did not match any files")
            end
        end
    end

    write_index(index)

    if not is_cached then
        for _, path in ipairs(removed) do
            local currObj = parse_path(path)
            if currObj and currObj ~= game then
                currObj:Destroy()
            end
        end
    end

    for _, path in ipairs(removed) do
        print("rm '" .. path .. "'")
    end
end)

arguments.createArgument("git", "commit", "", function(...)
    local tuple = { ... }
    local message = ""
    local allow_empty = false
    local amend = false

    local i = 1
    while i <= #tuple do
        if tuple[i] == "-m" and tuple[i + 1] then
            message = tuple[i + 1]
            i += 1
        elseif tuple[i] == "--allow-empty" then
            allow_empty = true
        elseif tuple[i] == "--amend" then
            amend = true
        end
        i += 1
    end

    if message == "" and not amend then
        message = "default commit message"
    end

    local index = read_index()

    local last_index = {}
    local last_index_str = bash.getFileContents(bash.getGitFolderRoot(), "last_commit_index")
    if last_index_str and last_index_str ~= "" then
        last_index = HttpService:JSONDecode(last_index_str)
    end

    local old_paths = {}
    local new_paths = {}
    local old_sha_to_path = {}
    local new_sha_to_path = {}

    for path, data in pairs(last_index) do
        old_paths[path] = data.sha
        old_sha_to_path[data.sha] = path
    end
    for path, data in pairs(index) do
        new_paths[path] = data.sha
        new_sha_to_path[data.sha] = path
    end

    local files_added = {}
    local files_deleted = {}
    local files_modified = {}
    local files_renamed = {}

    local total_insertions = 0
    local total_deletions = 0

    for path, old_sha in pairs(old_paths) do
        local new_sha = new_paths[path]

        if not new_sha then
            if new_sha_to_path[old_sha] then
                local new_path_for_sha = new_sha_to_path[old_sha]
                if new_path_for_sha ~= path then
                    new_paths[new_path_for_sha] = "RENAMED_PLACEHOLDER"
                    table.insert(files_renamed, {old_path = path, new_path = new_path_for_sha, similarity = 100})
                end
            else
                table.insert(files_deleted, {path = path, mode = last_index[path].mode})
                total_deletions = total_deletions + get_content_lines(old_sha)
            end
        elseif old_sha ~= new_sha then
            table.insert(files_modified, {path = path, old_sha = old_sha, new_sha = new_sha})
            total_deletions = total_deletions + get_content_lines(old_sha)
            total_insertions = total_insertions + get_content_lines(new_sha)
        end
    end

    for path, new_sha in pairs(new_paths) do
        if not old_paths[path] and new_sha ~= "RENAMED_PLACEHOLDER" then
            table.insert(files_added, {path = path, mode = index[path].mode})
            total_insertions = total_insertions + get_content_lines(new_sha)
        end
    end

    local num_files_changed = #files_added + #files_deleted + #files_modified + #files_renamed

    if not allow_empty and num_files_changed == 0 and not amend then
        print("nothing to commit, working tree clean")
        return
    end

    if message == "default commit message" then
        warn("hint: It's recommended to provide a descriptive commit message with -m")
    end

    local parent_sha = get_ref("HEAD")
    local tree_sha = write_tree(index)
    local commit_content = "tree " .. tree_sha .. "\n"

    if amend then
        if parent_sha and parent_sha ~= "" then
            local old_commit = read_object(parent_sha)
            if old_commit then
                for old_parent in old_commit.content:gmatch("\nparent (%x+)") do
                    commit_content = commit_content .. "parent " .. old_parent .. "\n"
                end
                if message == "" then
                    message = old_commit.content:match("\n\n(.+)$") or "default commit message"
                end
            end
        end
    else
        if parent_sha and parent_sha ~= "" then
            commit_content = commit_content .. "parent " .. parent_sha .. "\n"
        end
    end

    local timestamp = os.time()
    local user_name = getConfigValue("user.name") or "roGit"
    local user_email = getConfigValue("user.email") or "ro-git@example.com"
    commit_content = commit_content .. string.format("author %s <%s> %d +0000\n", user_name, user_email, timestamp)
    commit_content = commit_content .. string.format("committer %s <%s> %d +0000\n", user_name, user_email, timestamp)
    commit_content = commit_content .. "\n" .. message
    local commit_sha = write_object("commit", commit_content)
    update_ref("HEAD", commit_sha)

    if bash.getGitFolderRoot():FindFirstChild("last_commit_index") then
        bash.modifyFileContents(bash.getGitFolderRoot(), "last_commit_index", HttpService:JSONEncode(index))
    else
        bash.createFile(bash.getGitFolderRoot(), "last_commit_index", HttpService:JSONEncode(index))
    end

    local output_details = {}
    for _, entry in ipairs(files_renamed) do
        table.insert(output_details, string.format(" rename %s => %s (%d%%)", entry.old_path, entry.new_path, entry.similarity))
    end
    for _, entry in ipairs(files_added) do
        table.insert(output_details, string.format(" create mode %s %s", entry.mode, entry.path))
    end
    for _, entry in ipairs(files_deleted) do
        table.insert(output_details, string.format(" delete mode %s %s", entry.mode, entry.path))
    end

    local stats_line = ""
    if num_files_changed > 0 then
        stats_line = string.format(" %d files changed, %d insertions(+), %d deletions(-)", num_files_changed, total_insertions, total_deletions)
    end

    local short_sha = string.sub(commit_sha, 1, 7)
    local final_output = string.format("[master %s] %s", short_sha, message)
    if num_files_changed > 0 then
        final_output = final_output .. "\n" .. stats_line
    end
    if #output_details > 0 then
        final_output = final_output .. "\n" .. table.concat(output_details, "\n")
    end
    print(final_output)
end)

--[[
commands:
init
]]

arguments.createArgument("git", "init", "", function (...)
    ignore_patterns = nil

    local tuple = {...}
    local quiet = false
    local initial_branch = "master"

    local i = 1
    while i <= #tuple do
        if tuple[i] == "-q" or tuple[i] == "--quiet" then
            quiet = true
        elseif tuple[i] == "-b" and tuple[i + 1] then
            initial_branch = tuple[i + 1]
            i += 1
        end
        i += 1
    end

    local root = bash.getGitFolderRoot()
    if not root then 
        root = bash.createGitFolderRoot()
        if not quiet then
            print("Initialized empty Git repository")
        end
    else 
        if not quiet then
            print("Reinitialized existing Git repository in " .. game.Name)
        end
        local _reinit_required = true
    end

    bash.createFolder(root, "hooks")
    local info = bash.createFolder(root, "info")

    bash.createFolder(root, "objects/info")
    bash.createFolder(root, "objects/pack")

    bash.createFolder(root, "refs/heads")
    bash.createFolder(root, "refs/tags")

    bash.createFile(root, "config", [[
    [core]
        repositoryformatversion = 0
        filemode = false
        bare = false
        logallrefupdates = true
        symlinks = false
        ignorecase = true
    ]])
    bash.createFile(root, "description", "Unnamed repository; edit this file 'description' to name the repository.")
    bash.createFile(root, "HEAD", "ref: refs/heads/" .. initial_branch)

    bash.createFile(info, "exclude", [[
    # git ls-files --others --exclude-from=.git/info/exclude
    # Lines that start with '#' are comments.
    # For a project mostly in C, the following would be a good set of
    # exclude patterns (uncomment them if you want to use them):
    # *.[oa]
    # *~
    ]])

    bash.createFile(bash.getGitFolderRoot(), "index", "")
    bash.createFile(bash.getGitFolderRoot().Parent, ".rogit_project", "This repository is recognized as a valid roGit project.")
    bash.createFile(bash.getGitFolderRoot().Parent, ".rogitignore", [[
    # Instances to ignore in ro-git
    .rogitignore
    Camera
     ]])
end)

--[[
commands:
clone

clones a git repository
]]

arguments.createArgument("git", "clone", "", function(...)
    local tuple = {...}
    local branch_override = nil
    local url = nil
    local repo_dir = nil

    local i = 1
    while i <= #tuple do
        if (tuple[i] == "-b" or tuple[i] == "--branch") and tuple[i + 1] then
            branch_override = tuple[i + 1]
            i += 1
        elseif tuple[i]:sub(1,1) ~= "-" then -- Positional argument
            if not url then
                url = tuple[i]
            elseif not repo_dir then
                repo_dir = tuple[i]
            end
        end
        i += 1
    end

    if not url or url == "" then
        print("fatal: You must specify a repository to clone.")
        print("\nusage: git clone [<options>] [--] <repo> [<dir>]\n\n    -v, --verbose         be more verbose\n    -q, --quiet           be more quiet\n    --progress            force progress reporting\n    -n, --no-checkout     don't create a checkout")
        return
    end

    local repoName = url:match("/([^/]+)$") or "repository"
    if repo_dir then
        repoName = repo_dir
    end
    print("Cloning into '" .. repoName .. "'...")

    if not bash.getGitFolderRoot() then
        arguments.execute("git", "init", "-q")
    end
    arguments.execute("git", "remote", "add", "origin", url)

    local refs = discoverRefs(url)
    local headSha
    if branch_override then
        headSha = refs["refs/heads/" .. branch_override]
        assert(headSha, "fatal: Remote branch '" .. branch_override .. "' not found in upstream origin")
    else
       headSha = refs["HEAD"] or refs["refs/heads/master"] or refs["refs/heads/main"]
    end
    
    if not headSha or headSha == "" then
        print("warning: You appear to have cloned an empty repository.")
        return
    end

    local packFile = fetchPackfile(url, headSha)
    local _, objectsBySha = unpackObjects(packFile)

    for sha, obj in pairs(objectsBySha) do
        local typeName = ({[1]="commit", [2]="tree", [3]="blob", [4]="tag"})[obj.objType]
        if typeName then
            write_object(typeName, obj.content)
        end
    end

    local activeBranch = branch_override
    if not activeBranch then
        for refName, sha in pairs(refs) do
            if sha == headSha and refName:match("^refs/heads/") then
                activeBranch = refName:sub(12)
                break
            end
        end
        activeBranch = activeBranch or "master"
    end
    
    local gitRoot = bash.getGitFolderRoot()
    bash.modifyFileContents(gitRoot, "HEAD", "ref: refs/heads/" .. activeBranch)
    bash.createFile(bash.createFolder(gitRoot, "refs/heads"), activeBranch, headSha)
    bash.createFile(bash.createFolder(gitRoot, "refs/remotes/origin"), activeBranch, headSha)

    local headCommit = objectsBySha[headSha]
    assert(headCommit, "HEAD commit not found in packfile")

    local treeSha = headCommit.content:match("^tree (%x+)")
    assert(treeSha, "Could not parse tree SHA from commit")

    local treeObj = objectsBySha[treeSha]
    assert(treeObj, "Missing root tree: " .. treeSha)

    local content = treeObj.content
    
    local is_rogit_project = false
    local check_pos = 1
    while check_pos <= #content do
        local spacePos = content:find(" ", check_pos, true)
        local nullPos = content:find("\0", spacePos, true)
        local child_name = content:sub(spacePos + 1, nullPos - 1)
        if child_name == "ServerStorage" then
            local rawSha = content:sub(nullPos + 1, nullPos + 20)
            local ss_sha = ("%02x"):rep(20):format(rawSha:byte(1, 20))
            local ssObj = objectsBySha[ss_sha]
            if ssObj then
                local ss_content = ssObj.content
                local ss_pos = 1
                while ss_pos <= #ss_content do
                    local ss_spacePos = ss_content:find(" ", ss_pos, true)
                    local ss_nullPos = ss_content:find("\0", ss_spacePos, true)
                    local ss_name = ss_content:sub(ss_spacePos + 1, ss_nullPos - 1)
                    if ss_name == ".rogit_project" then
                        is_rogit_project = true
                        break
                    end
                    ss_pos = ss_nullPos + 21
                end
            end
        end
        check_pos = nullPos + 21
    end
    
    if not is_rogit_project then
        print("fatal: repository does not appear to be a rogit project (missing .rogit_project file at ServerStorage root).")
        local gitRoot_to_destroy = bash.getGitFolderRoot()
        if gitRoot_to_destroy then gitRoot_to_destroy:Destroy() end
        return
    end

    local pos = 1
    while pos <= #content do
        local spacePos = content:find(" ", pos, true)
        local mode = content:sub(pos, spacePos - 1)
        local nullPos = content:find("\0", spacePos, true)
        local name = content:sub(spacePos + 1, nullPos - 1)
        local rawSha = content:sub(nullPos + 1, nullPos + 20)
        local sha = ("%02x"):rep(20):format(rawSha:byte(1, 20))
        pos = nullPos + 21

        if mode == "40000" then
            local serviceParent = game:FindFirstChild(name)
            if not serviceParent then
                pcall(function()
                    serviceParent = game:GetService(name)
                end)
            end
            if serviceParent then
                local childProps = peekPropertiesBlob(objectsBySha, sha)
                if childProps then
                    applyProperties(serviceParent, childProps)
                end
                writeTree(objectsBySha, sha, serviceParent, name)
            end
        end
    end

    print("Done. '" .. repoName .. "' cloned.")
end)

--[[
commands:
remote

manages remotes
]]

arguments.createArgument("git", "remote", "", function(...)
    local tuple = {...}

    if #tuple == 0 or tuple[1] == "-v" or tuple[1] == "--verbose" then
        local verbose = #tuple > 0 and (tuple[1] == "-v" or tuple[1] == "--verbose")
        
        local config_content = bash.getFileContents(bash.getGitFolderRoot(), "config")
        local loaded_conf = ini_parser.parseIni(config_content)
        
        for section_name, section_data in pairs(loaded_conf) do
            local remote_name = section_name:match('^remote "(.+)"$')
            if remote_name then
                if verbose then
                    print(remote_name .. "\t" .. (section_data.url or "(no URL)"))
                else
                    print(remote_name)
                end
            end
        end
        return
    end

    local accepted_args = {
        ["add"] = true,
        ["set-url"] = true,
        ["remove"] = true,
        ["rm"] = true,
        ["get-url"] = true,
        ["rename"] = true,
        ["show"] = true
    }
    local subcommand = tuple[1]
    if not accepted_args[subcommand] then
        print("error: unknown subcommand: " .. tostring(subcommand))
        print("usage: git remote [-v | --verbose]")
        print("   or: git remote add [-f] <name> <url>")
        print("   or: git remote remove <name>")
        print("   or: git remote set-url <name> <newurl>")
        return
    end
    
    if subcommand == "add" then
        local do_fetch = false
        local name, url
        local args = {}
        for i=2, #tuple do
            local arg = tuple[i]
            if arg == "-f" or arg == "--fetch" then
                do_fetch = true
            else
                table.insert(args, arg)
            end
        end
        
        name = args[1]
        url = args[2]
        assert(name and url, "usage: git remote add [-f] <name> <url>")

        local config_content = bash.getFileContents(bash.getGitFolderRoot(), "config")
        local loaded_conf = ini_parser.parseIni(config_content)

        local section_name = 'remote "' .. name .. '"'
        loaded_conf[section_name] = {
            url = url,
            fetch = "+refs/heads/*:refs/remotes/" .. name .. "/*"
        }
        
        bash.modifyFileContents(bash.getGitFolderRoot(), "config", ini_parser.serializeIni(
            loaded_conf
        ))

        if do_fetch then
            fetch(name)
        end
    
    elseif subcommand == "set-url" then
        local config_content = bash.getFileContents(bash.getGitFolderRoot(), "config")
        local loaded_conf = ini_parser.parseIni(config_content)
        
        local push_mode = false
        local name, new_url

        if tuple[2] == "--push" then
            push_mode = true
            name = tuple[3]
            new_url = tuple[4]
        else
            name = tuple[2]
            new_url = tuple[3]
        end

        assert(name and new_url, "usage: git remote set-url [--push] <name> <newurl>")

        local section_name = 'remote "' .. name .. '"'
        local remote_section = loaded_conf[section_name]
        assert(remote_section, "fatal: No such remote '" .. name .. "'")

        local url_key = push_mode and "pushurl" or "url"
        remote_section[url_key] = new_url

        bash.modifyFileContents(bash.getGitFolderRoot(), "config", ini_parser.serializeIni(
            loaded_conf
        ))
    
    elseif subcommand == "remove" or subcommand == "rm" then
        local name = tuple[2]
        assert(name, "usage: git remote remove <name>")

        local config_content = bash.getFileContents(bash.getGitFolderRoot(), "config")
        local loaded_conf = ini_parser.parseIni(config_content)

        local section_name = 'remote "' .. name .. '"'
        if loaded_conf[section_name] then
            loaded_conf[section_name] = nil
            bash.modifyFileContents(bash.getGitFolderRoot(), "config", ini_parser.serializeIni(
                loaded_conf
            ))
        else
            error("fatal: No such remote: '" .. name .. "'")
        end

    elseif subcommand == "get-url" then
        local push_mode = false
        local name

        if tuple[2] == "--push" then
            push_mode = true
            name = tuple[3]
        else
            name = tuple[2]
        end

        assert(name, "usage: git remote get-url [--push] <name>")

        local config_content = bash.getFileContents(bash.getGitFolderRoot(), "config")
        local loaded_conf = ini_parser.parseIni(config_content)
        
        local section_name = 'remote "' .. name .. '"'
        local remote_section = loaded_conf[section_name]
        assert(remote_section, "fatal: No such remote: '" .. name .. "'")

        local url
        if push_mode then
            url = remote_section.pushurl or remote_section.url
        else
            url = remote_section.url
        end

        assert(url, "fatal: URL not found for remote '" .. name .. "'")
        print(url)
        
    elseif subcommand == "rename" then
        local old_name = tuple[2]
        local new_name = tuple[3]
        assert(old_name and new_name, "usage: git remote rename <old> <new>")

        local config_content = bash.getFileContents(bash.getGitFolderRoot(), "config")
        local loaded_conf = ini_parser.parseIni(config_content)

        local old_section_name = 'remote "' .. old_name .. '"'
        local new_section_name = 'remote "' .. new_name .. '"'

        local remote_data = loaded_conf[old_section_name]
        assert(remote_data, "fatal: No such remote: '" .. old_name .. "'")
        assert(not loaded_conf[new_section_name], "fatal: remote " .. new_name .. " already exists.")

        if remote_data.fetch and remote_data.fetch:find(old_name, 1, true) then
            remote_data.fetch = remote_data.fetch:gsub(old_name, new_name)
        end
        
        loaded_conf[new_section_name] = remote_data
        loaded_conf[old_section_name] = nil

        bash.modifyFileContents(bash.getGitFolderRoot(), "config", ini_parser.serializeIni(
            loaded_conf
        ))
        
    elseif subcommand == "show" then
        local name = tuple[2]
        assert(name, "usage: git remote show <name>")

        local config_content = bash.getFileContents(bash.getGitFolderRoot(), "config")
        local loaded_conf = ini_parser.parseIni(config_content)

        local section_name = 'remote "' .. name .. '"'
        local remote_section = loaded_conf[section_name]
        assert(remote_section, "fatal: No such remote: '" .. name .. "'")

        print("* remote " .. name)
        print("  Fetch URL: " .. (remote_section.url or "(no URL configured)"))
        print("  Push  URL: " .. (remote_section.pushurl or remote_section.url or "(no URL configured)"))
    end
end)

--[[
commands:
push

pushes a git repository
]]

arguments.createArgument("git", "push", "", function(...)
    local tuple = {...}
    local remote_name = "origin"
    local branch_name = "master"
    local force_push = false
    local set_upstream = false
    local positional = {}

    for _, arg in ipairs(tuple) do
        if arg == "-f" or arg == "--force" then
            force_push = true
        elseif arg == "-u" or arg == "--set-upstream" then
            set_upstream = true
        else
            table.insert(positional, arg)
        end
    end

    if positional[1] then remote_name = positional[1] end
    if positional[2] then 
        branch_name = positional[2] 
    else
        branch_name = get_current_branch() or "master"
    end

    local root = bash.getGitFolderRoot()
    assert(root, "fatal: not a git repository")

    local config_content = bash.getFileContents(root, "config")
    local loaded_conf = ini_parser.parseIni(config_content)

    local section_name = 'remote "' .. remote_name .. '"'
    local remote_section = loaded_conf[section_name]
    assert(remote_section and remote_section.url, "fatal: '" .. remote_name .. "' does not appear to be a git repository")
    
    local url = remote_section.url

    -- authHeaders are now handled internally inside discoverRefs -> url_request_with_retry
    local refs = discoverRefs(url, "git-receive-pack")
    local remoteSha = refs["refs/heads/" .. branch_name] or refs["HEAD"]

    local localSha = get_ref("HEAD")
    assert(localSha, "Nothing to push (no commits)")

    if localSha == remoteSha then
        print("Everything up-to-date")
        return
    end

    if remoteSha and not force_push then
        local is_ff = false
        local current = localSha
        local q = {current}
        local visited = {}
        
        while #q > 0 do
            local sha = table.remove(q, 1)
            if sha == remoteSha then
                is_ff = true
                break
            end
            if not visited[sha] then
                visited[sha] = true
                local obj = read_object(sha)
                if obj and obj.type == "commit" then
                    for parent in obj.content:gmatch("\nparent (%x+)") do
                        table.insert(q, parent)
                    end
                end
            end
        end
        
        if not is_ff then
            print("To " .. url)
            print(" ! [rejected]        " .. branch_name .. " -> " .. branch_name .. " (non-fast-forward)")
            print("error: failed to push some refs to '" .. url .. "'")
            print("hint: Updates were rejected because the tip of your current branch is behind")
            print("hint: its remote counterpart. Integrate the remote changes (e.g.")
            print("hint: 'git pull' before pushing again.")
            return
        end
    end

    local objects = collectObjects(localSha, if force_push then nil else remoteSha)

    local objectCount = 0
    for _ in pairs(objects) do
        objectCount = objectCount + 1
    end

    print(string.format("Enumerating objects: %d, done.", objectCount))
    print(string.format("Counting objects: 100%% (%d/%d), done.", objectCount, objectCount))

    local packFile = buildPackfile(objects)
    local packSize = #packFile

    print(string.format("Compressing objects: 100%% (%d/%d), done.", objectCount, objectCount))
    print(string.format("Writing objects: 100%% (%d/%d), %d bytes | %.2f KiB/s, done.", objectCount, objectCount, packSize, packSize / 1024))
    print(string.format("Total %d (delta 0), reused 0 (delta 0), pack-reused 0", objectCount))

    local oldSha = remoteSha or ("0"):rep(40)
    local refLine = oldSha.." "..localSha.." refs/heads/"..branch_name.."\0report-status side-band-64k\n"
    local refPkt = buffer.tostring(git_proto.encodePkt(buffer.fromstring(refLine)))
    local flushStr = buffer.tostring(git_proto.flush())

    local body = refPkt .. flushStr .. packFile

    local req = {
        Url = return_urls(url, "git-receive-pack")[2],
        Method = "POST",
        Headers = {
            ["Content-Type"] = "application/x-git-receive-pack-request",
            ["Accept"] = "application/x-git-receive-pack-result",
            ["Authorization"] = getAuthHeader(url:match("^(https?://[^/]+)") or url)
        },
        Body = body,
    }

    local ok, res = url_request_with_retry(req)
    assert(ok, "Push request error")

    if res.StatusCode == 200 then
        local remote_messages = {}
        local success_message = "To " .. url .. "\n"

        local response_buffer = buffer.fromstring(res.Body)
        local cursor = 0
        while cursor < buffer.len(response_buffer) do
            local data, next = git_proto.decodePkt(response_buffer, cursor)
            cursor = next
            if data then
                local channel = buffer.readu8(data, 0)
                local line = buffer.tostring(data)
                line = line:sub(2)
                
                line = line:gsub("[\r\n]+", "")

                if channel == 2 then 
                    table.insert(remote_messages, "remote: " .. line)
                elseif channel == 1 then
                    if line:find("^unpack ") then
                    elseif line:find("^ok ") then
                        if not remoteSha or remoteSha == "" then
                            success_message = success_message .. " * [new branch]      " .. branch_name .. " -> " .. branch_name .. "\n"
                        else
                            success_message = success_message .. "   " .. string.sub(oldSha, 1, 7) .. ".." .. string.sub(localSha, 1, 7) .. "  " .. branch_name .. " -> " .. branch_name .. "\n"
                        end
                    elseif line:find("^ng ") then
                        local _ref, reason = line:match("^ng (.-) (.+)$")
                        success_message = success_message .. " ! [rejected]        " .. branch_name .. " -> " .. branch_name .. " (" .. (reason or "unknown") .. ")\n"
                    elseif line ~= "" and not line:find("0000") then
                    end
                else
                    local full_line = buffer.tostring(data)
                    full_line = full_line:gsub("[\r\n]+", "")
                    if full_line:find("^unpack ") then
                    elseif full_line:find("^ok ") then
                        if not remoteSha or remoteSha == "" then
                            success_message = success_message .. " * [new branch]      " .. branch_name .. " -> " .. branch_name .. "\n"
                        else
                            success_message = success_message .. "   " .. string.sub(oldSha, 1, 7) .. ".." .. string.sub(localSha, 1, 7) .. "  " .. branch_name .. " -> " .. branch_name .. "\n"
                        end
                    elseif full_line:find("^ng ") then
                        local _ref, reason = full_line:match("^ng (.-) (.+)$")
                        success_message = success_message .. " ! [rejected]        " .. branch_name .. " -> " .. branch_name .. " (" .. (reason or "unknown") .. ")\n"
                    end
                end
            end
        end

        if #remote_messages > 0 then
            print(table.concat(remote_messages, "\n"))
        end
        
        print(success_message:gsub("\n$", ""))

        if set_upstream then
            local branch_section = 'branch "' .. branch_name .. '"'
            loaded_conf[branch_section] = {
                remote = remote_name,
                merge = "refs/heads/" .. branch_name
            }
            bash.modifyFileContents(root, "config", ini_parser.serializeIni(loaded_conf))
            print("Branch '" .. branch_name .. "' set up to track remote branch '" .. branch_name .. "' from '" .. remote_name .. "'.")
        end
    else
        print("error: failed to push some refs to '" .. url .. "'")
        print("remote: HTTP Status Code: " .. res.StatusCode)
        for line in string.gmatch(res.Body, "[^\n]+") do
            print("remote: " .. line)
        end
    end
end)

arguments.createArgument("git", "status", "st", function()
    assert(bash.getGitFolderRoot(), "fatal: not a git repository (or any of the parent directories): .git")

    local index = read_index()
    local headSha = get_ref("HEAD")
    local current_branch = get_current_branch() or "master"

    local last_index = {}
    local last_index_str = bash.getFileContents(bash.getGitFolderRoot(), "last_commit_index")
    if last_index_str and last_index_str ~= "" then
        last_index = HttpService:JSONDecode(last_index_str)
    end

    local staged_new = {}
    local staged_modified = {}
    local staged_deleted = {}

    for path, data in pairs(index) do
        if not last_index[path] then
            table.insert(staged_new, path)
        elseif last_index[path].sha ~= data.sha then
            table.insert(staged_modified, path)
        end
    end
    for path, _ in pairs(last_index) do
        if not index[path] then
            table.insert(staged_deleted, path)
        end
    end

    if not headSha or headSha == "" then
        print("On branch " .. current_branch)
        print("\nNo commits yet\n")
    else
        print("On branch " .. current_branch)
    end

    local has_staged = #staged_new + #staged_modified + #staged_deleted > 0
    if has_staged then
        print("Changes to be committed:")
        for _, path in ipairs(staged_new) do
            print("\tnew file:   " .. path)
        end
        for _, path in ipairs(staged_modified) do
            print("\tmodified:   " .. path)
        end
        for _, path in ipairs(staged_deleted) do
            print("\tdeleted:    " .. path)
        end
    else
        print("nothing to commit, working tree clean")
    end
end)

arguments.createArgument("git", "log", "", function(...)
    assert(bash.getGitFolderRoot(), "fatal: not a git repository (or any of the parent directories): .git")

    local tuple = {...}
    local max_count = nil
    local oneline = false

    local i = 1
    while i <= #tuple do
        if tuple[i] == "--oneline" then
            oneline = true
        elseif (tuple[i] == "-n" or tuple[i]:match("^%-%-max%-count")) and tuple[i + 1] then
            max_count = tonumber(tuple[i + 1])
            i += 1
        elseif tuple[i]:match("^%-(%d+)$") then
            max_count = tonumber(tuple[i]:match("^%-(%d+)$"))
        end
        i += 1
    end

    local sha = get_ref("HEAD")
    if not sha or sha == "" then
        print("fatal: your current branch 'master' does not have any commits yet")
        return
    end

    local count = 0
    while sha do
        if max_count and count >= max_count then break end

        local obj = read_object(sha)
        if not obj then break end

        local body = obj.content
        local msg = body:match("\n\n(.+)$") or ""

        if oneline then
            print(sha:sub(1, 7) .. " " .. (msg:match("^[^\n]+") or msg))
        else
            local author_line = body:match("\nauthor ([^\n]+)") or ""
            local author_name_email, author_time, author_tz = author_line:match("(.-) (%d+) ([+%-%d]+)")
            
            print("commit " .. sha)
            if author_name_email and author_time then
                print("Author: " .. author_name_email)
                print("Date:   " .. os.date("%a %b %d %H:%M:%S %Y", tonumber(author_time)) .. " " .. author_tz)
            else
                print("Author: " .. author_line)
            end
            print("")
            print("    " .. msg)
            print("")
        end

        count += 1
        sha = body:match("\nparent (%x+)")
    end
end)

arguments.createArgument("git", "branch", "br", function(...)
    assert(bash.getGitFolderRoot(), "fatal: not a git repository (or any of the parent directories): .git")

    local tuple = {...}

    if #tuple == 0 then
        local heads = bash.getGitFolderRoot():FindFirstChild("refs")
        if heads then
            heads = heads:FindFirstChild("heads")
        end
        local current_ref = bash.getFileContents(bash.getGitFolderRoot(), "HEAD") or ""
        local current_branch = current_ref:match("ref: refs/heads/(.+)")

        if heads then
            for _, child in ipairs(heads:GetChildren()) do
                if child.Name == current_branch then
                    print("* " .. child.Name)
                else
                    print("  " .. child.Name)
                end
            end
        end

        if not heads or #heads:GetChildren() == 0 then
            if current_branch then
                print("* " .. current_branch)
            end
        end
        return
    end

    if tuple[1] == "-d" or tuple[1] == "--delete" or tuple[1] == "-D" then
        local branch = tuple[2]
        assert(branch, "fatal: branch name required")

        local heads = bash.getGitFolderRoot():FindFirstChild("refs")
        if heads then heads = heads:FindFirstChild("heads") end
        if heads then
            local ref = heads:FindFirstChild(branch)
            if ref then
                ref:Destroy()
                print("Deleted branch " .. branch)
            else
                print("error: branch '" .. branch .. "' not found.")
            end
        end
        return
    end

    if tuple[1] == "-m" or tuple[1] == "--move" then
        local old_branch = tuple[2]
        local new_branch = tuple[3]
        if not new_branch then
            local current_ref = bash.getFileContents(bash.getGitFolderRoot(), "HEAD") or ""
            old_branch = current_ref:match("ref: refs/heads/(.+)")
            new_branch = old_branch
        end
        assert(old_branch and new_branch, "usage: git branch -m [<old>] <new>")

        local sha = get_ref("refs/heads/" .. old_branch)
        assert(sha, "error: refname refs/heads/" .. old_branch .. " not found")

        update_ref("refs/heads/" .. new_branch, sha)

        local heads = bash.getGitFolderRoot():FindFirstChild("refs")
        if heads then heads = heads:FindFirstChild("heads") end
        if heads then
            local old_ref = heads:FindFirstChild(old_branch)
            if old_ref then old_ref:Destroy() end
        end

        local current_ref = bash.getFileContents(bash.getGitFolderRoot(), "HEAD") or ""
        if current_ref:match("ref: refs/heads/(.+)") == old_branch then
            bash.modifyFileContents(bash.getGitFolderRoot(), "HEAD", "ref: refs/heads/" .. new_branch)
        end
        return
    end

    local branch_name = tuple[1]
    if not branch_name or branch_name == "" then
        -- list branches if no name provided
        local heads = bash.getGitFolderRoot():FindFirstChild("refs")
        if heads then heads = heads:FindFirstChild("heads") end
        if heads then
            local current = get_current_branch()
            for _, child in ipairs(heads:GetChildren()) do
                if child.Name == current then
                    print("* " .. child.Name)
                else
                    print("  " .. child.Name)
                end
            end
        end
        return
    end
    assert(is_valid_branch_name(branch_name), "fatal: '" .. tostring(branch_name) .. "' is not a valid branch name.")
    
    local start_point = tuple[2]
    local sha = start_point and get_ref("refs/heads/" .. start_point) or get_ref("HEAD")
    assert(sha and sha ~= "", "fatal: Not a valid object name: '" .. (start_point or "HEAD") .. "'.")
    update_ref("refs/heads/" .. branch_name, sha)
    print("Created branch '" .. branch_name .. "'")
end)

arguments.createArgument("git", "switch", "", function(...)
    assert(bash.getGitFolderRoot(), "fatal: not a git repository (or any of the parent directories): .git")
    local tuple = {...}
    
    local create_branch = false
    local branch_name = ""
    
    if tuple[1] == "-c" or tuple[1] == "--create" then
        create_branch = true
        branch_name = tuple[2]
    else
        branch_name = tuple[1]
    end
    
    if not branch_name or branch_name == "" then
        print("fatal: branch name required")
        print("usage: git switch [-c | --create] <branch>")
        return
    end
    
    assert(is_valid_branch_name(branch_name), "fatal: invalid reference: " .. tostring(branch_name))
    
    if create_branch then
        local sha = get_ref("HEAD")
        assert(sha and sha ~= "", "fatal: you are on a branch with no commits yet")
        update_ref("refs/heads/" .. branch_name, sha)
    else
        local heads = bash.getGitFolderRoot():FindFirstChild("refs")
        if heads then heads = heads:FindFirstChild("heads") end
        local branch_exists = heads and heads:FindFirstChild(branch_name)
        assert(branch_exists, "fatal: invalid reference: " .. branch_name)
    end
    
    bash.modifyFileContents(bash.getGitFolderRoot(), "HEAD", "ref: refs/heads/" .. branch_name)
    print("Switched to " .. (create_branch and "a new branch '" or "branch '") .. branch_name .. "'")
    
    local status, err = pcall(function()
        arguments.execute("git", "reset", "--hard", "HEAD")
    end)
    if not status then warn(err) end
end)

arguments.createArgument("git", "fetch", "", function(...)
    assert(bash.getGitFolderRoot(), "fatal: not a git repository (or any of the parent directories): .git")

    local tuple = {...}
    local remote_name = tuple[1] or "origin"
    fetch(remote_name)
end)

arguments.createArgument("git", "reset", "", function(...)
    assert(bash.getGitFolderRoot(), "fatal: not a git repository (or any of the parent directories): .git")

    local tuple = {...}
    local mode = "--mixed"
    local commit_target = "HEAD"
    local paths = {}

    local i = 1
    local positional = {}
    while i <= #tuple do
        local arg = tuple[i]
        if arg == "--soft" or arg == "--mixed" or arg == "--hard" then
            mode = arg
        elseif arg:sub(1, 1) ~= "-" then
            table.insert(positional, arg)
        end
        i += 1
    end

    if #positional > 0 then
        local first = positional[1]
        local is_commit = false
        if first == "HEAD" or get_ref("refs/heads/" .. first) then
            is_commit = true
        elseif #first >= 7 and first:match("^%x+$") then
            is_commit = true
        end
        
        if is_commit then
            commit_target = table.remove(positional, 1)
        end
        
        for _, p in ipairs(positional) do
            table.insert(paths, p)
        end
    end

    if #paths > 0 then
        local index = read_index()
        local tree_sha = ""
        local head_commit = get_ref("HEAD")
        
        if head_commit and head_commit ~= "" then
            local commit_obj = read_object(head_commit)
            if commit_obj then
                tree_sha = commit_obj.content:match("^tree (%x+)") or ""
            end
        end

        local tree_objects = {}
        if tree_sha ~= "" then
            local function recurse_tree(current_sha, prefix)
                local obj = read_object(current_sha)
                if not obj then return end
                
                local content = obj.content
                local pos = 1
                while pos <= #content do
                    local spacePos = content:find(" ", pos, true)
                    local mode_str = content:sub(pos, spacePos - 1)
                    local nullPos = content:find("\0", spacePos, true)
                    local name = content:sub(spacePos + 1, nullPos - 1)
                    local rawSha = content:sub(nullPos + 1, nullPos + 20)
                    local child_sha = ("%02x"):rep(20):format(rawSha:byte(1, 20))
                    pos = nullPos + 21
                    
                    local full_path = prefix == "" and name or (prefix .. "/" .. name)
                    if mode_str == "40000" then
                        recurse_tree(child_sha, full_path)
                    else
                        tree_objects[full_path] = {sha = child_sha, mode = mode_str}
                    end
                end
            end
            pcall(recurse_tree, tree_sha, "")
        end

        for _, target_path in ipairs(paths) do
            if target_path:sub(1, 5) == "game." or target_path:sub(1, 5) == "game/" then
                target_path = target_path:sub(6)
            end
            target_path = target_path:gsub("%.", "/")

            local found = false
            for path, _ in pairs(index) do
                if path == target_path or path:sub(1, #target_path + 1) == target_path .. "/" then
                    found = true
                    if tree_objects[path] then
                        index[path] = {sha = tree_objects[path].sha, mode = tree_objects[path].mode}
                    else
                        index[path] = nil
                    end
                end
            end
            if not found then
                warn("fatal: pathspec '" .. target_path .. "' did not match any files")
            end
        end
        
        write_index(index)
        -- We only print this if not doing a broad switch checkout
        if not (mode == "--hard" and commit_target == "HEAD" and #paths == 0) then
            print("Unstaged changes after reset:")
        end
        return
    end

    local target_sha = commit_target
    if target_sha == "HEAD" then
        target_sha = get_ref("HEAD")
    else
        local potential_ref = get_ref("refs/heads/" .. commit_target)
        if potential_ref then
            target_sha = potential_ref
        elseif #target_sha >= 7 then
            local found_full = false
            local objects_dir = bash.getGitFolderRoot():FindFirstChild("objects")
            if objects_dir then
                local prefix = target_sha:sub(1, 2)
                local rem = target_sha:sub(3)
                local prefix_dir = objects_dir:FindFirstChild(prefix)
                if prefix_dir then
                    for _, child in ipairs(prefix_dir:GetChildren()) do
                        if child.Name:sub(1, #rem) == rem then
                            target_sha = prefix .. child.Name
                            found_full = true
                            break
                        end
                    end
                end
            end
            if not found_full then
                local obj = read_object(target_sha) 
                if not obj then
                   error("fatal: ambiguous argument '" .. commit_target .. "': unknown revision or path not in the working tree.")
                end
            end
        end
    end

    assert(target_sha and target_sha ~= "", "fatal: Not a valid object name: '" .. commit_target .. "'.")

    local current_ref = bash.getFileContents(bash.getGitFolderRoot(), "HEAD") or ""
    local current_branch = current_ref:match("ref: refs/heads/(.+)")
    
    if current_branch then
        update_ref("refs/heads/" .. current_branch, target_sha)
    else
        bash.modifyFileContents(bash.getGitFolderRoot(), "HEAD", target_sha)
    end

    if mode == "--soft" then
        return
    end

    local target_commit = read_object(target_sha)
    local target_tree_sha = target_commit.content:match("^tree (%x+)")

    local fake_remote_map = {}
    if mode == "--hard" then
        local function collect_tree(current_sha)
            if not current_sha or fake_remote_map[current_sha] then return end
            local obj = read_object(current_sha)
            if not obj then return end
            fake_remote_map[current_sha] = obj
            
            if obj.type == "tree" then
                local content = obj.content
                local pos = 1
                while pos <= #content do
                    local spacePos = content:find(" ", pos, true)
                    local _entry_mode = content:sub(pos, spacePos - 1)
                    local nullPos = content:find("\0", spacePos, true)
                    local rawSha = content:sub(nullPos + 1, nullPos + 20)
                    local child_sha = ("%02x"):rep(20):format(rawSha:byte(1, 20))
                    pos = nullPos + 21
                    collect_tree(child_sha)
                end
            end
        end
        collect_tree(target_tree_sha)
    end

    local function build_index_from_tree(tree_sha, prefix, new_index)
        if not tree_sha or tree_sha == "" then return end
        local obj = read_object(tree_sha)
        if not obj then return end
        
        local content = obj.content
        local pos = 1
        while pos <= #content do
            local spacePos = content:find(" ", pos, true)
            local entry_mode = content:sub(pos, spacePos - 1)
            local nullPos = content:find("\0", spacePos, true)
            local name = content:sub(spacePos + 1, nullPos - 1)
            local rawSha = content:sub(nullPos + 1, nullPos + 20)
            local child_sha = ("%02x"):rep(20):format(rawSha:byte(1, 20))
            pos = nullPos + 21
            
            local full_path = prefix == "" and name or (prefix .. "/" .. name)
            
            if entry_mode == "40000" then
                build_index_from_tree(child_sha, full_path, new_index)
                if mode == "--hard" then
                    local segments = string.split(full_path, "/")
                    local currObj = game
                    for _, segment in ipairs(segments) do
                        if currObj and currObj:FindFirstChild(segment) then
                            currObj = currObj:FindFirstChild(segment)
                        elseif currObj then
                            pcall(function() currObj = game:GetService(segment) end)
                        end
                    end
                    if not currObj or (currObj.Name ~= name) then
                    end
                end
            else
                new_index[full_path] = {sha = child_sha, mode = entry_mode}
            end
        end
    end

    local new_index = {}
    build_index_from_tree(target_tree_sha, "", new_index)
    
    write_index(new_index)
    bash.modifyFileContents(bash.getGitFolderRoot(), "last_commit_index", HttpService:JSONEncode(new_index))

    if mode == "--hard" then
        local index = read_index()
        for path, _ in pairs(index) do
            if not new_index[path] then
                local segments = string.split(path, "/")
                local currObj = game
                for _, segment in ipairs(segments) do
                    if currObj and currObj:FindFirstChild(segment) then
                        currObj = currObj:FindFirstChild(segment)
                    else
                        currObj = nil
                        break
                    end
                end
                if currObj and currObj ~= game and currObj.Parent ~= game then
                    currObj:Destroy()
                end
            end
        end

        for _, service in ipairs(bash.trackingRoot) do
            local obj = read_object(target_tree_sha)
            if obj then
                local content = obj.content
                local pos = 1
                while pos <= #content do
                    local spacePos = content:find(" ", pos, true)
                    local entry_mode = content:sub(pos, spacePos - 1)
                    local nullPos = content:find("\0", spacePos, true)
                    local name = content:sub(spacePos + 1, nullPos - 1)
                    local rawSha = content:sub(nullPos + 1, nullPos + 20)
                    local child_sha = ("%02x"):rep(20):format(rawSha:byte(1, 20))
                    pos = nullPos + 21
                    
                    if entry_mode == "40000" and service.Name == name then
                        local objectsByShaFallback = setmetatable({}, {
                            __index = function(_, key)
                                local obj = read_object(key)
                                if not obj then return nil end
                                return {
                                    objType = ({commit=1, tree=2, blob=3, tag=4})[obj.type],
                                    content = obj.content
                                }
                            end
                        })
                        writeTree(objectsByShaFallback, child_sha, service, name)
                    end
                end
            end
        end
        print("HEAD is now at " .. target_sha:sub(1, 7))
    elseif mode == "--mixed" or mode == "--soft" then
        print("Unstaged changes after reset:")
    end
end)

arguments.createArgument("git", "config", "", function(...)
    local tuple = {...}
    local is_global = false
    local args_start = 1
    
    if tuple[1] == "--global" then
        is_global = true
        args_start = 2
    end
    
    local key = tuple[args_start]
    local value = tuple[args_start + 1]
    
    if not key or key == "" then
        print("usage: git config [<options>]")
        return
    end
    
    local key_parts = string.split(key, ".")
    local section = key_parts[1]
    local property = key_parts[2]
    
    local sensitive_keys = {
        ["user.name"] = true,
        ["user.email"] = true,
        ["user.token"] = true,
        ["user.password"] = true
    }

    if value then
        if (is_global or sensitive_keys[key]) and ACTIVE_PLUGIN then
            ACTIVE_PLUGIN:SetSetting(key, value)
            print("Set '" .. key .. "' in plugin settings")
            return
        end
    end

    local root = bash.getGitFolderRoot()
    if not root then
        print("fatal: not in a git directory")
        return
    end
    
    local config_content = bash.getFileContents(root, "config")
    local loaded_conf = ini_parser.parseIni(config_content)
    
    if value then
        if not loaded_conf[section] then
            loaded_conf[section] = {}
        end
        loaded_conf[section][property] = value
        bash.modifyFileContents(root, "config", ini_parser.serializeIni(loaded_conf))
    else
        local val = getConfigValue(key)
        if val then
            print(val)
        end
    end
end)

return git