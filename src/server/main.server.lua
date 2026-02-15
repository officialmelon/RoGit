--[[
Full "rewrite" of git in luau
]]

local arguments = require(script.Parent.arguments)
local git = require(script.Parent.git)

--[[
Test execution
]]
arguments.executeArgument("init", ".")
arguments.executeArgument("add", ".")
arguments.executeArgument("commit", "-m", '"Initial Commit"')
-- workspace.ExampleInstance:Remove()