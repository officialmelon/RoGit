--[[
Full "rewrite" of git in luau
]]
local arguments = require(script.Parent.arguments)
local git = require(script.Parent.git)
local plugin = require(script.Parent.plugin)

plugin.initializePlugin()

--[[
Test execution
]]
-- arguments.executeArgument("init", ".")
-- arguments.executeArgument("add", ".")
-- arguments.executeArgument("remote", "add", "origin", "https://github.com/officialmelon/rblx_test.git")
-- arguments.executeArgument("commit", "-m", "commit")
-- arguments.executeArgument("push", "origin", "master")