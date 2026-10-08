local Handlers = {}

local HttpService = game:GetService("HttpService")

local bash = require(script.Parent.Parent.bash)
local hashlib = require(script.Parent.hashlib)
local zlib = require(script.Parent.zlib)
local git_proto = require(script.Parent.git_proto)
local Utilities = require(script.Parent.utilities)
local Auth = require(script.Parent.localstore)

--// Cache for .rogitignore
local ignore_cache = {}
local ignore_patterns = nil
local objects_dir_cache = {}

--// Objects are immutable (addressed by their hash), so both of these caches are always safe.
--// The sha cache avoids re-hashing identical content, which is by far the most expensive part of `status`.
local SHA_CACHE_BYTES = 64 * 1024 * 1024
local sha_cache = {}
local sha_cache_bytes = 0

local OBJECT_CACHE_BYTES = 24 * 1024 * 1024
local object_cache = {}
local object_cache_bytes = 0

--[[
Hashes a git object (`<type> <len>\0<content>`) with caching.
]]
function Handlers.hash_object(typeName, content)
    local perType = sha_cache[typeName]
    if not perType then
        perType = {}
        sha_cache[typeName] = perType
    end

    local sha = perType[content]
    if sha then return sha end

    sha = hashlib.sha1(typeName .. " " .. tostring(#content) .. "\0" .. content)

    local size = #content
    if size <= SHA_CACHE_BYTES / 8 then
        if sha_cache_bytes + size > SHA_CACHE_BYTES then
            table.clear(sha_cache)
            sha_cache_bytes = 0
            perType = {}
            sha_cache[typeName] = perType
        end
        perType[content] = sha
        sha_cache_bytes += size
    end
    return sha
end

--[[
Computes the blob sha of a serialized instance.
]]
function Handlers.blob_sha(content)
    return Handlers.hash_object("blob", content)
end

local function remember_object(sha, obj)
    local size = #obj.content
    if size > OBJECT_CACHE_BYTES / 8 then return end
    if object_cache_bytes + size > OBJECT_CACHE_BYTES then
        table.clear(object_cache)
        object_cache_bytes = 0
    end
    object_cache[sha] = obj
    object_cache_bytes += size
end

--[[
Compresses and writes an object to the .git/objects folder.
]]
function Handlers.write_object(typeName, content)
    local sha = Handlers.hash_object(typeName, content)

    local prefix = string.sub(sha, 1, 2)
    local dir = objects_dir_cache[prefix]
    if not dir or not dir.Parent then
        dir = bash.createFolder(
            bash.getObjectsRoot(),
            "objects/" .. prefix
        )
        objects_dir_cache[prefix] = dir
    end

    if not dir:FindFirstChild(string.sub(sha, 3)) then
        local full = typeName .. " " .. tostring(#content) .. "\0" .. content
        bash.createFile(
            dir,
            string.sub(sha, 3),
            hashlib.bin_to_base64(zlib.compressZlib(full))
        )
    end

    --// whatever we just wrote is very likely to be read right back (commit stats, tree walks)
    if not object_cache[sha] then
        remember_object(sha, {type = typeName, content = content})
    end

    return sha
end

--[[
Writes an object to the .git/objects folder with a specified SHA.
]]
function Handlers.write_object_with_sha(typeName, content, sha)
    local prefix = string.sub(sha, 1, 2)
    local dir = objects_dir_cache[prefix]
    if not dir or not dir.Parent then
        dir = bash.createFolder(
            bash.getObjectsRoot(),
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

--[[
self explanatory: Clears the object cache.
]]
function Handlers.clear_objects_cache()
    table.clear(objects_dir_cache)
    table.clear(object_cache)
    object_cache_bytes = 0
end

--[[ 
Reads an object and decompresses it from the .git/objects folder.
]]
function Handlers.read_object(sha)
    if type(sha) ~= "string" or #sha < 3 then return nil end

    local cached = object_cache[sha]
    if cached then return cached end

    local gitRoot = bash.getObjectsRoot()
    if not gitRoot then return nil end
    local objsFolder = gitRoot:FindFirstChild("objects")
    if not objsFolder then return nil end
    local dir = objsFolder:FindFirstChild(string.sub(sha, 1, 2))
    if not dir then return nil end

    local raw64 = bash.getFileContents(dir, string.sub(sha, 3))
    if not raw64 then return nil end

    local data = hashlib.base64_to_bin(raw64)
    local ok, raw = pcall(zlib.decompressZlib, data)
    if not ok or not raw then return nil end

    local nullIndex = string.find(raw, "\0", 1, true)
    if not nullIndex then return nil end

    local header = string.sub(raw, 1, nullIndex - 1)
    local content = string.sub(raw, nullIndex + 1)

    local typeName = string.split(header, " ")[1]

    local obj = {type = typeName, content = content}
    remember_object(sha, obj)
    return obj
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
The file is re-read whenever its content changed, so edits apply without restarting Studio.
]]
local ignore_source = nil

function Handlers.load_ignore_patterns()
    local content = ""
    local storage = bash.getServiceRoot("ServerStorage")
    if storage then
        content = bash.getFileContents(storage, ".rogitignore") or ""
    end

    if ignore_patterns ~= nil and content == ignore_source then
        return
    end

    ignore_source = content
    ignore_patterns = {}
    table.clear(ignore_cache)

    for line in string.gmatch(content, "[^\r\n]+") do
        line = string.match(line, "^%s*(.-)%s*$")
        if string.sub(line, 1, 1) ~= "#" and #line > 0 then
            local is_glob = string.find(line, "*", 1, true)
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

--// another repository (worktree/submodule) can have its own .rogitignore
bash.onContextChanged(function()
    ignore_patterns = nil
    table.clear(ignore_cache)
end)

--[[
Whether an instance is outside the work tree: the .git folder, other worktrees, or matched by .rogitignore.
]]
function Handlers.is_ignored_instance(instance)
    return bash.isInternal(instance) or Handlers.is_ignored(bash.relativeName(instance))
end

--[[
Checks if a path is ignored by the .rogitignore file.
]]
function Handlers.is_ignored(path)
    if ignore_cache[path] ~= nil then return ignore_cache[path] end
    if ignore_patterns == nil then Handlers.load_ignore_patterns() end

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
Collects all objects reachable from `localSha` that aren't already reachable from `remoteSha`
(a sha, or a list of shas the server is known to have).
]]
function Handlers.collectObjects(localSha, remoteSha)
    local objects = {}
    local visited = {}
    local ZERO = ("0"):rep(40)

    --// Walks everything reachable from the roots with an explicit stack (histories can be very deep).
    local function walk(roots, collect)
        local stack = {}
        for _, sha in ipairs(roots) do
            table.insert(stack, sha)
        end

        while #stack > 0 do
            local sha = table.remove(stack)
            if sha and sha ~= ZERO and not visited[sha] then
                visited[sha] = true
                local obj = Handlers.read_object(sha)
                if obj then
                    if collect then
                        objects[sha] = {type = obj.type, content = obj.content}
                    end

                    if obj.type == "commit" then
                        local treeSha = obj.content:match("^tree (%x+)")
                        if treeSha then table.insert(stack, treeSha) end
                        for parent in obj.content:gmatch("\nparent (%x+)") do
                            table.insert(stack, parent)
                        end
                    elseif obj.type == "tag" then
                        local target = obj.content:match("^object (%x+)")
                        if target then table.insert(stack, target) end
                    elseif obj.type == "tree" then
                        for _, entry in ipairs(Handlers.parse_tree(obj.content)) do
                            --// a gitlink names a commit of another repository (a submodule), never sent along
                            if entry.mode ~= "160000" then
                                table.insert(stack, entry.sha)
                            end
                        end
                    end
                    Utilities.roYield()
                end
            end
        end
    end

    if type(remoteSha) == "table" then
        walk(remoteSha, false)
    elseif remoteSha and remoteSha ~= ZERO then
        walk({remoteSha}, false)
    end

    walk({localSha}, true)
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
Deletes a ref file (e.g. a branch or tag). Returns true if something was removed.
]]
function Handlers.delete_ref(ref_path)
    local root = bash.getGitFolderRoot()
    local file = root and bash.getDirectoryOrFile(root, ref_path)
    if file then
        file:Destroy()
        return true
    end
    return false
