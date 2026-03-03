local Remote = {}

local HttpService = game:GetService("HttpService")
local hashlib = require(script.Parent.hashlib)
local zlib = require(script.Parent.zlib)
local bash = require(script.Parent.Parent.bash)
local git_proto = require(script.Parent.git_proto)
local Utilities = require(script.Parent.utilities)
local Auth = require(script.Parent.localstore)
local Requests = require(script.Parent.requests)
local ini_parser = require(script.Parent.ini_parser)
local _Handlers = require(script.Parent.git_handlers)
local instances = require(script.Parent.instances)

local ROGIT_ID = "_rogit_id"
local pending_instance_refs = {}

Remote.print = print
Remote.warn = warn
Remote.error = error

--[[
Requests git refs, parses and returns.
]]
function Remote.discoverRefs(url: string, service: string?)
	local req = {
        Url = Utilities.return_urls(url, service or "git-upload-pack")[1],
        Method = "GET",
        Headers = {
            ["Authorization"] = Auth.getAuthHeader(url:match("^(https?://[^/]+)") or url)
        }
    }
    
    local ok, res = Requests.url_request_with_retry(req)

    if not ok or res.StatusCode ~= 200 then
        Remote.error("fatal: repository '" .. url .. "' not found or access denied")
    end
    
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

--[[
Fetches the git repository packfile, parses and returns.
]]
function Remote.fetchPackfile(url: string, sha: string)
	local wantPkt = git_proto.encodePkt(buffer.fromstring("want " .. sha .. " side-band-64k ofs-delta\n"))
	local donePkt = git_proto.encodePkt(buffer.fromstring("done\n"))
	local body = buffer.tostring(wantPkt) .. buffer.tostring(git_proto.flush()) .. buffer.tostring(donePkt)

	local req = {
		Url = Utilities.return_urls(url)[2],
		Method = "POST",
		Headers = {
			["Content-Type"] = "application/x-git-upload-pack-request",
			["Accept"] = "application/x-git-upload-pack-result",
            ["Authorization"] = Auth.getAuthHeader(url:match("^(https?://[^/]+)") or url)
		},
		Body = body,
	}
    
    local ok, res = Requests.url_request_with_retry(req)
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
						Remote.print("remote: " .. trimmed)
					end
				end
			elseif channel == 3 then
				Remote.error("remote error: " .. buffer.tostring(data))
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

--[[
Unpacks objects (either from clone/pull)
]]
function Remote.unpackObjects(fullPack)
	local _version, objCount, cursor = git_proto.parsePackHeader(fullPack, 0)
	local parsedCount = 0
	local objectsByOffset = {}
	local typesByOffset = {}
	local objectsBySha = {}

	local fullPackStr = buffer.tostring(fullPack)
	local fullPackLen = #fullPackStr

	for i = 1, objCount do
		Utilities.roYield()
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
			local parts = table.create(20)
			for j = 0, 19 do
				parts[j + 1] = string.format("%02x", buffer.readu8(fullPack, cursor + j))
			end
			refShaHex = table.concat(parts)
			cursor += 20
		end

		local decompressed, bytesLeft = zlib.decompressZlib(fullPackStr, cursor + 1)

		local resolved
		local actualType
		if objType == 6 then
			local base = objectsByOffset[objOffset - baseOffset]
			assert(base, "Missing base object at offset " .. (objOffset - baseOffset))
			resolved = git_proto.applyDelta(base, decompressed)
			actualType = typesByOffset[objOffset - baseOffset]
		elseif objType == 7 then
			local baseWrapper = objectsBySha[refShaHex]
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

		cursor = fullPackLen - bytesLeft

		local typePrefix = ({[1]="commit",[2]="tree",[3]="blob",[4]="tag"})[actualType]
		if typePrefix and resolved then
			local header = typePrefix .. " " .. #resolved .. "\0"
			local sha = hashlib.sha1()(header)(resolved)()
			objectsBySha[sha] = {objType = actualType, content = resolved}
		end
	end

	return objectsByOffset, objectsBySha
end

--[[
Parses properties of objects.
]]
function Remote.peekPropertiesBlob(objectsBySha, treeSha)
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

