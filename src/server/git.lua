local git = {}

local HttpService = game:GetService("HttpService")
local ScriptRegistrationService = game:GetService("ScriptRegistrationService")
local Workspace = game:GetService("Workspace")

local config = require(script.Parent.config)
local arguments = require(script.Parent.arguments)

local hashlib = require(script.Parent.libs.hashlib)
local zlib = require(script.Parent.libs.zlib)
local bash = require(script.Parent.bash)

local ignore_patterns = nil

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
    local data = bash.getFileContents(dir, string.sub(sha, 1, 2))

    local raw = zlib.decompressZlib(data)
    local nullIndex = string.find(raw, "\0", 1, true)

    local header = string.sub(raw, 1, nullIndex - 1)
    local content = string.sub(raw, nullIndex + 1)

    local typeName = string.split(header, "")[1]
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
                tree_content = string.format("%s %s\0%s", item.mode, name, hashlib.hex_to_bin(sha))
            else
                sha = build_tree_objects(item)
                type = "tree"
                tree_content = string.format("40000 %s\0%s", name, hashlib.hex_to_bin(sha))
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

local function store_instance_hash(desc)
    
    assert(desc, "no instance supplied!")
    local hash = calculate_hash(desc)
    local dir = bash.createFolder(bash.getGitFolderRoot(), "objects/" .. string.sub(hash, 1, 2))
        
    -- create the file (create subfolder, first 2 chars of hash. then remove first 2 chars of content and set as name, compress)
    bash.createFile(dir, string.sub(hash, 3), zlib.compressZlib(serialize_instance(desc)))
    
    -- Modify index, newline, hash and fullname
    bash.modifyFileContents(bash.getGitFolderRoot(), "index", (
        bash.getFileContents(bash.getGitFolderRoot(), "index") ..
        "\n" ..
        hash .. " " .. desc:GetFullName()
    )) -- create index
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
    local index = read_index()

    -- git add . (.=root)
    if target == "." then
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

    local parent_sha = get_ref("HEAD")

    local index = read_index()
    local tree_sha = write_tree(index)

    local commit_content = "tree " .. tree_sha .. "\n"

    if parent_sha and parent_sha ~= "" then
        commit_content = commit_content .. "parent " .. parent_sha .. "\n"
    end

    local timestamp = os.time()
    commit_content = commit_content ..
        string.format("author roGit <ro-git@example.com> %d +0000\n", timestamp)
    commit_content = commit_content ..
        string.format("committer roGit <ro-git@example.com> %d +0000\n", timestamp)

    commit_content = commit_content .. "\n" .. message

    local commit_sha = write_object("commit", commit_content)

    update_ref("HEAD", commit_sha)

    print("Committed to master, commit SHA: " .. commit_sha)
end)


--[[
commands:
init
]]

arguments.createArgument("init", "", function (...)
    -- Create .git if not existing already.

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

arguments.createArgument("clone", "", function (...)
    assert((#{...} >= 1), "No argument supplied!")
    local tuple = {...}

    local repo = tuple[1]

    if not string.find(repo, "github") then -- no non github support, since using their api directly ):
        warn_assert("Sorry! Only GitHub repositories are supported, due to ROBLOX api limitations.")
    end
    -- cleaning time!
    repo = repo:gsub("https://github.com/", "")
    repo = repo:gsub("git@github.com:", "")
    repo = repo:gsub(".git", "")

    -- cloning :P

    print("Cloning into '" .. string.split(repo, "/")[2] .. "'")
    local base_url = "https://api.github.com"
    
    local req = HttpService:RequestAsync({
        Url = "https://api.github.com/repos/" .. repo .. "/contents"
    })

    if not req.Success and req.StatusCode ~= 200 then 
        warn_assert("Request error! Status: " .. req.StatusCode)
    end
 
    -- download contents
    local body = HttpService:JSONDecode(req.Body)
    local parent = bash.createFolder(workspace, string.split(repo, "/")[2])
    recursive_download(body, parent)

    print("Repository " .. "'" .. string.split(repo, "/")[2] .. "'" .. " Cloned")
end)

return git