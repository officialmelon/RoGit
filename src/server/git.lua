local git = {}

local HttpService = game:GetService("HttpService")

local config = require(script.Parent.config)
local arguments = require(script.Parent.arguments)

local hashlib = require(script.Parent.libs.hashlib)
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
                    value = instance[property.Name]
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
    -- Check and hint if no tuple supplied
    warn_assert(..., "hint: Maybe you wanted to say 'git add .'?")
    local packed = {...}
    local getDirectoryOut = bash.getDirectory(packed[1])

    assert(getDirectoryOut, "fatal: pathspec '" .. packed[1] .. "' did not match any files ")

    print(calculate_hash(workspace.ExampleInstance))

    --TODO implement add functino.
end)

return git