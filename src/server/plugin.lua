--[[
Plugin (handles the plugin itself)
Creates UI for bash so far
need to implement user-friendly
]]

local plugins = {}
local arguments = require(script.Parent.arguments)
local git = require(script.Parent.git)
local StudioService = game:GetService("StudioService")
local Players = game:GetService("Players")

local user = Players:GetNameFromUserIdAsync(StudioService:GetUserId())
local name = game.Name

function createCommandOutput(parent, text, optionalColor)
    local command = Instance.new("Frame")
    local output = Instance.new("TextLabel")
    local UIListLayout = Instance.new("UIListLayout")
    
    command.Name = "output"
    command.Parent = parent
    command.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    command.BackgroundTransparency = 1.000
    command.BorderSizePixel = 0
    command.Size = UDim2.new(1, 0, 0, 0)
    command.AutomaticSize = Enum.AutomaticSize.Y

    UIListLayout.Parent = command
    UIListLayout.SortOrder = Enum.SortOrder.LayoutOrder

    output.Name = "output"
    output.Parent = command
    output.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    output.BackgroundTransparency = 1.000
    output.BorderSizePixel = 0
    output.Size = UDim2.new(1, 0, 0, 0)
    output.AutomaticSize = Enum.AutomaticSize.Y
    output.Font = Enum.Font.Ubuntu
    output.Text = text
    output.TextColor3 = optionalColor or Color3.fromRGB(255, 255, 255)
    output.TextSize = 14.000
    output.TextXAlignment = Enum.TextXAlignment.Left
    output.TextWrapped = true
    output.RichText = true

    return output
end

function createCommandEntry(parent)
    local command = Instance.new("Frame")
    local start = Instance.new("TextLabel")
    local entry = Instance.new("TextBox")
    local UIListLayout = Instance.new("UIListLayout")
    
    command.Name = "command"
    command.Parent = parent
    command.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    command.BackgroundTransparency = 1.000
    command.BorderSizePixel = 0
    command.Size = UDim2.new(1, 0, 0, 18)

    UIListLayout.Parent = command
    UIListLayout.FillDirection = Enum.FillDirection.Horizontal
    UIListLayout.SortOrder = Enum.SortOrder.LayoutOrder

    start.Name = "start"
    start.Parent = command
    start.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    start.BackgroundTransparency = 1.000
    start.BorderSizePixel = 0
    start.Size = UDim2.new(0, 172, 1, 0)
    start.Font = Enum.Font.Ubuntu
    start.Text =  user .. "@" .. name .. ">"
    start.TextColor3 = Color3.fromRGB(255, 255, 255)
    start.TextSize = 14.000
    start.TextXAlignment = Enum.TextXAlignment.Left

    entry.Name = "entry"
    entry.Parent = command
    entry.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    entry.BackgroundTransparency = 1.000
    entry.BorderSizePixel = 0
    entry.Selectable = false
    entry.Size = UDim2.new(1, -172, 1, 0)
    entry.Font = Enum.Font.Ubuntu
    entry.Text = ""
    entry.ClearTextOnFocus = false
    entry.TextColor3 = Color3.fromRGB(255, 255, 255)
    entry.TextSize = 14.000
    entry.TextXAlignment = Enum.TextXAlignment.Left
    
    handleCommandCallback(entry, parent)
    
    -- Auto-focus the new entry line!
    pcall(function()
        entry:CaptureFocus()
    end)

    return command
end

local commandHistory = {}

