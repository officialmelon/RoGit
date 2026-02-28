local arguments = {}

arguments.existingCommands = {

}

--[[
Returns existingArguments
]]
function arguments.returnAllArguments(cmd)
    return arguments[cmd].existingArguments
end

local function levenshtein(s1, s2)
    local len1, len2 = #s1, #s2
    local matrix = {}
    for i = 0, len1 do matrix[i] = {[0] = i} end
    for j = 0, len2 do matrix[0][j] = j end
    for i = 1, len1 do
        for j = 1, len2 do
            local cost = (string.lower(s1:sub(i, i)) == string.lower(s2:sub(j, j))) and 0 or 1
            matrix[i][j] = math.min(matrix[i-1][j] + 1, matrix[i][j-1] + 1, matrix[i-1][j-1] + cost)
            -- transposition
            if i > 1 and j > 1 and s1:sub(i,i) == s2:sub(j-1,j-1) and s1:sub(i-1,i-1) == s2:sub(j,j) then
                matrix[i][j] = math.min(matrix[i][j], matrix[i-2][j-2] + cost)
            end
        end
    end
    return matrix[len1][len2]
end

function arguments.replacePrint(callback)
    print = callback
end

--[[
Retrieves argument based on input
]]
function arguments.retrieveArgument(command, argumentOrAlias)
    local cmd = arguments.existingCommands[command]
    if not cmd then return nil end

    for _, arg in pairs(cmd.args) do
        if arg.main_arg == argumentOrAlias or arg.alias == argumentOrAlias then
            return arg
        end
    end
    return nil
end

function arguments.createCommand(command, callback)
    assert(type(command) == "string", "command is either nil or not a string!, received: " .. tostring(command))
    assert(not arguments.existingCommands[command], "attempting to create command that already exists!")

    arguments.existingCommands[command] = 
    {
        main_command = command,
        callback = callback or nil,
        args = {},
    }
end

function arguments.createArgument(command, argument, alias, callback, ...)
    assert(type(command) == "string", "command must be a string, received: " .. tostring(command))
    assert(type(argument) == "string", "argument must be a string, received: " .. tostring(argument))

    -- allow skipping alias
    if type(alias) == "function" then
        callback = alias
        alias = argument
    end

    assert(type(alias) == "string", "alias must be a string, received: " .. tostring(alias))
    assert(type(callback) == "function", "callback must be a function!")

    local cmd = arguments.existingCommands[command]
    assert(cmd, "command '" .. command .. "' does not exist! Create it with createCommand first.")
    assert(not cmd.args[argument], "argument '" .. argument .. "' already exists on command '" .. command .. "'!")

    cmd.args[argument] = {
        main_arg = argument,
        alias = alias,
        callback = callback,
        extra_passed = ... or nil,
    }
end

function arguments.execute(command, argument, ...)
    assert(type(command) == "string", "command must be a string")

    local cmd = arguments.existingCommands[command]
    if not cmd then
        print("unknown command '" .. command .. "'")
        return
    end

    if argument == nil then
        if cmd.callback then
            cmd.callback(...)
        else
            print(command .. ": no arguments provided. Available arguments:")
            for name, _ in pairs(cmd.args) do
                print("        " .. name)
            end
        end
        return
    end

    local retrievedArgument = arguments.retrieveArgument(command, argument)
    if retrievedArgument then
        retrievedArgument.callback(...)
        return
    end

    print(command .. ": '" .. argument .. "' is not a " .. command .. " command. See '" .. command .. " --help'.")
    print("")

    local similar = {}
    for name, _ in pairs(cmd.args) do
        local dist = levenshtein(argument, name)
        if dist <= 3 then
            table.insert(similar, { name = name, dist = dist })
        end
    end

    if #similar > 0 then
        table.sort(similar, function(a, b) return a.dist < b.dist end)
        print("The most similar commands are")
        local count = 0
        for _, match in ipairs(similar) do
            print("        " .. match.name)
            count = count + 1
            if count >= 4 then break end
        end
    end
end

return arguments