--[[
Resolves the references for instances.
]]
function Remote.resolve_instance_refs()
    if #pending_instance_refs == 0 then return end
    
    local guid_map = {}
    local function map_guids(node)
        if node ~= bash.getGitFolderRoot() and not node:IsDescendantOf(bash.getGitFolderRoot()) then
            Utilities.roYield()
            local guid = node:GetAttribute(ROGIT_ID)
            if guid then
                guid_map[guid] = node
            end
            for _, child in ipairs(node:GetChildren()) do
                map_guids(child)
            end
        end
    end
    
    for _, service in ipairs(bash.trackingRoot) do
        map_guids(service)
    end
    
    for _, refPending in ipairs(pending_instance_refs) do
        local target = guid_map[refPending.targetGuid]
        if target then
            pcall(function()
                refPending.inst[refPending.prop] = target
            end)
        end
    end
    
    table.clear(pending_instance_refs)
end

--[[
applies properties to an instance.
]]
function Remote.applyProperties(instance, props)
    Utilities.roYield()
    for _, propData in ipairs(props) do
        if propData.name == "_attributes" and propData.valueType == "_attributes" then
            if type(propData.value) == "table" and propData.value[1] and type(propData.value[1]) == "table" and propData.value[1].name then
                -- New sorted array format
                for _, attrData in ipairs(propData.value) do
                    local val = instances.deserialize_property(attrData.value, attrData.valueType)
                    if val ~= nil then
                        pcall(function() instance:SetAttribute(attrData.name, val) end)
                    end
                end
            elseif type(propData.value) == "table" then
                -- Legacy dictionary format
                for attrName, attrValue in pairs(propData.value) do
                    local val
                    if type(attrValue) == "table" and attrValue.value then
                        val = instances.deserialize_property(attrValue.value, attrValue.valueType)
                    else
                        val = attrValue
                    end
                    if val ~= nil then
                        pcall(function() instance:SetAttribute(attrName, val) end)
                    end
                end
            end
        elseif propData.name == "_tags" and propData.valueType == "_tags" then
            for _, tag in ipairs(propData.value) do
                pcall(function() instance:AddTag(tag) end)
            end
        elseif propData.name ~= "ClassName" and propData.name ~= "Parent" then
            if propData.valueType == "Instance" then
                if type(propData.value) == "table" and propData.value.Guid then
                    table.insert(pending_instance_refs, {
                        inst = instance,
                        prop = propData.name,
                        targetGuid = propData.value.Guid
                    })
                end
            else
                local val = instances.deserialize_property(propData.value, propData.valueType)
                if val ~= nil then
                    if propData.name == "MeshId" and instance:IsA("MeshPart") then
                        pcall(function()
                            local InsertService = game:GetService("InsertService")
                            local loadedMesh = InsertService:CreateMeshPartAsync(val, instance.CollisionFidelity, instance.RenderFidelity)
                            instance:ApplyMesh(loadedMesh)
                        end)
                    elseif propData.name == "Source" and instance:IsA("LuaSourceContainer") then
                        pcall(function()
                            (instance :: any).Source = val
                        end)
                    else
                        local name = propData.name
                        if name == "Color3uint8" then name = "Color" end
                        
                        local ok = pcall(function()
                            instance[name] = val
                        end)
                        
                        if not ok then
                            -- Try capitalized fallback (e.g. 'size' -> 'Size')
                            local cap = name:sub(1,1):upper() .. name:sub(2)
                            pcall(function()
                                instance[cap] = val
                            end)
                        end
                    end
                end
            end
        end
    end
end

--[[
find instances by rogit_id (e.g. for properties with instance type)
]]
function Remote.findByRogitId(parent, rogitId)
    for _, child in ipairs(parent:GetChildren()) do
        if child:GetAttribute(ROGIT_ID) == rogitId then
            return child
        end
    end
    return nil
end

