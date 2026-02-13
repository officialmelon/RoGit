local arguments = {}

arguments.existingArguments = {

}

--[[
Retrieves argument based on input
]]

function arguments.retrieveArgument(argumentOrAlias)
    -- Checking before retrieving
    assert(type(argumentOrAlias) == "string", "argument (or alias) is either nil or not a string!, received: " .. argumentOrAlias)

    -- Retrieves argument
    local checkedArg = nil

    for _, argument in arguments.existingArguments do
        if argument.main_arg == argumentOrAlias or argument.alias == argumentOrAlias then 
            checkedArg = argument
        end
    end

    -- Check and return
    assert(checkedArg, "the supplied argument (or alias) doesn't exist within existingArguments!")

    return checkedArg
end

--[[
Creates runnable argument based on input
]]
function arguments.createArgument(argument, alias, callback, ...)
    -- Checking before creating argument table.
    assert(type(argument) == "string", "argument is either nil or not a string!, received: " .. argument)
    assert(type(alias) == "string", "alias is either nil or not a string!, received: " .. alias)
    assert(type(callback) == "function", "callback is either nil or not a function!")
    assert(not arguments.existingArguments[argument], "attempting to create argument that already exists!")

    -- insert argument into table (dictionary key)
    arguments.existingArguments[argument] = 
    {
        main_arg = argument,
        alias = alias,
        callback = callback,
        extra_passed = ... or nil,
    }
end

--[[
Executes argument added from createArgument (or existingArguments)
]]
function arguments.executeArgument(argument, ...)
    -- Checking before attempting to execute arguments.
    assert(type(argument) == "string", "executing argument is either nil or not a string!, received: " .. argument)
    assert(arguments.retrieveArgument(argument), "attempting to execute argument not found!, received: " .. argument)

    -- Fetch argument
    local retrievedArgument = arguments.retrieveArgument(argument)

    -- Execute argument
    retrievedArgument.callback(...)
end

return arguments