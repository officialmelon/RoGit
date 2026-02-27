local plugins = {}
local arguments = require(script.Parent.arguments)
local git = require(script.Parent.git)

function handleCommandCallback(TextBox:TextBox, parent)
    TextBox.InputBegan:Connect(function(input:InputObject)
        if input.KeyCode ~= Enum.KeyCode.Return then
            return
        end

        -- Clean Input
        local toProcess = string.split(TextBox.Text, " ")

        -- Handle
        arguments.executeArgument(table.unpack(toProcess))

        -- New arg
        createCommandEntry(parent)
    end)
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
    command.BorderColor3 = Color3.fromRGB(0, 0, 0)
    command.BorderSizePixel = 0
    command.Size = UDim2.new(1, 0, -0.0356347449, 50)

    UIListLayout.Parent = command
    UIListLayout.FillDirection = Enum.FillDirection.Horizontal
    UIListLayout.SortOrder = Enum.SortOrder.LayoutOrder

    start.Name = "start"
    start.Parent = command
    start.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    start.BackgroundTransparency = 1.000
    start.BorderColor3 = Color3.fromRGB(0, 0, 0)
    start.BorderSizePixel = 0
    start.Size = UDim2.new(0, 172, 0, 18)
    start.Font = Enum.Font.Ubuntu
    start.Text = "thatconvictedfelon@RoGit >"
    start.TextColor3 = Color3.fromRGB(255, 255, 255)
    start.TextSize = 14.000
    start.TextXAlignment = Enum.TextXAlignment.Left

    entry.Name = "entry"
    entry.Parent = command
    entry.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    entry.BackgroundTransparency = 1.000
    entry.BorderColor3 = Color3.fromRGB(0, 0, 0)
    entry.BorderSizePixel = 0
    entry.Position = UDim2.new(0.213447168, 0, 0, 0)
    entry.Selectable = false
    entry.Size = UDim2.new(0, 200, 0, 18)
    entry.Font = Enum.Font.Ubuntu
    entry.Text = ""
    entry.TextColor3 = Color3.fromRGB(255, 255, 255)
    entry.TextSize = 14.000
    entry.TextXAlignment = Enum.TextXAlignment.Left

    handleCommandCallback(entry, parent)

    return command
end

function plugins.createBashTerminal()

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

    local terminal = Instance.new("ScreenGui")
    terminal.Name = "BashTerminal"
    terminal.Parent = plugin:GetGuiObjects()

    local terminal_frame = Instance.new("Frame")
    terminal_frame.BackgroundColor3 = Color3.fromRGB(0,0,0)
    terminal_frame.Size = UDim2.new(1,0,1,0)
    terminal_frame.Position = UDim2.new(0,0,1,0)
    terminal_frame.AnchorPoint = Vector2.new(0,1)
    terminal_frame.Parent = terminal

    local holder = Instance.new("Folder")
    holder.Name = "commands_holder"
    holder.Parent = terminal_frame

    local CommandsListLayout = Instance.new("UIListLayout")
    CommandsListLayout.Parent = holder
    CommandsListLayout.Padding = UDim.new(0,5)
    CommandsListLayout.SortOrder = Enum.SortOrder.LayoutOrder

    createCommandEntry(holder)
end

function plugins.initializePlugin()
    local toolbar = plugin:CreateToolbar("roGit")

    local buttons = {
        ["GraphicalMode"] = toolbar:CreateButton("Graphical Mode", "", "rbxassetid://123456789"),
        ["BashMode"] = toolbar:CreateButton("Bash Mode", "", "rbxassetid://123456789")
    }

    --// Use during scripting (out of viewport)
    buttons.GraphicalMode.ClickableWhenViewportHidden = true
    buttons.BashMode.ClickableWhenViewportHidden = true

    --// Graphical Mode (GUI)
    buttons.GraphicalMode.Click:Connect(function()
    
    end)

    --// Bash Mode (Terminal)
    buttons.BashMode.Click:Connect(function()
        plugins.createBashTerminal()
    end)
end

return plugins