--[[
Extracts the rogit_id from properties.
]]
function Remote.extractRogitId(props)
    for _, propData in ipairs(props) do
        if propData.name == "_attributes" and propData.valueType == "_attributes" then
            if type(propData.value) == "table" then
                -- Check for new sorted array format: [{name = "...", value = ...}]
                if propData.value[1] and type(propData.value[1]) == "table" and propData.value[1].name then
                    for _, attrData in ipairs(propData.value) do
                        if attrData.name == ROGIT_ID then
                            local v = attrData.value
                            return type(v) == "table" and (v.Guid or v.value) or v
                        end
                    end
                else
                    -- Fallback to legacy dictionary format
                    local entry = propData.value[ROGIT_ID]
                    if entry then
                        return type(entry) == "table" and (entry.Guid or entry.value) or entry
                    end
                end
            end
        elseif propData.name == ROGIT_ID then
            -- Extreme fallback if ID is at root level of props (some very old versions)
            return type(propData.value) == "table" and (propData.value.Guid or propData.value.value) or propData.value
        end
    end
    return nil
end

--[[
Writes to the remote tree.
]]
function Remote.writeTree(objectsBySha, treeSha, parent, treePath)
    local treeObj = objectsBySha[treeSha]
    assert(treeObj, "Missing tree: " .. treeSha)

    local content = treeObj.content
    local pos = 1

    while pos <= #content do
        Utilities.roYield()
        local spacePos = content:find(" ", pos, true)
        local mode = content:sub(pos, spacePos - 1)

        local nullPos = content:find("\0", spacePos, true)
        local name = content:sub(spacePos + 1, nullPos - 1)

        local rawSha = content:sub(nullPos + 1, nullPos + 20)
        local sha = ("%02x"):rep(20):format(rawSha:byte(1, 20))
        pos = nullPos + 21

        local entryPath = treePath and (treePath .. "/" .. name) or name

        if mode == "40000" then
            local childProps = Remote.peekPropertiesBlob(objectsBySha, sha)
            local className = nil
            local uuid = nil
            if childProps then
                for _, propData in ipairs(childProps) do
                    if propData.name == "ClassName" then
                        className = propData.value
                    end
                end
                uuid = Remote.extractRogitId(childProps)
            end

            local target = uuid and Remote.findByRogitId(parent, uuid) or parent:FindFirstChild(name)
            local isNew = false
            if not target then
                isNew = true
                if className then
                    local ok, inst = pcall(Instance.new, className)
                    if ok then
                        target = inst
                        target.Name = name
                    else
                        target = Instance.new("Folder")
                        target.Name = name
                    end
                else
                    target = Instance.new("Folder")
                    target.Name = name
                end
            end

            if uuid then
                target:SetAttribute(ROGIT_ID, uuid)
            end

            if childProps then
                Remote.applyProperties(target, childProps)
            end

            Remote.writeTree(objectsBySha, sha, target, entryPath)

            if isNew then
                target.Parent = parent
            end
        else
            local blobObj = objectsBySha[sha]
            if not blobObj then
                continue
            elseif name == ".properties" then
                local ok, props = pcall(function() return HttpService:JSONDecode(blobObj.content) end)
                if ok then
                    Remote.applyProperties(parent, props)
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

                local uuid = Remote.extractRogitId(props)
                local newInstance = uuid and Remote.findByRogitId(parent, uuid) or parent:FindFirstChild(name)

                local isNew = false
                if not newInstance then
                    isNew = true
                    local ok2, inst = pcall(Instance.new, className)
                    if not ok2 then
                        continue
                    end
                    newInstance = inst
                    newInstance.Name = name
                end

                Remote.applyProperties(newInstance, props)

                if isNew then
                    newInstance.Parent = parent
                end
            end
        end
    end
end

