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
Second return value holds extra info from the server: `symrefs` (e.g. HEAD -> refs/heads/main) and `capabilities`.
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

    if not ok then
        error("fatal: unable to access '" .. url .. "': " .. tostring(res), 0)
    end
    if res.StatusCode ~= 200 then
        local reason = (res.StatusCode == 401 or res.StatusCode == 403) and "authentication failed or access denied"
            or (res.StatusCode == 404 and "not found")
            or ("HTTP " .. tostring(res.StatusCode))
        error("fatal: repository '" .. url .. "' " .. reason, 0)
    end
    
	local buf = buffer.fromstring(res.Body)
	local cursor = 0
	local refs = {}
	local info = {symrefs = {}, capabilities = ""}

	while cursor < buffer.len(buf) do
		local data, next = git_proto.decodePkt(buf, cursor)
		cursor = next
		if data then
			local sha, name, caps = git_proto.parseRef(data)
			if sha and name and name ~= "capabilities^{}" then
				refs[name] = sha
			end
			if caps and caps ~= "" then
				info.capabilities = caps
				for from, to in caps:gmatch("symref=([^:%s]+):([^%s]+)") do
					info.symrefs[from] = to
				end
			end
		end
	end

	return refs, info
end

--[[
Fetches the git repository packfile, parses and returns.
`wants` is a sha (or a list of them), `haves` are commits we already own so the server can skip sending them.
]]
function Remote.fetchPackfile(url: string, wants, haves)
	if type(wants) == "string" then wants = {wants} end

	local function pkt(line)
		return buffer.tostring(git_proto.encodePkt(buffer.fromstring(line)))
	end

	local parts = {}
	for i, sha in ipairs(wants) do
		parts[#parts + 1] = pkt("want " .. sha .. (i == 1 and " side-band-64k ofs-delta" or "") .. "\n")
	end
	parts[#parts + 1] = buffer.tostring(git_proto.flush())
	for _, sha in ipairs(haves or {}) do
		parts[#parts + 1] = pkt("have " .. sha .. "\n")
	end
	parts[#parts + 1] = pkt("done\n")
	local body = table.concat(parts)

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
    assert(ok, "Upload-pack request error: " .. tostring(res))
	assert(res.StatusCode == 200, "Upload-pack failed: " .. tostring(res.StatusCode))

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
				error("remote error: " .. buffer.tostring(data):sub(2), 0)
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
                if ok then return props, entrySha end
            end
            return nil
        end
    end
    return nil
end

--[[
Makes the folder for a submodule (a "gitlink" tree entry). Its contents come from `git submodule update`.
]]
function Remote.writeGitlink(parent, name, sha)
    local folder = parent:FindFirstChild(name)
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = name
        folder.Parent = parent
    end
    if type(folder:GetAttribute(_Handlers.SUBMODULE_ATTRIBUTE)) ~= "string" then
        folder:SetAttribute(_Handlers.SUBMODULE_ATTRIBUTE, Remote.submoduleNameFor and Remote.submoduleNameFor(folder) or name)
    end
    folder:SetAttribute(_Handlers.SUBMODULE_COMMIT_ATTRIBUTE, sha)
    return folder
end

--[[
Gives a MeshPart the mesh behind `content` (a Content value). MeshParts can't simply be assigned a new mesh.
]]
local function applyMeshContent(meshPart, content)
    local AssetService = game:GetService("AssetService")
    local loaded = AssetService:CreateMeshPartAsync(content, {
        CollisionFidelity = meshPart.CollisionFidelity,
        RenderFidelity = meshPart.RenderFidelity,
    })
    meshPart:ApplyMesh(loaded)
end

--[[
Resolves the references for instances.
]]
function Remote.resolve_instance_refs()
    if #pending_instance_refs == 0 then return end
    
    local guid_map = {}
    local function map_guids(node)
        if not bash.isInternal(node) then
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
    
    for _, service in ipairs(bash.getTrackedRoots()) do
        map_guids(service)
    end
    
    for _, refPending in ipairs(pending_instance_refs) do
        local target = guid_map[refPending.targetGuid]
        if target then
            pcall(function()
                --// Content properties (e.g. an ImageLabel showing an EditableImage) wrap the object
                if refPending.asMesh then
                    applyMeshContent(refPending.inst, Content.fromObject(target))
                else
                    refPending.inst[refPending.prop] = refPending.asContent and Content.fromObject(target) or target
                end
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

    local hasMeshId = false
    for _, propData in ipairs(props) do
        if propData.name == "MeshId" then hasMeshId = true break end
    end

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
        elseif instances.is_pseudo_property(propData) then
            instances.apply_pseudo_property(instance, propData)
        elseif propData.name ~= "ClassName" and propData.name ~= "Parent" then
            if propData.valueType == "Content" and type(propData.value) == "table" and type(propData.value.Object) == "table" then
                --// points at another instance, link it once everything exists
                if propData.value.Object.Guid then
                    table.insert(pending_instance_refs, {
                        inst = instance,
                        prop = propData.name,
                        targetGuid = propData.value.Object.Guid,
                        asContent = true,
                        asMesh = propData.name == "MeshContent" and instance:IsA("MeshPart"),
                    })
                end
            elseif propData.valueType == "Instance" then
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
                        --// downloading a mesh is slow, don't do it when it's already the right one
                        if instance.MeshId ~= val then
                            pcall(function()
                                local InsertService = game:GetService("InsertService")
                                local loadedMesh = InsertService:CreateMeshPartAsync(val, instance.CollisionFidelity, instance.RenderFidelity)
                                instance:ApplyMesh(loadedMesh)
                            end)
                        end
                    elseif propData.name == "MeshContent" and instance:IsA("MeshPart") then
                        if not hasMeshId then
                            pcall(function()
                                local current = instance.MeshContent
                                if current.SourceType == Enum.ContentSourceType.Uri and current.Uri == val.Uri then return end
                                applyMeshContent(instance, val)
                            end)
                        end
                    elseif propData.name == "Source" and instance:IsA("LuaSourceContainer") then
                        pcall(function()
                            if (instance :: any).Source == val then return end
                            --// a script open in the editor has to be changed through the editor, or the edit is lost
                            local editor = game:GetService("ScriptEditorService")
                            if editor:FindScriptDocument(instance) then
                                editor:UpdateSourceAsync(instance, function() return val end)
                            else
                                (instance :: any).Source = val
                            end
                        end)
                        if (instance :: any).Source ~= val then
                            pcall(function() (instance :: any).Source = val end)
                        end
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

    --// The blob is the whole truth about the instance: drop what it no longer has
    local keepAttributes, keepTags, present = {[ROGIT_ID] = true}, {}, {}
    for _, propData in ipairs(props) do
        present[propData.name] = true
        if propData.name == "_attributes" and type(propData.value) == "table" then
            if propData.value[1] ~= nil then
                for _, attrData in ipairs(propData.value) do
                    if type(attrData) == "table" and attrData.name then keepAttributes[attrData.name] = true end
                end
            else
                for attrName in pairs(propData.value) do keepAttributes[attrName] = true end
            end
        elseif propData.name == "_tags" and type(propData.value) == "table" then
            for _, tag in ipairs(propData.value) do keepTags[tag] = true end
        end
    end

    for attrName in pairs(instance:GetAttributes()) do
        if not keepAttributes[attrName] then
            pcall(function() instance:SetAttribute(attrName, nil) end)
        end
    end
    for _, tag in ipairs(instance:GetTags()) do
        if not keepTags[tag] then
            pcall(function() instance:RemoveTag(tag) end)
        end
    end
    for _, name in ipairs(instances.nullable_properties(instance)) do
        if not present[name] then
            pcall(function() instance[name] = nil end)
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
        local entryName = content:sub(spacePos + 1, nullPos - 1)
        --// tree entries use escaped names (see Utilities.escape_name), the instance gets its real name back
        local name = Utilities.unescape_name(entryName)

        local rawSha = content:sub(nullPos + 1, nullPos + 20)
        local sha = ("%02x"):rep(20):format(rawSha:byte(1, 20))
        pos = nullPos + 21

        local entryPath = treePath and (treePath .. "/" .. entryName) or entryName

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
                    local inst = instances.create_instance(className, childProps)
                    if inst then
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
        elseif mode == "160000" then
            Remote.writeGitlink(parent, name, sha)
        else
            local blobObj = objectsBySha[sha]
            if not blobObj then
                continue
            elseif entryName == ".properties" then
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
                    local inst = instances.create_instance(className, props)
                    if not inst then
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
Stores every object from an unpacked pack in the repository.
]]
function Remote.storeObjects(objectsBySha, only)
	local typeNames = {[1] = "commit", [2] = "tree", [3] = "blob", [4] = "tag"}
	local written = 0
	for objSha, obj in pairs(objectsBySha) do
		if not only or only[objSha] then
			local typeName = typeNames[obj.objType]
			if typeName then
				Utilities.roYield()
				_Handlers.write_object_with_sha(typeName, obj.content, objSha)
				written += 1
			end
		end
	end
	return written
end

--[[
Fetches remote based off name.
Downloads everything we don't have yet in a single pack and updates the remote-tracking refs and tags.
Returns the remote refs and the discovery info.
]]
function Remote.fetch(remote_name, quiet, opts)
    opts = opts or {}
    local say = quiet and function() end or function(...) Remote.print(...) end
    say("Fetching " .. remote_name)

    local config_content = bash.getFileContents(bash.getGitFolderRoot(), "config")
    local loaded_conf = ini_parser.parseIni(config_content)

    local section_name = 'remote "' .. remote_name .. '"'
    local remote_section = loaded_conf[section_name]
    assert(remote_section and remote_section.url, "fatal: '" .. remote_name .. "' does not appear to be a git repository")
    
    local url = remote_section.url

    local refs, info = Remote.discoverRefs(url)

    --// only ask for the tips that we do not own yet
    local wants, wantSet = {}, {}
    for name, sha in pairs(refs) do
        if (name:match("^refs/heads/") or name:match("^refs/tags/")) and not name:match("%^{}$") then
            if not wantSet[sha] and not _Handlers.read_object(sha) then
                wantSet[sha] = true
                table.insert(wants, sha)
            end
        end
    end
    table.sort(wants)

    if #wants > 0 then
        local haves, haveSet = {}, {}
        for _, sha in pairs(_Handlers.list_refs()) do
            if not haveSet[sha] and #haves < 64 then
                haveSet[sha] = true
                table.insert(haves, sha)
            end
        end
        table.sort(haves)

        local pack = Remote.fetchPackfile(url, wants, haves)
        local _, objectsBySha = Remote.unpackObjects(pack)
        Remote.storeObjects(objectsBySha)
    end

    local output = { "From " .. url }
    local names = {}
    for name in pairs(refs) do table.insert(names, name) end
    table.sort(names)

    for _, name in ipairs(names) do
        local sha = refs[name]
        local branch_name = name:match("^refs/heads/(.+)")
        local tag_name = name:match("^refs/tags/(.+)")
        if branch_name then
            local trackingRef = "refs/remotes/" .. remote_name .. "/" .. branch_name
            local old = _Handlers.get_ref(trackingRef)
            if old ~= sha then
                if old then
                    table.insert(output, string.format("   %s..%s  %-15s -> %s/%s", old:sub(1, 7), sha:sub(1, 7), branch_name, remote_name, branch_name))
                else
                    table.insert(output, string.format(" * [new branch]      %-15s -> %s/%s", branch_name, remote_name, branch_name))
                end
                _Handlers.update_ref(trackingRef, sha)
            end
        elseif tag_name and not tag_name:match("%^{}$") then
            if _Handlers.get_ref(name) ~= sha then
                table.insert(output, string.format(" * [new tag]         %-15s -> %s", tag_name, tag_name))
                _Handlers.update_ref(name, sha)
            end
        end
    end

    --// --prune: forget remote branches that are gone
    if opts.prune then
        for refName in pairs(_Handlers.list_refs()) do
            local branch = refName:match("^refs/remotes/" .. remote_name:gsub("%p", "%%%0") .. "/(.+)$")
            if branch and branch ~= "HEAD" and not refs["refs/heads/" .. branch] then
                _Handlers.delete_ref(refName)
                table.insert(output, " - [deleted]         (none)     -> " .. remote_name .. "/" .. branch)
            end
        end
    end

    if #output == 1 then
        say("Already up to date.")
    else
        say(table.concat(output, "\n"))
    end

    return refs, info
end

--[[
Writes a root tree into the work tree: each top level entry is a service (or a folder standing in for one).
]]
function Remote.writeRoot(objectsBySha, treeSha)
    local treeObj = objectsBySha[treeSha]
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
            local inPlace = bash.getWorkRoot() == game
            local serviceParent = bash.getServiceRoot(Utilities.unescape_name(name), not inPlace)
            if serviceParent then
                local childProps, propsSha = Remote.peekPropertiesBlob(objectsBySha, sha)
                if inPlace and childProps then
                    Remote.applyProperties(serviceParent, childProps)
                end
                Remote.writeTree(objectsBySha, sha, serviceParent, name)
                if not inPlace then
                    --// a worktree/submodule folder stands in for the service and keeps its properties as they are
                    serviceParent:SetAttribute(instances.SERVICE_BLOB_ATTRIBUTE, propsSha)
                end
            end
        elseif mode ~= "160000" then
            --// a service without children is a single blob
            local inPlace = bash.getWorkRoot() == game
            local serviceParent = bash.getServiceRoot(Utilities.unescape_name(name), not inPlace)
            local blob = serviceParent and objectsBySha[sha]
            if blob then
                if inPlace then
                    local ok, props = pcall(function() return HttpService:JSONDecode(blob.content) end)
                    if ok then Remote.applyProperties(serviceParent, props) end
                else
                    serviceParent:SetAttribute(instances.SERVICE_BLOB_ATTRIBUTE, sha)
                end
            end
        end
    end

end

--[[
Checkout at a certain tree SHA.
]]
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

    Remote.writeRoot(objectsByShaFallback, treeSha)

    Remote.resolve_instance_refs()

    local new_index = Remote.buildIndexFromTree(objectsByShaFallback, treeSha)
    local old_index = _Handlers.read_index()
    
    local to_destroy = {}
    for path, _ in pairs(old_index) do
        if not new_index[path] then
            local clean_path = path:match("^(.-)/%.properties$") or path
            local currObj = Utilities.parse_path(clean_path)
            if currObj and not bash.isProtected(currObj) then
                table.insert(to_destroy, currObj)
            end
        end
    end
    for _, obj in ipairs(to_destroy) do
        pcall(function() obj:Destroy() end)
    end

    _Handlers.write_index(new_index)
    bash.writeFile(bash.getGitFolderRoot(), "last_commit_index", HttpService:JSONEncode(new_index))
    
    return true
end

--[[
Builds the remote index from the tree!
]]
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