end

--[[
Updates the ref.
]]
local ZERO_SHA = ("0"):rep(40)

local function write_git_file(full_path, content)
    local segments = string.split(full_path, "/")
    local filename = table.remove(segments)

    local parent_folder = bash.resolveGitParent(bash.getGitFolderRoot(), full_path)
    if #segments > 0 then
        parent_folder = bash.createFolder(parent_folder, table.concat(segments, "/"))
    end
    bash.writeFile(parent_folder, filename, content)
end

local function read_git_file(path)
    local root = bash.getGitFolderRoot()
    local file = root and bash.getDirectoryOrFile(root, path)
    if file then
        return bash.getFileContents(file.Parent, file.Name)
    end
    return nil
end

--[[
Appends an entry to a reflog (.git/logs/<ref>), in git's own format.
]]
function Handlers.append_reflog(ref_path, old_sha, new_sha, message)
    if not ref_path:match("^HEAD$") and not ref_path:match("^refs/heads/") and not ref_path:match("^refs/stash$") then
        return
    end
    local name = Auth.getConfigValue("user_name") or "roGit"
    local email = Auth.getConfigValue("user_email") or "ro-git@example.com"
    local line = string.format("%s %s %s <%s> %d +0000\t%s\n",
        (old_sha and old_sha ~= "") and old_sha or ZERO_SHA, new_sha, name, email, os.time(), (message or "update"):gsub("\n.*", ""))
    write_git_file("logs/" .. ref_path, (read_git_file("logs/" .. ref_path) or "") .. line)
