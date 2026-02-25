--[[
Full "rewrite" of git in luau
]]

local arguments = require(script.Parent.arguments)
local git = require(script.Parent.git)

--[[
Test execution
]]
arguments.executeArgument("clone", "https://github.com/officialmelon/openradar.git")