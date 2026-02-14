local git = {}

local HttpService = game:GetService("HttpService")

local config = require(script.Parent.config)
local arguments = require(script.Parent.arguments)

local hashlib = require(script.Parent.libs.hashlib)
local zlib = require(script.Parent.libs.zlib)
local bash = require(script.Parent.bash)

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
    -- Check and hint if no tuple supplied then or not initialized
    assert(bash.getGitFolderRoot(), "fatal: not a git repository (or any of the parent directories): .git")
    warn_assert(..., "hint: Maybe you wanted to say 'git add .'?")

    local packed = {...}

    local getDirectoryOut = bash.getDirectoryOrFile(game.Workspace, packed[1])
    assert(getDirectoryOut, "fatal: pathspec '" .. packed[1] .. "' did not match any files ")

    -- is root? set to game
    if packed[1] == "." then 
        local root = bash.trackingRoot
        for _, service in root do 
            for _, desc in service:GetDescendants() do 
                if not desc:IsDescendantOf(bash.getGitFolderRoot()) then 
                    store_instance_hash(desc)
                end
            end
        end
    else -- single file or folder
        packed = string.split(packed[1], ".")
        local currObj = game
        for i = 1, #packed do
            local path = packed[i]
            if currObj and currObj:FindFirstChild(path) then 
                currObj = currObj:FindFirstChild(path)
            else 
                 currObj = nil
                 break
            end
        end

        if currObj then 
            store_instance_hash(currObj)
            if #currObj:GetChildren() >= 1 then -- probably redundant, but had errors w/o
                for _, desc in currObj:GetDescendants() do 
                    store_instance_hash(desc)
                end
            end
        end
    end
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
    
end)

return git