function handleCommandCallback(TextBox:TextBox, parent)
    local UserInputService = game:GetService("UserInputService")
    local unsubmittedText = ""
    local localHistoryIndex = #commandHistory + 1
    
    local inputConnection
    inputConnection = UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if TextBox:IsFocused() then
            if input.KeyCode == Enum.KeyCode.Up then
                if localHistoryIndex > 1 then
                    if localHistoryIndex == #commandHistory + 1 then
                        unsubmittedText = TextBox.Text
                    end
                    localHistoryIndex = localHistoryIndex - 1
                    TextBox.Text = commandHistory[localHistoryIndex]
                    TextBox.CursorPosition = #TextBox.Text + 1
                end
            elseif input.KeyCode == Enum.KeyCode.Down then
                if localHistoryIndex < #commandHistory then
                    localHistoryIndex = localHistoryIndex + 1
                    TextBox.Text = commandHistory[localHistoryIndex]
                    TextBox.CursorPosition = #TextBox.Text + 1
                elseif localHistoryIndex == #commandHistory then
                    localHistoryIndex = localHistoryIndex + 1
                    TextBox.Text = unsubmittedText
                    TextBox.CursorPosition = #TextBox.Text + 1
                end
            end
        end
    end)

    TextBox.FocusLost:Connect(function(enterPressed)
        if not enterPressed then
            return
        end

        if inputConnection then
            inputConnection:Disconnect()
        end

        TextBox.TextEditable = false

        -- Clean Input
        local text = TextBox.Text:gsub("^%s+", ""):gsub("%s+$", "")
        if text ~= "" then
            if #commandHistory == 0 or commandHistory[#commandHistory] ~= text then
                table.insert(commandHistory, text)
            end
            
            local toProcess = string.split(text, " ")
            local cmdName = string.lower(toProcess[1])
            
            if arguments.existingCommands[cmdName] then
                table.remove(toProcess, 1)
                                
                local status, err = pcall(function()
                    arguments.execute(cmdName, table.unpack(toProcess))
                end)
                if not status then
                    local cleanErr = tostring(err):gsub("^.-:%d+: ", "")
                    createCommandOutput(parent, "fatal: " .. cleanErr)
                end
            else
                createCommandOutput(parent, "RoGit: command not found: " .. (cmdName or ""))
            end
        end

        -- New arg
        createCommandEntry(parent)
    end)
end