end

--[[
Reads a reflog, newest entry first: {{old, new, message}}.
]]
function Handlers.read_reflog(ref_path)
    local entries = {}
    local content = read_git_file("logs/" .. ref_path) or ""
    for line in content:gmatch("[^\n]+") do
        local old, new, rest = line:match("^(%x+) (%x+) (.*)$")
        if old then
            table.insert(entries, 1, {old = old, new = new, message = rest:match("\t(.*)$") or ""})
        end
    end
    return entries
end

--[[
Updates the ref (following HEAD to the branch it points at) and records it in the reflogs.
]]
function Handlers.update_ref(ref_path, sha, message)
    local content = read_git_file(ref_path)

    if content and string.sub(content, 1, 5) == "ref: " then
        local symbolic_path = string.sub(content, 6)
        local old = read_git_file(symbolic_path)
        write_git_file(symbolic_path, sha)
        Handlers.append_reflog(symbolic_path, old, sha, message)
        Handlers.append_reflog(ref_path, old, sha, message)
    else
        write_git_file(ref_path, sha)
        Handlers.append_reflog(ref_path, content, sha, message)
    end
end

--[[
Points HEAD at a branch ("refs/heads/main") or a commit (detached), logging it like git checkout does.
]]
function Handlers.set_head(target, message)
    local old = Handlers.get_ref("HEAD")
    if target:match("^refs/") then
        write_git_file("HEAD", "ref: " .. target)
    else
        write_git_file("HEAD", target)
    end
    local new = Handlers.get_ref("HEAD")
    if new and new ~= "" then
        Handlers.append_reflog("HEAD", old, new, message)
    end
end

--[[
Parses a raw tree object into a list of {mode, name, sha}.
]]
function Handlers.parse_tree(content)
    local entries = {}
    local pos = 1
    local len = #content
    while pos <= len do
        local spacePos = string.find(content, " ", pos, true)
        local nullPos = spacePos and string.find(content, "\0", spacePos, true)
        if not nullPos then break end
        local rawSha = string.sub(content, nullPos + 1, nullPos + 20)
        entries[#entries + 1] = {
            mode = string.sub(content, pos, spacePos - 1),
            name = string.sub(content, spacePos + 1, nullPos - 1),
            sha = ("%02x"):rep(20):format(rawSha:byte(1, 20)),
        }
        pos = nullPos + 21
    end
    return entries
end

--[[
Flattens a tree into an index ({path = {sha, mode}}).
]]
function Handlers.tree_to_index(tree_sha)
    local index = {}
    local function walk(sha, prefix)
        local obj = Handlers.read_object(sha)
        if not obj or obj.type ~= "tree" then return end
        for _, entry in ipairs(Handlers.parse_tree(obj.content)) do
            Utilities.roYield()
            local path = prefix == "" and entry.name or (prefix .. "/" .. entry.name)
            if entry.mode == "40000" then
                walk(entry.sha, path)
            else
                index[path] = {sha = entry.sha, mode = entry.mode}
            end
        end
    end
    walk(tree_sha, "")
    return index
end