--[[
Fetches remote based off name.
]]
function Remote.fetch(remote_name)
    print("Fetching " .. remote_name)

    local config_content = bash.getFileContents(bash.getGitFolderRoot(), "config")
    local loaded_conf = ini_parser.parseIni(config_content)

    local section_name = 'remote "' .. remote_name .. '"'
    local remote_section = loaded_conf[section_name]
    assert(remote_section and remote_section.url, "fatal: '" .. remote_name .. "' does not appear to be a git repository")
    
    local url = remote_section.url

    local refs = Remote.discoverRefs(url)
    
    local output = { "From " .. url }
    for name, sha in pairs(refs) do
        if name ~= "HEAD" then
            local branch_name = name:match("refs/heads/(.+)")
            if branch_name then
                table.insert(output, string.format(" * [new branch]      %-15s -> %s/%s", branch_name, remote_name, branch_name))
                _Handlers.update_ref("refs/remotes/" .. remote_name .. "/" .. branch_name, sha)
            end
        end
    end
    print(table.concat(output, "\n"))

    for name, sha in pairs(refs) do
        if name ~= "HEAD" then
            local pack = Remote.fetchPackfile(url, sha)
            local _, objectsBySha = Remote.unpackObjects(pack)
            for objSha, obj in pairs(objectsBySha) do
                local typeName = ({[1]="commit", [2]="tree", [3]="blob", [4]="tag"})[obj.objType]
                if typeName then
                    _Handlers.write_object(typeName, obj.content)
                end
            end
        end
    end
end

function Remote.checkout(treeSha)
    local objectsByShaFallback = setmetatable({}, {
        __index = function(_, key)
            local obj = _Handlers.read_object(key)
            if not obj then return nil end
            return {
                objType = ({commit=1, tree=2, blob=3, tag=4})[obj.type],
                content = obj.content
            }
        end
    })

    local treeObj = objectsByShaFallback[treeSha]
    if not treeObj then return false, "Tree " .. treeSha .. " not found" end
    
    local content = treeObj.content
    local pos = 1
    while pos <= #content do
        Utilities.roYield()
        local spacePos = content:find(" ", pos, true)
        if not spacePos then break end
        local mode = content:sub(pos, spacePos - 1)
        local nullPos = content:find("\0", spacePos, true)
        if not nullPos then break end
        local name = content:sub(spacePos + 1, nullPos - 1)
        local rawSha = content:sub(nullPos + 1, nullPos + 20)
        local sha = ("%02x"):rep(20):format(rawSha:byte(1, 20))
        pos = nullPos + 21

        if mode == "40000" then
            local serviceParent = game:FindFirstChild(name)
            if not serviceParent then
                pcall(function() serviceParent = game:GetService(name) end)
            end
            if serviceParent then
                local childProps = Remote.peekPropertiesBlob(objectsByShaFallback, sha)
                if childProps then
                    Remote.applyProperties(serviceParent, childProps)
                end
                Remote.writeTree(objectsByShaFallback, sha, serviceParent, name)
            end
        end
    end

    Remote.resolve_instance_refs()

    local new_index = Remote.buildIndexFromTree(objectsByShaFallback, treeSha)
    local old_index = _Handlers.read_index()
    
    local to_destroy = {}
    for path, _ in pairs(old_index) do
        if not new_index[path] then
            local clean_path = path:match("^(.-)/%.properties$") or path
            local currObj = Utilities.parse_path(clean_path)
            if currObj and currObj ~= game and currObj.Parent ~= game then
                table.insert(to_destroy, currObj)
            end
        end
    end
    for _, obj in ipairs(to_destroy) do
        pcall(function() obj:Destroy() end)
    end

    _Handlers.write_index(new_index)
    bash.modifyFileContents(bash.getGitFolderRoot(), "last_commit_index", HttpService:JSONEncode(new_index))
    
    return true
end

function Remote.buildIndexFromTree(objectsBySha, treeSha)
    local index = {}

    local function traverse(tSha, prefix)
        local treeObj = objectsBySha[tSha]
        if not treeObj then return end

        local content = treeObj.content
        local pos = 1
        while pos <= #content do
            local spacePos = content:find(" ", pos, true)
            local mode = content:sub(pos, spacePos - 1)
            local nullPos = content:find("\0", spacePos, true)
            local name = content:sub(spacePos + 1, nullPos - 1)
            local rawSha = content:sub(nullPos + 1, nullPos + 20)
            local entrySha = ("%02x"):rep(20):format(rawSha:byte(1, 20))
            pos = nullPos + 21

            local entryPath = prefix ~= "" and (prefix .. "/" .. name) or name

            if mode == "40000" then
                traverse(entrySha, entryPath)
            else
                index[entryPath] = {
                    mode = mode,
                    sha = entrySha
                }
            end
        end
    end

    traverse(treeSha, "")
    return index
end

return Remote
