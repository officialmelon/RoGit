local git = {}

local HttpService = game:GetService("HttpService")
local ScriptRegistrationService = game:GetService("ScriptRegistrationService")
local Workspace = game:GetService("Workspace")

local config = require(script.Parent.config)
local arguments = require(script.Parent.arguments)

local hashlib = require(script.Parent.libs.hashlib)
local zlib = require(script.Parent.libs.zlib)
local bash = require(script.Parent.bash)
local git_proto = require(script.Parent.libs.git_proto)

local ignore_patterns = nil

local TYPE_NAMES = {[1]="Commit", [2]="Tree", [3]="Blob", [4]="Tag", [6]="OFS-Delta", [7]="Ref-Delta"}

--[[
Utilities

warn_assert
warns instead of asserting.

calculate_hash
calculates the hash of a instance based off properties.

]]

-- (https://devforum.roblox.com/t/how-to-save-parts-and-the-idea-of-serialization/524311)
local function serialize_property(prop)

    -- quick check
    assert(prop, "No property parsed to serialize!")

    local type = typeof(prop)
    local r = prop

    -- Serialize prop to string.
    if type == "BrickColor" then

        r = tostring(prop)
    elseif type == "CFrame" then

        r = {pos = serialize_property(prop.Position), rX = serialize_property(prop.rightVector), rY = serialize_property(prop.upVector), rZ = serialize_property(-prop.lookVector)}
    elseif type == "Vector3" then

        r = {X = prop.X, Y = prop.Y, Z = prop.Z}
    elseif type == "Color3" then

        r = {Color3.toHSV(prop)}
    elseif type == "EnumItem" then

        r = {string.split(tostring(prop), ".")[2], string.split(tostring(prop), ".")[3]} 
    end

    return r
end

local function deserialize_property(prop, propType)
    if propType == "BrickColor" then
        return BrickColor.new(prop)
    elseif propType == "CFrame" then
        local pos = Vector3.new(prop.pos.X, prop.pos.Y, prop.pos.Z)
        local rX = Vector3.new(prop.rX.X, prop.rX.Y, prop.rX.Z)
        local rY = Vector3.new(prop.rY.X, prop.rY.Y, prop.rY.Z)
        local rZ = Vector3.new(prop.rZ.X, prop.rZ.Y, prop.rZ.Z)
        return CFrame.fromMatrix(pos, rX, rY, -rZ)
    elseif propType == "Vector3" then
        return Vector3.new(prop.X, prop.Y, prop.Z)
    elseif propType == "Color3" then
        return Color3.fromHSV(prop[1], prop[2], prop[3])
    elseif propType == "EnumItem" then
        return Enum[prop[1]][prop[2]]
    end
    return prop
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
            zlib.compressZlib(full)
        )
    end

    return sha
end

local function read_object(sha)
    local dir = bash.getGitFolderRoot().objects[string.sub(sha, 1, 2)]
    if not dir then return nil end

    local data = bash.getFileContents(dir, string.sub(sha, 3))
    if not data then return nil end

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
    
        -- Pcall because if a property doesnt exist, it will error out.
        pcall(function ()
    
            -- if instance exists, then we add to table and set value
            if instance[property.Name] then 
                table.insert(instanceProperties, {
                    name = property.Name,
                    value = instance[property.Name],
                    valueType = typeof(instance[property.Name])
                })
            end
    
        end)
    end
    
    -- We must serialize all properties before attempting to 
    for _, instanceProp in instanceProperties do 
        if instanceProp.value then 
            instanceProp.value = serialize_property(instanceProp.value)
        end
    end

    return HttpService:JSONEncode(instanceProperties)
end

local function calculate_hash(instance)
    -- Check instance exists
    assert(typeof(instance) == "Instance", "no instance passed or instance is not a instance")

    -- serialize the instance itself
    local serializedData = serialize_instance(instance)

    -- calculate the hash and return based off serialized data
    return hashlib.sha1(serializedData)
end

local function warn_assert(condition, message)
    -- Check for message
    assert(message, "no message supplied to warn!")

    if not condition then 
        warn(message)        
    end

    return
end

local function stage_instance(instance, index)
    local fullPath = instance:GetFullName()

    local serialized = serialize_instance(instance)
    local blobSha = write_blob(serialized)

    index[fullPath] = {
        mode = "100644",
        sha = blobSha
    }
end

local function load_ignore_patterns()
    if ignore_patterns ~= nil then
        return
    end

    ignore_patterns = {}
    local ignore_file = bash.getGitFolderRoot().Parent:FindFirstChild(".rogitignore")
    if ignore_file then
        local content = ignore_file.Value
        for line in string.gmatch(content, "[^\r\n]+") do
            if string.sub(line, 1, 1) ~= "#" and #line > 0 then
                table.insert(ignore_patterns, line)
            end
        end
    end