--[[
Reads the interesting parts of a commit: its tree, parents and message.
]]
function Handlers.read_commit(sha)
    local obj = sha and Handlers.read_object(sha)
    if not obj or obj.type ~= "commit" then return nil end

    local headers, message = obj.content:match("^(.-)\n\n(.*)$")
    headers = headers or obj.content

    local parents = {}
    for parent in headers:gmatch("\nparent (%x+)") do
        table.insert(parents, parent)
    end

    return {
        tree = headers:match("^tree (%x+)"),
        parents = parents,
        author = headers:match("\nauthor ([^\n]+)"),
        committer = headers:match("\ncommitter ([^\n]+)"),
        message = message or "",
    }
end

--[[
Returns a set of every commit reachable from `sha` (including itself).
]]
function Handlers.ancestors(sha)
    local seen = {}
    local queue = {sha}
    local cursor = 1
    while cursor <= #queue do
        local current = queue[cursor]
        cursor += 1
        if not seen[current] then
            seen[current] = true
            local commit = Handlers.read_commit(current)
            if commit then
                for _, parent in ipairs(commit.parents) do
                    table.insert(queue, parent)
                end
            end
            Utilities.roYield()
        end
    end
    return seen
end

--[[
Finds the best common ancestor of two commits (nil for unrelated histories).
]]
function Handlers.merge_base(a, b)
    local ancestorsOfA = Handlers.ancestors(a)
    local queue = {b}
    local cursor = 1
    local visited = {}
    while cursor <= #queue do
        local current = queue[cursor]
        cursor += 1
        if not visited[current] then
            visited[current] = true
            if ancestorsOfA[current] then
                return current
            end
            local commit = Handlers.read_commit(current)
            if commit then
                for _, parent in ipairs(commit.parents) do
                    table.insert(queue, parent)
                end
            end
            Utilities.roYield()
        end
    end
    return nil
end

