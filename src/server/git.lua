local git = {}

local config = require(script.Parent.config)
local arguments = require(script.Parent.arguments)

local bash = require(script.Parent.bash)

--[[
Utilities

warn_assert
warns instead of asserting.

]]

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

    --TODO implement add functino.
end)

return git