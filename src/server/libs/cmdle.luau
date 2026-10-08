local commandle_plugin = {}

--// Services
local StudioService = game:GetService("StudioService")

--// This is the root of our API (looked up in setupPlugin, waiting for it here would stall the whole plugin on startup)
local commandle_api_root = nil
local argumentsModule = require(script.Parent.Parent.arguments)
local gitHandlers = require(script.Parent.git_handlers)

--// Type definition
type api_objects = {
    createCommands: BindableEvent,
    pushRequest: BindableEvent,
    popRequest: BindableEvent,

    openPalette: BindableEvent,
    closePalette: BindableEvent,

    requestTheme: BindableEvent,
    requestInput: BindableEvent
}

--// API Objects
local api_objects : api_objects = {
    createCommands = nil,
    pushRequest = nil,
    popRequest = nil,

    closePalette = nil,
    openPalette = nil,

    requestTheme = nil,
    requestInput = nil
}

--// Runs a git command, printing the error (if any) instead of "nil" noise when it succeeds
local function runGit(...)
    local ok, err = pcall(argumentsModule.execute, "git", ...)
    if not ok then
        warn("RoGit: " .. tostring(err):gsub("^.-:%d+: ", ""))
    end
    return ok
end

function commandle_plugin:setupCommands()
    commandle_plugin:createCommands("main", {
        {
            title = "RoGit: Initialize Repository",

            callback = function()
                runGit("init", ".")
                commandle_plugin:closePalette(true)
            end
        },
        {
            title = "RoGit: Clone Repository",

            callback = function()
                commandle_plugin:requestInput(
                    "Repository URL...",
                    function(input : string)
                        runGit("clone", input)
                        commandle_plugin:closePalette(true)
                    end
                )
            end
        },
        {
            title = "RoGit: Checkout Branch",

            callback = function()
                local commands = {}

                -- loop through branches
                for _, branch in gitHandlers.get_branches() do
                    -- is current branch?
                    local isCurr = (branch == gitHandlers.get_current_branch())

                    -- Insert as command
                    table.insert(commands, {
                        title = isCurr and ("* " .. branch) or branch,

                        callback = function()
                            runGit("checkout", branch)

                            -- close
                            commandle_plugin:closePalette(true)
                        end
                    })

                end

                table.insert(commands, 1, {
                    title = "Create Branch",

                    callback = function()
                        commandle_plugin:requestInput("branch name...", function(input : string)
                            runGit("branch", input)
                        end)
                    end
                })

                -- push the request
                commandle_plugin:pushRequest(commands)
                commandle_plugin:closePalette(true)
            end
        },
        {
            title = "RoGit: Stage Changes",

            callback = function()
                runGit("add", ".")
                commandle_plugin:closePalette(true)
            end
        },
        {
            title = "RoGit: Commit Staged",

            callback = function()
                commandle_plugin:requestInput("your commit description...", function(input : string)
                    runGit("commit", "-m", input)

                    commandle_plugin:closePalette(true)
                end)
            end
        },
        {
            title = "RoGit: Add/Set Remote",

            callback = function()
                commandle_plugin:requestInput("repository url...", function(repoUrl : string)
                    commandle_plugin:requestInput("remote name...", function(remoteName : string)
                        local config = require(script.Parent.Parent.bash).getFileContents(require(script.Parent.Parent.bash).getGitFolderRoot(), "config") or ""
                        local exists = config:find('[remote "' .. remoteName .. '"]', 1, true) ~= nil
                        runGit("remote", exists and "set-url" or "add", remoteName, repoUrl)

                        commandle_plugin:closePalette(true)
                    end)
                end)
            end
        },
        {
            title = "RoGit: Pull from remote",

            callback = function()
                runGit("pull")
                commandle_plugin:closePalette(true)
            end
        },
        {
            title = "RoGit: Push to remote",

            callback = function()
                commandle_plugin:requestInput("remote name... (default: origin)", function(input : string)
                    if input and input ~= "" then
                        runGit("push", input)
                    else
                        runGit("push")
                    end
                    commandle_plugin:closePalette(true)
                end)
            end
        }
    })
end

--// Sets-up the API
function commandle_plugin:setupPlugin()
    commandle_api_root = StudioService:WaitForChild("commandle_api", 5)

    -- API does not exist (commandle not installed?)
    if not commandle_api_root then
        return
    end

    -- Sets up the Bindables
    api_objects.createCommands = commandle_api_root.createCommands
    api_objects.pushRequest = commandle_api_root.pushRequest
    api_objects.popRequest = commandle_api_root.popRequest
    api_objects.closePalette = commandle_api_root.closePalette
    api_objects.openPalette = commandle_api_root.openPalette
    api_objects.requestTheme = commandle_api_root.requestTheme
    api_objects.requestInput = commandle_api_root.requestInput

    -- Setup commands
    commandle_plugin:setupCommands()
end

--// API functions
function commandle_plugin:createCommands(commandType : string, tableOfCommands : {{title: string, callback: () -> ()}})
    api_objects.createCommands:Fire(commandType, tableOfCommands)
end

function commandle_plugin:pushRequest(tableOfCommands : {{title : string, callback: () -> ()}})
    api_objects.pushRequest:Fire(tableOfCommands)
end

function commandle_plugin:popRequest()
    api_objects.popRequest:Fire()
end

function commandle_plugin:openPalette()
    api_objects.openPalette:Fire()
end

function commandle_plugin:closePalette(shouldAnimate : boolean)
    -- default is true
    api_objects.closePalette:Fire(shouldAnimate)
end

function commandle_plugin:requestInput(stringName : string, callback: (answer : string) -> ())
    api_objects.requestInput:Fire(stringName or "", callback)
end

return commandle_plugin