--[[
Resolves a revision (branch, tag, remote branch, full or abbreviated sha, HEAD) to a full commit sha.
]]
function Handlers.resolve_revision(rev)
    if not rev or rev == "" then return nil end
    if rev == "@" then rev = "HEAD" end

    --// peeling: v1.0^{} / HEAD^{commit} (the commit), HEAD^{tree} (its tree)
    local peeled, kind = rev:match("^(.-)%^{(%a*)}$")
    if peeled then
        local sha = Handlers.resolve_revision(peeled)
        if kind == "tree" then
            local commit = sha and Handlers.read_commit(sha)
            return commit and commit.tree or nil
        end
        return sha
    end
    rev = rev:gsub("^@{", "HEAD@{")

    --// reflog / upstream suffixes: HEAD@{2}, main@{1}, main@{upstream}, @{u}
    local refName, selector, rest = rev:match("^([^@]*)@{([^}]*)}(.*)$")
    if refName then
        if refName == "" then refName = "HEAD" end
        local sha
        if selector == "u" or selector == "upstream" or selector == "push" then
            local branch = refName == "HEAD" and Handlers.get_current_branch() or refName
            sha = branch and Handlers.get_ref("refs/remotes/origin/" .. branch)
        else
            local n = tonumber(selector)
            if not n then return nil end
            local logRef = refName == "HEAD" and "HEAD" or ("refs/heads/" .. refName)
            local entry = Handlers.read_reflog(logRef)[n + 1]
            sha = entry and entry.new
        end
        if not sha then return nil end
        if rest ~= "" then
            return Handlers.resolve_revision(sha .. rest)
        end
        return sha
    end

    --// HEAD~2, main^, v1.0~1^2 ...
    local base, modifiers = rev:match("^([^~^]+)([~^].*)$")
    if base then
        local sha = Handlers.resolve_revision(base)
        for kind, count in modifiers:gmatch("([~^])(%d*)") do
            if not sha then return nil end
            local commit = Handlers.read_commit(sha)
            if not commit then return nil end
            if kind == "~" then
                for _ = 1, (count == "" and 1 or tonumber(count)) do
                    commit = Handlers.read_commit(sha)
                    sha = commit and commit.parents[1]
                    if not sha then return nil end
                end
            else
                local n = count == "" and 1 or tonumber(count)
                if n > 0 then
                    sha = commit.parents[n]
                end
            end
        end
        return sha
    end

    if rev == "HEAD" then
        local head = Handlers.get_ref("HEAD")
        return head ~= "" and head or nil
    end

    for _, candidate in ipairs({
        rev,
        "refs/heads/" .. rev,
        "refs/tags/" .. rev,
        "refs/remotes/" .. rev,
        "refs/remotes/origin/" .. rev,
    }) do
        local sha = Handlers.get_ref(candidate)
        if sha and #sha == 40 then
            --// annotated tags point at a tag object, peel to the commit
            local obj = Handlers.read_object(sha)
            local guard = 0
            while obj and obj.type == "tag" and guard < 5 do
                sha = obj.content:match("^object (%x+)") or sha
                obj = Handlers.read_object(sha)
                guard += 1
            end
            return sha
        end
    end

    if #rev >= 4 and #rev <= 40 and rev:match("^%x+$") then
        local gitRoot = bash.getObjectsRoot()
        local objects = gitRoot and gitRoot:FindFirstChild("objects")
        local dir = objects and objects:FindFirstChild(rev:sub(1, 2):lower())
        if dir then
            local rest = rev:sub(3):lower()
            local found = nil
            for _, child in ipairs(dir:GetChildren()) do
                if child.Name:sub(1, #rest) == rest then
                    if found then return nil end --// ambiguous
                    found = rev:sub(1, 2):lower() .. child.Name
                end
            end
            return found
        end
    end

    return nil
end

--[[
Returns every ref under .git/refs as {["refs/heads/main"] = sha}.
]]
function Handlers.list_refs()
    local refs = {}
    local root = bash.getGitFolderRoot()
    local refsFolder = root and root:FindFirstChild("refs")
    if not refsFolder then return refs end

    local function scan(folder, prefix)
        for _, child in ipairs(folder:GetChildren()) do
            if child:IsA("Folder") and not child:FindFirstChild("1") then
                scan(child, prefix .. child.Name .. "/")
            else
                local content = bash.getFileContents(folder, child.Name)
                if content and content ~= "" and #content == 40 then
                    refs[prefix .. child.Name] = content
                end
            end
        end
    end
    scan(refsFolder, "refs/")
    return refs
end

--// ------------------------------------------------------------------ submodules

--[[
Submodules are folders with this attribute (the submodule's name). Their repository is .git/modules/<name>.
]]
Handlers.SUBMODULE_ATTRIBUTE = "RoGitSubmodule"
--// the commit a submodule folder should be at, for submodules that were not cloned yet
Handlers.SUBMODULE_COMMIT_ATTRIBUTE = "RoGitSubmoduleCommit"

function Handlers.is_submodule(instance)
    return instance ~= bash.getWorkRoot() and type(instance:GetAttribute(Handlers.SUBMODULE_ATTRIBUTE)) == "string"
end

function Handlers.submodule_git_folder(name)
    local main = bash.getMainGitFolder()
    local modules = main and main:FindFirstChild("modules")
    return modules and name and modules:FindFirstChild(name) or nil
end

--[[
The commit checked out in a submodule folder (what the superproject records for it).
]]
function Handlers.submodule_head(instance)
    local folder = Handlers.submodule_git_folder(instance:GetAttribute(Handlers.SUBMODULE_ATTRIBUTE))
    if not folder then
        return instance:GetAttribute(Handlers.SUBMODULE_COMMIT_ATTRIBUTE)
    end
    local head = bash.getFileContents(folder, "HEAD")
    local guard = 0
    while head and head:sub(1, 5) == "ref: " and guard < 5 do
        local file = bash.getDirectoryOrFile(folder, head:sub(6))
        head = file and bash.getFileContents(file.Parent, file.Name)
        guard += 1
    end
    if head and #head == 40 then
        return head
    end
    return instance:GetAttribute(Handlers.SUBMODULE_COMMIT_ATTRIBUTE)
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

    --// only scripts have more than one line, skip the JSON decode for everything else
    if not string.find(blob.content, '"Source"', 1, true) then return 1 end

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

--[[
Retrieves a list of all local branches.
]]
function Handlers.get_branches()
    local gitRoot = bash.getGitFolderRoot()
    if not gitRoot then
        return {}
    end
    
    local headsDir = bash.getDirectoryOrFile(gitRoot, "refs/heads")
    if not headsDir then
        return {}
    end

    local branches = {}

    local function recursiveDir(dir, prefix)
        for _, child in ipairs(dir:GetChildren()) do
            if child:IsA("StringValue") then
                table.insert(branches, prefix .. child.Name)
            elseif child:IsA("Folder") then
                recursiveDir(child, prefix .. child.Name .. "/")
            end
        end
    end

    recursiveDir(headsDir, "")

    return branches
end

return Handlers