local Handlers = {}

local HttpService = game:GetService("HttpService")

local bash = require(script.Parent.Parent.bash)
local hashlib = require(script.Parent.hashlib)
local zlib = require(script.Parent.zlib)
local git_proto = require(script.Parent.git_proto)
local Utilities = require(script.Parent.utilities)

--// Cache for .rogitignore
local ignore_cache = {}
local ignore_patterns = nil
local objects_dir_cache = {}

--[[
Compresses and writes an object to the .git/objects folder.
]]
function Handlers.write_object(typeName, content)
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

function Handlers.write_object_with_sha(typeName, content, sha)
    local prefix = string.sub(sha, 1, 2)
    local dir = objects_dir_cache[prefix]
    if not dir then
        dir = bash.createFolder(
            bash.getGitFolderRoot(),
            "objects/" .. prefix
        )
        objects_dir_cache[prefix] = dir
    end

    if not dir:FindFirstChild(string.sub(sha, 3)) then
        local header = typeName .. " " .. tostring(#content) .. "\0"
        local full = header .. content
        bash.createFile(
            dir,
            string.sub(sha, 3),
            hashlib.bin_to_base64(zlib.compressZlib(full))
        )
    end

    return sha
end

function Handlers.clear_objects_cache()
    table.clear(objects_dir_cache)
end

--[[ 
Reads an object and decompresses it from the .git/objects folder.
]]
function Handlers.read_object(sha)
    local gitRoot = bash.getGitFolderRoot()
    if not gitRoot then return nil end
    local objsFolder = gitRoot:FindFirstChild("objects")
    if not objsFolder then return nil end
    local dir = objsFolder:FindFirstChild(string.sub(sha, 1, 2))
    if not dir then return nil end

    local raw64 = bash.getFileContents(dir, string.sub(sha, 3))
    if not raw64 then return nil end

    local data = hashlib.base64_to_bin(raw64)
    local raw = pcall(function() return zlib.decompressZlib(data) end) and zlib.decompressZlib(data) or nil
    if not raw then return nil end

    local nullIndex = string.find(raw, "\0", 1, true)
    if not nullIndex then return nil end

    local header = string.sub(raw, 1, nullIndex - 1)
    local content = string.sub(raw, nullIndex + 1)

    local typeName = string.split(header, " ")[1]

    return {type = typeName, content = content}
end

--[[
Writes a serialized instance into a blob object.
]]
function Handlers.write_blob(serializedInstance)
    return Handlers.write_object("blob", serializedInstance)
end

--[[
Reads the .git/index and decodes it into a table.
]]
function Handlers.read_index()
    local raw = bash.getFileContents(bash.getGitFolderRoot(), "index")
    if raw == "" then
        return {}
    end

    return HttpService:JSONDecode(raw)
end

--[[
Encodes the index into JSON format and saves into .git/index
]]
function Handlers.write_index(tbl)
    assert(tbl, "Index table is nil!")

    local encoded = HttpService:JSONEncode(tbl)

    bash.modifyFileContents(
        bash.getGitFolderRoot(),
        "index",
        encoded
    )
end

--[[
Writes a tree object to the .git/objects folder.
]]
function Handlers.write_tree(index)
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
            Utilities.roYield()
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

        return Handlers.write_object("tree", tree_content)
    end
    
    return build_tree_objects(tree_structure)
end

--[[ 
Loads the .rogitignore file and parses it into a table of ignore patterns.
]]
function Handlers.load_ignore_patterns()
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
                local is_glob = string.find(line, "*")
                if is_glob then
                    local p1 = "^" .. string.gsub(line, "([%.%+%-%?%[%]%^%$%(%)])", "%%%1")
                    p1 = string.gsub(p1, "%*", ".*") .. "$"
                    
                    local p2 = "/" .. string.gsub(line, "([%.%+%-%?%[%]%^%$%(%)])", "%%%1")
                    p2 = string.gsub(p2, "%*", ".*") .. "$"
                    
                    table.insert(ignore_patterns, {raw = line, kind = "glob", p1 = p1, p2 = p2})
                else
                    table.insert(ignore_patterns, {raw = line, kind = "exact"})
                end
            end
        end
    end
end

--[[
Checks if a path is ignored by the .rogitignore file.
]]
function Handlers.is_ignored(path)
    if ignore_cache[path] ~= nil then return ignore_cache[path] end
    Handlers.load_ignore_patterns()

    local path_slashes = string.gsub(path, "%.", "/")

    for _, pat in ipairs(ignore_patterns) do
        if pat.kind == "glob" then
            if string.match(path_slashes, pat.p1) then ignore_cache[path] = true; return true end
            if string.match(path_slashes, pat.p2) then ignore_cache[path] = true; return true end
        else
            local pattern = pat.raw
            if path_slashes == pattern then ignore_cache[path] = true; return true end
            if string.sub(path_slashes, 1, #pattern + 1) == pattern .. "/" then ignore_cache[path] = true; return true end
            if string.sub(path_slashes, -#pattern - 1) == "/" .. pattern then ignore_cache[path] = true; return true end
            if string.find(path_slashes, "/" .. pattern .. "/", 1, true) then ignore_cache[path] = true; return true end
        end
    end
    ignore_cache[path] = false
    return false
end

--[[
Collects all objects reachable from the given SHAs.
]]
function Handlers.collectObjects(localSha, remoteSha)
    local objects = {}
    local visited = {}

    local function markReachable(sha)
        if not sha or sha == ("0"):rep(40) or visited[sha] then return end
        visited[sha] = true
        local obj = Handlers.read_object(sha)
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
        Utilities.roYield()
    end

    if remoteSha and remoteSha ~= ("0"):rep(40) then
        markReachable(remoteSha)
    end

    local function addObject(sha)
        if not sha or sha == ("0"):rep(40) or visited[sha] then return end
        visited[sha] = true
        local obj = Handlers.read_object(sha)
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
        Utilities.roYield()
    end

    addObject(localSha)
    return objects
end

--[[
Compiles the packfile based on objects.
]]
function Handlers.buildPackfile(objects)
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
            Utilities.roYield()
        end
    end

    local packData = "PACK"
    .. git_proto.writeU32BE(2)
    .. git_proto.writeU32BE(count)
    .. table.concat(entries)

    local checksum = hashlib.hex_to_bin(hashlib.sha1(packData))
    return packData .. checksum
end

--[[
Gets the ref from the .git/refs folder.
]]
function Handlers.get_ref(ref_path)
    local file = bash.getDirectoryOrFile(bash.getGitFolderRoot(), ref_path)
    if not file then return nil end

    local content = bash.getFileContents(file.Parent, file.Name)
    if content and string.sub(content, 1, 5) == "ref: " then
        return Handlers.get_ref(string.sub(content, 6))
    else
        return content
    end
end

--[[
Updates the ref.
]]
function Handlers.update_ref(ref_path, sha)
    local function do_update(full_path, sha_content)
        local segments = string.split(full_path, "/")
        local filename = table.remove(segments)
        
        local parent_folder = bash.getGitFolderRoot()
        if #segments > 0 then
            local dir_path = table.concat(segments, "/")
            parent_folder = bash.createFolder(parent_folder, dir_path)
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

--[[
Retrieves the current branch.
]]
function Handlers.get_current_branch()
    local root = bash.getGitFolderRoot()
    if not root then return nil end
    local head = bash.getFileContents(root, "HEAD")
    if not head then return nil end
    return head:match("ref: refs/heads/(.+)")
end

--[[
Retrieves the source of any script, split by newlines.
]]
function Handlers.get_content_lines(sha)
    if not sha then return 0 end

    local blob = Handlers.read_object(sha)
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

return Handlers