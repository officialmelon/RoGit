--[[
Full "rewrite" of git in luau
]]
local arguments = require(script.Parent.arguments)
local git = require(script.Parent.git)
local pluginModule = require(script.Parent.plugin)

pluginModule.initializePlugin(plugin)

--[[
Example custom execution via say an API?
]]
-- arguments.executeArgument("git", "init", ".")
-- arguments.executeArgument("git", "add", ".")
-- arguments.executeArgument("git", "remote", "add", "origin", "https://github.com/officialmelon/rblx_test.git")
-- arguments.executeArgument("git", "commit", "-m", "commit")
-- arguments.executeArgument("git", "push", "origin", "master")