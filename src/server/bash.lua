local Bash = {}

local ServerStorage = game:GetService("ServerStorage")

local conf = {
    gitRoot = ServerStorage
}

Bash.trackingRoot = {
    game:GetService("Workspace"),
    game:GetService("Lighting"),
    game:GetService("MaterialService"),
    game:GetService("ReplicatedFirst"),
    game:GetService("ReplicatedStorage"),
    game:GetService("ServerScriptService"),
    game:GetService("ServerStorage"),
    game:GetService("StarterGui"),
    game:GetService("StarterPack"),
    game:GetService("StarterPlayer"),
    game:GetService("SoundService"),
}

--[[
Bash-Esque file system
]]

-- Returns where we hold .git
function Bash.getGitFolderRoot()
    if conf.gitRoot:FindFirstChild(".git") then
        return conf.gitRoot:FindFirstChild(".git")
    end
end

-- Creates .git folder (e.g. for init)
function Bash.createGitFolderRoot()
    local root = Instance.new("Folder")
    root.Parent = ServerStorage
    root.Name = ".git"
    return root
end

-- Create files
function Bash.createFile(parent, name, content)
    -- Quick checks
    assert(typeof(parent) == "Instance", "Parent doesnt exist, or not instance!")
    assert(name, "File name is nil!")
    assert(content, "Content is nil!")

    if parent:FindFirstChild(name) then 
        assert("File already exists!")
        return
    end

    -- create "File" (stringvalue)
    local str = Instance.new("StringValue")
    str.Parent = parent
    str.Value = content
    str.Name = name

    return str
end

-- Get folders

function Bash.getDirectoryOrFile(parent, name)
    -- Quick checks
    assert(typeof(parent) == "Instance", "Parent doesnt exist, or not instance!")

    for _, rec in string.split(name, "/") do
        if parent:FindFirstChild(rec) then
            parent = parent:FindFirstChild(rec)
        end
    end

    return parent
end

function Bash.getFileContents(parent, name)
    -- Quick checks
    assert(typeof(parent) == "Instance", "Parent doesnt exist, or not instance!")
    assert(name, "File name is nil!")
    
    local file = parent:FindFirstChild(name)
    
    if not file then return nil end

    return file.value
end

function Bash.modifyFileContents(parent, name, content)
    -- Quick checks
    assert(typeof(parent) == "Instance", "Parent doesnt exist, or not instance!")
    assert(name, "File name is nil!")
    assert(content, "Content is nil!")

    assert(parent:FindFirstChild(name), "File doesnt exist! Looking for " .. content)

    local str = parent:FindFirstChild(name)
    str.Value = content
end

-- Create files
function Bash.createFolder(parent, name)
    -- Quick checks
    assert(typeof(parent) == "Instance", "Parent doesnt exist, or not instance!")

    -- Recursive folder creation (hierarchy)
    for _, rec in string.split(name, "/") do
        if parent:FindFirstChild(rec) then
            parent = parent:FindFirstChild(rec)
        else
            -- Create folder
            local fldr = Instance.new("Folder")
            fldr.Parent = parent
            fldr.Name = rec
            parent = fldr
        end
    end

    return parent
end

return Bash