function plugins.createBashTerminal(plugin)

    --// Create terminal
    local terminal_window = DockWidgetPluginGuiInfo.new(
        Enum.InitialDockState.Bottom,
        true,
        false,
        -- Default of floating window
        1000,
        500,
        -- Default min w/h
        200,
        100
    )

    local terminal = plugin:CreateDockWidgetPluginGui("BashTerminal", terminal_window)
    terminal.Title = "RoGit Terminal"

    local terminal_frame = Instance.new("TextButton")
    terminal_frame.Text = ""
    terminal_frame.AutoButtonColor = false
    terminal_frame.BackgroundColor3 = Color3.fromRGB(0,0,0)
    terminal_frame.Size = UDim2.new(1,0,1,0)
    terminal_frame.Position = UDim2.new(0,0,1,0)
    terminal_frame.AnchorPoint = Vector2.new(0,1)
    terminal_frame.Parent = terminal

    local holder = Instance.new("ScrollingFrame")
    holder.Name = "commands_holder"
    holder.Parent = terminal_frame
    holder.BackgroundTransparency = 1
    holder.Size = UDim2.new(1,0,1,0)
    holder.CanvasSize = UDim2.new(0,0,0,0)
    holder.AutomaticCanvasSize = Enum.AutomaticSize.Y
    holder.ScrollBarThickness = 0

    local CommandsListLayout = Instance.new("UIListLayout")
    CommandsListLayout.Parent = holder
    CommandsListLayout.Padding = UDim.new(0,5)
    CommandsListLayout.SortOrder = Enum.SortOrder.LayoutOrder

    --// Set output

    local function scrollToBottom()
        task.wait()
        holder.CanvasPosition = Vector2.new(0, holder.AbsoluteCanvasSize.Y)
    end

    local function printOutput(...)
        local tuple = {...}
        local str = ""
        for i, v in ipairs(tuple) do
            str = str .. tostring(v) .. (i < #tuple and " " or "")
        end
        createCommandOutput(holder, str)
        scrollToBottom()
    end

    local function warnOutput(...)
        local tuple = {...}
        local str = ""
        for i, v in ipairs(tuple) do
            str = str .. tostring(v) .. (i < #tuple and " " or "")
        end
        createCommandOutput(holder, str, Color3.new(1, 1, 0))
        scrollToBottom()
    end

    local function errOutput(...)
        local tuple = {...}
        local str = ""
        for i, v in ipairs(tuple) do
            str = str .. tostring(v) .. (i < #tuple and " " or "")
        end
        createCommandOutput(holder, str, Color3.fromRGB(255, 0, 0))
        scrollToBottom()
    end

    git.replaceOutputCallback(
        printOutput,
        warnOutput,
        errOutput
    )
    arguments.replacePrint(
        printOutput
    )

    local activeEntryBox = nil

    local function promptInput(promptText, isPassword)
        local command = Instance.new("Frame")
        local start = Instance.new("TextLabel")
        local entry = Instance.new("TextBox")
        local UIListLayout = Instance.new("UIListLayout")
        
        command.Name = "prompt"
        command.Parent = holder
        command.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        command.BackgroundTransparency = 1
        command.BorderSizePixel = 0
        command.Size = UDim2.new(1, 0, 0, 18)

        UIListLayout.Parent = command
        UIListLayout.FillDirection = Enum.FillDirection.Horizontal
        UIListLayout.SortOrder = Enum.SortOrder.LayoutOrder

        start.Name = "start"
        start.Parent = command
        start.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        start.BackgroundTransparency = 1
        start.BorderSizePixel = 0
        start.Size = UDim2.new(0, 0, 1, 0)
        start.AutomaticSize = Enum.AutomaticSize.X
        start.Font = Enum.Font.Ubuntu
        start.Text = promptText .. " "
        start.TextColor3 = Color3.fromRGB(255, 255, 255)
        start.TextSize = 14
        start.TextXAlignment = Enum.TextXAlignment.Left

        entry.Name = "entry"
        entry.Parent = command
        entry.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        entry.BackgroundTransparency = 1
        entry.BorderSizePixel = 0
        entry.Selectable = false
        entry.Size = UDim2.new(1, -150, 1, 0)
        entry.Font = Enum.Font.Ubuntu
        entry.Text = ""
        entry.ClearTextOnFocus = false
        if isPassword then
            entry.ClearTextOnFocus = true
        end
        entry.TextColor3 = Color3.fromRGB(255, 255, 255)
        entry.TextSize = 14
        entry.TextXAlignment = Enum.TextXAlignment.Left

        local bindable = Instance.new("BindableEvent")
        local result = ""

        local connection
        connection = entry.FocusLost:Connect(function(enterPressed)
            if enterPressed then
                result = entry.Text
                entry.TextEditable = false
                if isPassword then entry.Text = "" end
                if connection then connection:Disconnect() end
                bindable:Fire()
            end
        end)
        
        activeEntryBox = entry
        scrollToBottom()

        task.delay(0.1, function()
            pcall(function() entry:CaptureFocus() end)
        end)

        bindable.Event:Wait()
        bindable:Destroy()
        return result
    end

    git.replacePromptCallback(promptInput)
    
    local function ensureFocus()
        if activeEntryBox then
            pcall(function() activeEntryBox:CaptureFocus() end)
        end
    end

    terminal_frame.Activated:Connect(ensureFocus)

    local originalCreate = createCommandEntry
    createCommandEntry = function(p)
        local frame = originalCreate(p)
        activeEntryBox = frame:FindFirstChild("entry")
        scrollToBottom()
        return frame
    end

    if not arguments.existingCommands["clear"] then
        arguments.createCommand("clear", function()
            for _, child in ipairs(holder:GetChildren()) do
                if child:IsA("Frame") then
                    child:Destroy()
                end
            end
        end)
    end

    createCommandEntry(holder)

    return terminal
end

function plugins.initializePlugin(plugin)
    git.setPlugin(plugin)
    local toolbar = plugin:CreateToolbar("roGit")

    local buttons = {
        -- ["GraphicalMode"] = toolbar:CreateButton("Graphical Mode", "", "rbxassetid://123456789"),
        ["BashMode"] = toolbar:CreateButton("Bash Mode", "", "rbxassetid://78663253184043")
    }

    --// Use during scripting (out of viewport)
    -- buttons.GraphicalMode.ClickableWhenViewportHidden = true
    buttons.BashMode.ClickableWhenViewportHidden = true

    --// Graphical Mode (GUI)
    -- buttons.GraphicalMode.Click:Connect(function()
    
    -- end)

    --// Bash Mode (Terminal)
    local bashTerminalGui = nil
    buttons.BashMode.Click:Connect(function()
        if not bashTerminalGui then
            bashTerminalGui = plugins.createBashTerminal(plugin)
        else
            bashTerminalGui.Enabled = not bashTerminalGui.Enabled
        end
    end)
end

return plugins