end

local function is_ignored(path)
    load_ignore_patterns()

    for _, pattern in ipairs(ignore_patterns) do
        if string.sub(path, 1, #pattern) == pattern then
            return true
        end
    end
    return false
end

local function stage_recursive(instance, index)
    if is_ignored(instance:GetFullName()) then return end

    stage_instance(instance, index)

    for _, child in ipairs(instance:GetChildren()) do
        if not child:IsDescendantOf(bash.getGitFolderRoot()) then
            stage_recursive(child, index)
        end
    end
end

local function write_tree(index)
    local tree_structure = {}
    
    for path, data in pairs(index) do 
        local segments = string.split(path, ".")
        local current_level = tree_structure
        for i=1, #segments - 1 do 
            local segment = segments[i]
            current_level[segment] = current_level[segment] or {}
            current_level = current_level[segment]
        end
        current_level[segments[#segments]] = {
            type = "blob",
            sha = data.sha,
            mode = data.mode
        }
    end

    local function build_tree_objects(structure)
        local tree_content = ""
        local entries = {}

        for name, item in pairs(structure) do
            table.insert(entries, {name=name, item=item})
        end

        for _, entry in entries do
            local name = entry.name
            local item = entry.item
            local sha
            local type

            if item.type == "blob" then
                sha=item.sha
                type = "blob"
                tree_content = tree_content .. string.format("%s %s\0%s", item.mode, name, hashlib.hex_to_bin(sha))
            else
                sha = build_tree_objects(item)
                type = "tree"
                tree_content = tree_content .. string.format("40000 %s\0%s", name, hashlib.hex_to_bin(sha))
            end
        end

        return write_object("tree", tree_content)
    end
    
    return build_tree_objects(tree_structure)
end

local function get_ref(ref_path)
    local content = bash.getFileContents(bash.getGitFolderRoot(), ref_path)
    if not content then return nil end

    if string.sub(content, 1, 5) == "ref: " then -- sym ref
        return get_ref(string.sub(content, 6))
    else -- sha
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
        if file and file:IsA("StringValue") then
            return file.Value
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

local function return_urls(url: string)
    return {url .. "/info/refs?service=git-upload-pack", url .. "/git-upload-pack"}
end

local function discoverRefs(url: string)
	local ok, res = pcall(function()
        return HttpService:RequestAsync({
            Url = return_urls(url)[1],
            Method = "GET",
        })
    end)

	assert(ok, res)
	assert(res.StatusCode == 200, "Discovery failed: " .. res.StatusCode)

	local buf = buffer.fromstring(res.Body)
	local cursor = 0
	local headSha = nil

	while cursor < buffer.len(buf) do
		local data, next = git_proto.decodePkt(buf, cursor)
		cursor = next
		if data then
			local sha, name = git_proto.parseRef(data)
			if sha and not headSha then
				headSha = sha
			end
		end
	end

	assert(headSha, "Could not find HEAD sha in discovery response")
	return headSha
end

local function fetchPackfile(url: string, sha: string)
	local wantPkt = git_proto.encodePkt(buffer.fromstring("want " .. sha .. " side-band-64k ofs-delta\n"))
	local donePkt = git_proto.encodePkt(buffer.fromstring("done\n"))
	local body = buffer.tostring(wantPkt) .. buffer.tostring(git_proto.flush()) .. buffer.tostring(donePkt)

	local res = HttpService:RequestAsync({
		Url = return_urls(url)[2],
		Method = "POST",
		Headers = {
			["Content-Type"] = "application/x-git-upload-pack-request",
			["Accept"] = "application/x-git-upload-pack-result",
		},
		Body = body,
	})
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
				print("remote:", buffer.tostring(data):gsub("[\r\n]+", ""))
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

	for i = 1, objCount do
		local objOffset = cursor
		local objType, size, next = git_proto.parseObjectHeader(fullPack, cursor)
		cursor = next

		local baseOffset, baseSha

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
			cursor += 20
			baseSha = buffer.tostring(shaBytes)
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
		else
			resolved = decompressed
			actualType = objType
		end

		objectsByOffset[objOffset] = resolved
		typesByOffset[objOffset] = actualType
		parsedCount += 1

		cursor += #buffer.tostring(slice) - (bytesLeft or 0)

		local typePrefix = ({[1]="commit",[2]="tree",[3]="blob",[4]="tag"})[actualType]
		if typePrefix and resolved then
			local header = typePrefix .. " " .. #resolved .. "\0"
			local sha = hashlib.sha1(header .. resolved)
			objectsBySha[sha] = {objType = actualType, content = resolved}
		end

		print(string.format("[%d] %s | size: %d%s",
			i,
			TYPE_NAMES[objType] or "Unknown",
			resolved and #resolved or 0,
			baseOffset and " | base: +" .. baseOffset or ""
		))
	end

	return objectsByOffset, objectsBySha
end

local function writeTree(objectsBySha, treeSha, parent)
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

        if mode == "40000" then
            local folder = bash.createFolder(parent, name)
            writeTree(objectsBySha, sha, folder)
        else
            local blobObj = objectsBySha[sha]
            if blobObj then
                local ok, err = pcall(bash.createFile, parent, name, blobObj.content)
                if not ok then
                    warn("Skipped " .. name .. ": " .. tostring(err))
                end
            end
        end
    end
end


--[[
Commands:
version
v

Outputs the version to the console.
]]
arguments.createArgument("version", "v", function ()
    print(config.version)
end)

--[[
Commands:
help
h

Outputs all possible commands.
TODO: Implement descriptions
]]
arguments.createArgument("help", "h", function ()
    for _, arg in arguments.returnAllArguments() do 
        print(arg.main_arg)
    end
end)

--[[
Commands:
add
a

Adds files to be commited
]]

arguments.createArgument("add", "a", function (...)
    assert(bash.getGitFolderRoot(),
        "fatal: not a git repository (or any of the parent directories): .git")

    local args = {...}
    warn_assert(#args > 0,
        "hint: Maybe you wanted to say 'git add .'?")

    local target = args[1]
    
    if target == "." then
        -- start with a fresh index for 'add .' to correctly capture deletions
        local index = {} 
        for _, service in ipairs(bash.trackingRoot) do
            for _, obj in ipairs(service:GetDescendants()) do
                if not obj:IsDescendantOf(bash.getGitFolderRoot()) and not is_ignored(obj:GetFullName()) then
                    stage_instance(obj, index)
                end
            end
        end
        write_index(index)
        return
    end

    -- for specific adds, we add to the existing index
    local index = read_index()

    local segments = string.split(target, ".")
    local currObj = game

    for _, segment in ipairs(segments) do
        if currObj and currObj:FindFirstChild(segment) then
            currObj = currObj:FindFirstChild(segment)
        else
            currObj = nil
            break
        end
    end

    assert(currObj,
        "fatal: pathspec '" .. target .. "' did not match any files")

    -- stage la object + children 
    stage_recursive(currObj, index)

    write_index(index)
end)


--[[
commands:
pull

pulls latest commit.
]]

arguments.createArgument("pull", "", function (...)
    -- Check if not initialized
    assert(bash.getGitFolderRoot(), "fatal: not a git repository (or any of the parent directories): .git")

    local packed = {...}

    local index = bash.getFileContents(bash.getGitFolderRoot(), "index") -- get index
    local split_index = string.split(index, "\n") -- split by newline
    split_index[1] = nil -- first index is nil since its a blank space. hence removing

    -- loop through index
    for _, ind in split_index do 
        local hash = string.split(ind, " ")[1] -- split by space
        local fullName = string.split(string.split(ind, " ")[2], ".") -- split by space, then by .

        print(hash)
        print(fullName)

        local currObj = game
        for i = 1, #fullName - 1 do
            local path = fullName[i]
            if currObj and currObj:FindFirstChild(path) then 
                currObj = currObj:FindFirstChild(path)
            end
        end

        local hashFile = bash.getFileContents(bash.getGitFolderRoot().objects[string.sub(hash, 1, 2)], string.sub(hash, 3))

        local decomp = zlib.decompressZlib(hashFile)
        if decomp then
            local success, out = pcall(function ()
                local props = HttpService:JSONDecode(decomp)
                local class
                for _, prop in props do
                    if prop.name == "ClassName" then 
                        class = prop.value
                    end
                end
                local obj = Instance.new(class)
                for _, prop in props do
                    if prop.name ~= "Parent" and prop.name ~= "ClassName" then
                        pcall(function ()
                            obj[prop.name] = deserialize_property(prop.value, prop.valueType)
                        end)
                    end
                end
                obj.Parent = currObj
            end)
            print(success, out)
        end
    end
end)

arguments.createArgument("rm", "", function (...)
    local tuple = {...}
    local is_cached = false
    local path_to_remove

    -- basic arg parsing
    if tuple[1] == "--cached" then
        is_cached = true
        path_to_remove = tuple[2]
    else
        path_to_remove = tuple[1]
    end

    assert(path_to_remove, "fatal: no path specified")

    local index = read_index()

    if not index[path_to_remove] then
        warn("fatal: pathspec '" .. path_to_remove .. "' did not match any files")
        return
    end

    -- remove from index
    index[path_to_remove] = nil
    write_index(index)

    if not is_cached then
        -- also remove from workspace
        local segments = string.split(path_to_remove, ".")
        local currObj = game
        for _, segment in ipairs(segments) do
            if currObj and currObj:FindFirstChild(segment) then
                currObj = currObj:FindFirstChild(segment)
            else
                currObj = nil
                break
            end
        end
        if currObj and currObj ~= game then
            currObj:Destroy()
        end
    end

    print("rm '" .. path_to_remove .. "'")
end)

arguments.createArgument("commit", "", function(...)
    local tuple = { ... }
    local message = ""

    if tuple[1] == "-m" and tuple[2] then
        message = tuple[2]:gsub('"', '')
    else
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
    
    local parent_sha = get_ref("HEAD")
    local tree_sha = write_tree(index)
    local commit_content = "tree " .. tree_sha .. "\n"
    if parent_sha and parent_sha ~= "" then
        commit_content = commit_content .. "parent " .. parent_sha .. "\n"
    end
    local timestamp = os.time()
    commit_content = commit_content .. string.format("author roGit <ro-git@example.com> %d +0000\n", timestamp)
    commit_content = commit_content .. string.format("committer roGit <ro-git@example.com> %d +0000\n", timestamp)
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

    local num_files_changed = #files_added + #files_deleted + #files_modified + #files_renamed
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

arguments.createArgument("init", "", function (...)
    -- Create .git if not existing already.

    local tuple = {...}

    local quiet  -- if enabled, no output
    local obj_format = "sha1" -- sha1, sha256
    local b -- branch
    

    local reinit_required = false

    local root = bash.getGitFolderRoot()
    if not bash.getGitFolderRoot() then 
        root = bash.createGitFolderRoot()
        warn("Initialized empty Git repository")
    else 
        -- reinit required?
        warn("Reinitialized existing Git repository in " .. game.Name)
        reinit_required = true
    end

    -- Create folders required
    local hooks = bash.createFolder(root, "hooks")
    local info = bash.createFolder(root, "info")

    bash.createFolder(root, "objects/info")
    bash.createFolder(root, "objects/pack")

    bash.createFolder(root, "refs/heads")
    bash.createFolder(root, "refs/tags")

    -- Create files required
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
    bash.createFile(root, "HEAD", "ref: refs/heads/master")

    bash.createFile(info, "exclude", [[
    # git ls-files --others --exclude-from=.git/info/exclude
    # Lines that start with '#' are comments.
    # For a project mostly in C, the following would be a good set of
    # exclude patterns (uncomment them if you want to use them):
    # *.[oa]
    # *~
    ]])

    -- this file is usually created at runtime (e.g. during add operations) however its much easier to just create it here.
    bash.createFile(bash.getGitFolderRoot(), "index", "")
    bash.createFile(bash.getGitFolderRoot().Parent, ".rogitignore", "# Instances to ignore in ro-git\n")
    
end)

--[[
commands:
clone

clones a git repository
]]

function download(url, name, parent)
    local sc = Instance.new("StringValue")
    sc.Parent = parent 
    sc.Name = name
    local req = HttpService:RequestAsync({
        Url = url
    })
    sc.Value = req.Body
end

function recursive_download(body, parent)
    for _, file in body do
        if not file.download_url and file.url then --// Is a folder 
        
            local req = HttpService:RequestAsync({
                Url = file.url
            })

            bash.createFolder(parent, file.path)
            
            recursive_download(HttpService:JSONDecode(req.Body), parent)
        else 
            print("Cloning:", file.path, "Size:", file.size)
            download(file.download_url, file.name, bash.getDirectoryOrFile(parent, file.path))
        end
    end
end

arguments.createArgument("clone", "", function(...)
    assert((#{...} >= 1), "No argument supplied!")
    local url = (...):gsub("%.git$", "")

    local repoName = url:match("/([^/]+)$")
    print("Cloning into '" .. repoName .. "'...")

    local headSha = discoverRefs(url .. ".git")
    local fullPack = fetchPackfile(url .. ".git", headSha)
    local _, objectsBySha = unpackObjects(fullPack)

    local headCommit = objectsBySha[headSha]
    assert(headCommit, "HEAD commit not found in packfile")

    local treeSha = headCommit.content:match("^tree (%x+)")
    assert(treeSha, "Could not parse tree SHA from commit")

    local parent = bash.createFolder(workspace, repoName)
    writeTree(objectsBySha, treeSha, parent)

    print("Done. '" .. repoName .. "' cloned.")
end)

return git