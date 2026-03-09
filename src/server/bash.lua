local Bash = {}

local ServerStorage = game:GetService("ServerStorage")

local conf = {
    gitRoot = ServerStorage
}

Bash.trackingRoot = {
    game:GetService("Workspace"),
    game:GetService("ReplicatedStorage"),
    game:GetService("ReplicatedFirst"),
    game:GetService("ServerScriptService"),
    game:GetService("ServerStorage"),
    game:GetService("StarterGui"),
    game:GetService("Lighting"),
    game:GetService("StarterPack"),
    game:GetService("StarterPlayer"),
    game:GetService("SoundService"),
    game:GetService("AdService"),
    game:GetService("LocalizationService"),
    game:GetService("PhysicsService"),
    game:GetService("TextService"),
    game:GetService("Teams")
}

--[[
Kind-of emulates "bash"?
Needs a real filesystem setup/filesystem navigation commands.
]]

--[[
Returns our git root folder
]]
function Bash.getGitFolderRoot()
    if conf.gitRoot:FindFirstChild(".git") then
        return conf.gitRoot:FindFirstChild(".git")
    end
    return nil
end

--[[
Does file exist?
]]
function Bash.exists(parent, name)
    return parent:FindFirstChild(name) ~= nil
end

--[[
Creates the git root folder in ServerStorage (hardcoded!)
]]
function Bash.createGitFolderRoot()
    local root = Instance.new("Folder")
    root.Parent = ServerStorage
    root.Name = ".git"
    return root
end

--[[
Create a "file" using some stringvalues (or folder + stringvalues if too large!)
tbh this is probably a hack sort of thing for now>
]]
function Bash.createFile(parent, name, content)
    assert(typeof(parent) == "Instance", "Parent doesnt exist, or not instance!")
    assert(name, "File name is nil!")
    assert(content, "Content is nil!")

    if parent:FindFirstChild(name) then 
        return parent:FindFirstChild(name)
    end

    --// Small content
    if #content <= 199000 then
        local str = Instance.new("StringValue")
        str.Parent = parent
        str.Value = content
        str.Name = name
        return str
    --// Big content, split it up!
    else
        local folder = Instance.new("Folder")
        folder.Name = name
        folder.Parent = parent
        
        local chunks = math.ceil(#content / 199000)
        for i = 1, chunks do
            local chunkStr = Instance.new("StringValue")
            chunkStr.Name = tostring(i)
            chunkStr.Value = string.sub(content, (i-1)*199000 + 1, i*199000)
            chunkStr.Parent = folder
        end
        return folder
    end
end

--[[
Gets the directory/file
]]
function Bash.getDirectoryOrFile(parent, name)
    -- Quick checks
    assert(typeof(parent) == "Instance", "Parent doesnt exist, or not instance!")

    for _, rec in string.split(name, "/") do
        if parent:FindFirstChild(rec) then
            parent = parent:FindFirstChild(rec)
        else
            return nil
        end
    end

    return parent
end

--[[
Gets the contents of a file.
if file is split up into folders? we piece chunks together and return that.
]]
function Bash.getFileContents(parent, name)
    assert(typeof(parent) == "Instance", "Parent doesnt exist, or not instance!")
    assert(name, "File name is nil!")
    
    local file = parent:FindFirstChild(name)
    
    if not file then return nil end

    if file:IsA("StringValue") then
        return file.Value
    elseif file:IsA("Folder") then
        local result = {}
        local i = 1
        while true do
            local chunk = file:FindFirstChild(tostring(i))
            if chunk and chunk:IsA("StringValue") then
                table.insert(result, chunk.Value)
                i = i + 1
            else
                break
            end
        end
        return table.concat(result, "")
    end

    return nil
end

--[[
Modifies the contents of a file (or split file)
]]
function Bash.modifyFileContents(parent, name, content)
    assert(typeof(parent) == "Instance", "Parent doesnt exist, or not instance!")
    assert(name, "File name is nil!")
    assert(content, "Content is nil!")

    local str = parent:FindFirstChild(name)
    if not str then
        warn("Bash: Attempting to modify non-existent file '" .. name .. "' in '" .. parent:GetFullName() .. "'. Creating instead.")
        return Bash.createFile(parent, name, content)
    end
    
    if str:IsA("StringValue") then
        if #content <= 199000 then
            str.Value = content
            return str
        else
            str:Destroy()
            return Bash.createFile(parent, name, content)
        end
    elseif str:IsA("Folder") then
        if #content <= 199000 then
            str:Destroy()
            return Bash.createFile(parent, name, content)
        else
            str:ClearAllChildren()
            local chunks = math.ceil(#content / 199000)
            for i = 1, chunks do
                local chunkStr = Instance.new("StringValue")
                chunkStr.Name = tostring(i)
                chunkStr.Value = string.sub(content, (i-1)*199000 + 1, i*199000)
                chunkStr.Parent = str
            end
            return str
        end
    end
    return nil
end

--[[
Creates a folder at specific parent/name
]]
function Bash.createFolder(parent, name)
    assert(typeof(parent) == "Instance", "Parent doesnt exist, or not instance!")

    --// Recursive folder creation (hierarchy)
    for _, rec in string.split(name, "/") do
        if parent:FindFirstChild(rec) then
            parent = parent:FindFirstChild(rec)
        else
            --// Create folder
            local fldr = Instance.new("Folder")
            fldr.Parent = parent
            fldr.Name = rec
            parent = fldr
        end
    end

    return parent
end

return Bash