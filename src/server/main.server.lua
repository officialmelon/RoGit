--[[
Full "rewrite" of git in luau
]]

local arguments = require(script.Parent.arguments)

arguments.createArgument("version", "v", function ()
    print "Version 0.33"
end)

arguments.executeArgument("v")