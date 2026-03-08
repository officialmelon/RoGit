--[[
Plugin (handles the plugin itself)
Creates UI for bash so far
need to implement user-friendly
]]

local plugins = {}
local arguments = require(script.Parent.arguments)
local git = require(script.Parent.git)
local remote = require(script.Parent.libs.git_remote)
local Auth = require(script.Parent.libs.localstore)
local gui = require(script.Parent.gui)

local bash = require(script.Parent.bash)

local StudioService = game:GetService("StudioService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local git_handlers = require(script.Parent.libs.git_handlers)

local user = "User"
pcall(function()
    user = Players:GetNameFromUserIdAsync(StudioService:GetUserId())
end)
local name = game.Name

local commandHistory = {}

--// In-Game check
if not RunService:IsStudio() then 
    return
end

--[[
Gui/"Desktop" mode related stuff
]]

function initDesktop(gui)
    gui = gui.PluginGui

    --// Runs on start (or when initalized)

    --// Create change item (what we are tracking)
    local function createChangeItem(parentList, statusChar, filePath)
        local statusColors = {
            ["M"] = Color3.fromRGB(210, 153, 34),  -- Modified
            ["A"] = Color3.fromRGB(63, 185, 80),   -- Added
            ["D"] = Color3.fromRGB(248, 81, 73),   -- Deleted
            ["U"] = Color3.fromRGB(139, 148, 158)  -- Untracked
        }

        local Frame = Instance.new("Frame")
        Frame.Parent = parentList
        Frame.BackgroundTransparency = 1.000
        Frame.Size = UDim2.new(1, 0, 0, 28)

        local HighlightFrame = Instance.new("Frame")
        HighlightFrame.Parent = Frame
        HighlightFrame.BackgroundColor3 = Color3.fromRGB(48, 54, 61)
        HighlightFrame.BackgroundTransparency = 1.000
        HighlightFrame.Position = UDim2.new(0, 4, 0, 0)
        HighlightFrame.Size = UDim2.new(1, -8, 1, 0)

        local UICorner = Instance.new("UICorner")
        UICorner.CornerRadius = UDim.new(0, 4)
        UICorner.Parent = HighlightFrame

        local StatusText = Instance.new("TextLabel")
        StatusText.Parent = Frame
        StatusText.BackgroundTransparency = 1.000
        StatusText.Position = UDim2.new(0, 8, 0, 0)
        StatusText.Size = UDim2.new(0, 20, 1, 0)
        StatusText.Font = Enum.Font.Ubuntu
        StatusText.Text = "<b>" .. statusChar .. "</b>"
        StatusText.TextColor3 = statusColors[statusChar] or Color3.fromRGB(230, 237, 243)
        StatusText.TextSize = 12.000
        StatusText.RichText = true

        local FilePathText = Instance.new("TextLabel")
        FilePathText.Parent = Frame
        FilePathText.BackgroundTransparency = 1.000
        FilePathText.Position = UDim2.new(0, 28, 0, 0)
        FilePathText.Size = UDim2.new(1, -36, 1, 0)
        FilePathText.Font = Enum.Font.Ubuntu
        FilePathText.Text = filePath
        FilePathText.TextColor3 = Color3.fromRGB(230, 237, 243)
        FilePathText.TextSize = 13.000
        FilePathText.TextXAlignment = Enum.TextXAlignment.Left

        return Frame
    end

    --// populate branch list with defined item
    local function createBranchItem(parentList, branchName, isCurrentBranch)
        local BranchBtn = Instance.new("TextButton")
        BranchBtn.Name = branchName
        BranchBtn.Parent = parentList
        BranchBtn.BackgroundColor3 = Color3.fromRGB(33, 38, 45)
        BranchBtn.BackgroundTransparency = isCurrentBranch and 0.500 or 1.000
        BranchBtn.Size = UDim2.new(1, 0, 0, 32)
        BranchBtn.ZIndex = 62
        BranchBtn.Text = ""

        local BranchIcon = Instance.new("ImageLabel")
        BranchIcon.Name = "Icon"
        BranchIcon.Parent = BranchBtn
        BranchIcon.BackgroundTransparency = 1.000
        BranchIcon.Position = UDim2.new(0, 22, 0.5, -6)
        BranchIcon.Size = UDim2.new(0, 12, 0, 12)
        BranchIcon.ZIndex = 63
        BranchIcon.Image = "rbxassetid://93856691842639"

        local CheckIcon = Instance.new("TextLabel")
        CheckIcon.Name = "Check"
        CheckIcon.Parent = BranchBtn
        CheckIcon.BackgroundTransparency = 1.000
        CheckIcon.Position = UDim2.new(0, 6, 0.5, -6)
        CheckIcon.Size = UDim2.new(0, 12, 0, 12)
        CheckIcon.ZIndex = 63
        CheckIcon.Font = Enum.Font.Ubuntu
        CheckIcon.Text = isCurrentBranch and "✓" or ""
        CheckIcon.TextColor3 = Color3.fromRGB(230, 237, 243)
        CheckIcon.TextSize = 12.000

        local BranchNameText = Instance.new("TextLabel")
        BranchNameText.Name = "Name"
        BranchNameText.Parent = BranchBtn
        BranchNameText.BackgroundTransparency = 1.000
        BranchNameText.Position = UDim2.new(0, 40, 0, 0)
        BranchNameText.Size = UDim2.new(1, -44, 1, 0)
        BranchNameText.ZIndex = 63
        BranchNameText.Font = Enum.Font.Ubuntu
        BranchNameText.Text = isCurrentBranch and "<b>" .. branchName .. "</b>" or branchName
        BranchNameText.TextColor3 = Color3.fromRGB(230, 237, 243)
        BranchNameText.TextSize = 13.000

        BranchNameText.TextXAlignment = Enum.TextXAlignment.Left
        BranchNameText.RichText = true

        BranchBtn.AutoButtonColor = false
        BranchBtn.MouseEnter:Connect(function()
            BranchBtn.BackgroundColor3 = Color3.fromRGB(48, 54, 61)
            BranchBtn.BackgroundTransparency = 0
        end)
        BranchBtn.MouseLeave:Connect(function()
            BranchBtn.BackgroundColor3 = Color3.fromRGB(33, 38, 45)
            BranchBtn.BackgroundTransparency = isCurrentBranch and 0.500 or 1.000
        end)

        return BranchBtn
    end

    --// show modal message!
    local function showModalMessage(parentModal, title, message)
        local ModalInner = parentModal:FindFirstChild("Modal")
        local ProblemFrame = ModalInner:FindFirstChild("Problem")
        
        --// clear out old text if any.
        for _, child in ipairs(ModalInner:GetChildren()) do
            if child.Name == "Title" then child:Destroy() end
        end

        for _, child in ipairs(ProblemFrame:GetChildren()) do
            if child:IsA("TextLabel") then child:Destroy() end
        end

        local TitleLabel = Instance.new("TextLabel")
        TitleLabel.Name = "Title"
        TitleLabel.Parent = ModalInner
        TitleLabel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        TitleLabel.BackgroundTransparency = 1.000
        TitleLabel.LayoutOrder = 1
        TitleLabel.Size = UDim2.new(1, 0, 0, 20)
        TitleLabel.Font = Enum.Font.Ubuntu
        TitleLabel.Text = "<b>" .. title .. "</b>"
        TitleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        TitleLabel.TextSize = 14.000
        TitleLabel.ZIndex = 122
        TitleLabel.RichText = true

        local MessageLabel = Instance.new("TextLabel")
        MessageLabel.Parent = ProblemFrame
        MessageLabel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        MessageLabel.BackgroundTransparency = 1.000
        MessageLabel.Size = UDim2.new(1, 0, 0, 0)
        MessageLabel.AutomaticSize = Enum.AutomaticSize.Y
        MessageLabel.Font = Enum.Font.Ubuntu
        MessageLabel.Text = message
        MessageLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
        MessageLabel.TextSize = 13.000
        MessageLabel.TextWrapped = true
        MessageLabel.TextYAlignment = Enum.TextYAlignment.Center
        MessageLabel.ZIndex = 122

        parentModal.Visible = true
    end

    local function populateBranchList()
        local branchContainer = gui.BranchDropdown.BranchList

        for _, child in ipairs(branchContainer:GetChildren()) do
            if child:IsA("TextButton") then
                child:Destroy()
            end
        end

        local branches = git_handlers.get_branches()
        local currBranch = git_handlers.get_current_branch()

        for _, branch in ipairs(branches) do
            local isCurr = (branch == currBranch)
            local branchBtn = createBranchItem(branchContainer, branch, isCurr)
        
            branchBtn.Activated:Connect(function()
                local succ, err = pcall(function()
                    arguments.execute("git", "checkout", branch)
                end)

                --// modal
                if not succ then
                    showModalMessage(gui.Modal, "Couldn't checkout branch!", err:match(":%d+: (.+)$") or err)
                end
            end)
        end

        gui.Header.BranchBtn.Text = currBranch or "main"
        gui.Body.BottomArea.ActionsRow.CommitBtn.Text = "<b>Commit to " .. (currBranch or "main") .. "</b>"
    end

    local function populateChangesList()
        local list = gui.Body.ChangesArea.ChangesBg.List
        local label = gui.Body.ChangesArea.ChangesLabel
        local commitBtn = gui.Body.BottomArea.ActionsRow.CommitBtn
        
        local changes = git.get_changes()
        
        local existing = {}
        for _, child in ipairs(list:GetChildren()) do
            if child:IsA("Frame") and child.Name ~= "UIListLayout" then
                existing[child.Name] = child
            end
        end

        local changes_map = {}
        for _, change in ipairs(changes) do
            -- Use the path as the instance name for diffing UI
            changes_map[change.path] = change
            
            if not existing[change.path] then
                local item = createChangeItem(list, change.status, change.path)
                item.Name = change.path
            else
                -- recreate if status changed? We can just leave it for now since status rarely changes from under it
                -- (unless it goes from U -> A, but M -> M is common)
            end
        end

        for path, child in pairs(existing) do
            if not changes_map[path] then
                child:Destroy()
            end
        end
        
        if #changes > 0 then
            commitBtn.BackgroundColor3 = Color3.fromRGB(35, 134, 54)
            commitBtn.AutoButtonColor = true
        else
            commitBtn.BackgroundColor3 = Color3.fromRGB(48, 54, 61)
            commitBtn.AutoButtonColor = false
        end

        label.Text = "<b>Changes</b>   <font color='#8b949e'>" .. tostring(#changes) .. "</font>"
    end

    --// dismiss generic modal (Global)
    gui.Modal:FindFirstChild("Modal").Options.OkayBtn.Activated:Connect(function()
        gui.Modal.Visible = false
    end)

    local function onReady()
        gui.InitRepoView.Visible = false

        --// Branch Related Stuff below!

        --// select branch/dropdown
        gui.Header.BranchBtn.Activated:Connect(function()
            populateBranchList()
            gui.BranchDropdown.Visible = not gui.BranchDropdown.Visible
        end)

        --// branch creation is now visible!!11!
        local addBranchBtn = gui.BranchDropdown.AddBranchBtn
        addBranchBtn.AutoButtonColor = false
        addBranchBtn.MouseEnter:Connect(function()
            addBranchBtn.BackgroundColor3 = Color3.fromRGB(48, 54, 61)
            addBranchBtn.BackgroundTransparency = 0
        end)
        addBranchBtn.MouseLeave:Connect(function()
            addBranchBtn.BackgroundTransparency = 1
        end)

        addBranchBtn.Activated:Connect(function()
            gui.CreateBranchModal.ModalInner.Body.NameBg.NameInput.Text = ""
            gui.CreateBranchModal.Visible = true
        end)

        --// cancel creation
        gui.CreateBranchModal.ModalInner.Body.Actions.CancelBtn.Activated:Connect(function()
            gui.CreateBranchModal.Visible = false
        end)

        --// create branch
        gui.CreateBranchModal.ModalInner.Body.Actions.CreateBtn.Activated:Connect(function()
            if #gui.CreateBranchModal.ModalInner.Body.NameBg.NameInput.Text < 1 then
                return
            end
            
            local succ, err = pcall(function()
                arguments.execute("git", "branch", gui.CreateBranchModal.ModalInner.Body.NameBg.NameInput.Text)
            end)

            --// cant create!
            if not succ then
                showModalMessage(gui.Modal, "Couldn't create branch!", err:match(":%d+: (.+)$") or err)
                gui.CreateBranchModal.Visible = false
            end
            populateBranchList()
        end)

        --// discard changes
        local discardBtn = gui.Body.ChangesArea.ConfigsRow.DiscardBtn
        discardBtn.MouseEnter:Connect(function()
            discardBtn.BackgroundColor3 = Color3.fromRGB(48, 54, 61)
        end)
        discardBtn.MouseLeave:Connect(function()
            discardBtn.BackgroundColor3 = Color3.fromRGB(33, 38, 45)
        end)
        discardBtn.Activated:Connect(function()
            local succ, err = pcall(function()
                arguments.execute("git", "restore", ".")
            end)
            if succ then
                populateChangesList()
                showModalMessage(gui.Modal, "Discarded", "Successfully reverted all uncommitted changes.")
            else
                showModalMessage(gui.Modal, "Discard Failed!", err:match(":%d+: (.+)$") or err)
            end
        end)

        --// open settings
        local settingsBtn = gui.Header.SettingsBtn
        settingsBtn.MouseEnter:Connect(function()
            settingsBtn.BackgroundColor3 = Color3.fromRGB(48, 54, 61)
        end)
        settingsBtn.MouseLeave:Connect(function()
            settingsBtn.BackgroundColor3 = Color3.fromRGB(33, 38, 45)
        end)
        settingsBtn.Activated:Connect(function()
            local cfg = bash.getFileContents(bash.getGitFolderRoot(), "config") or ""
            local url = cfg:match('remote "origin".-\n%s*url%s*=%s*([^\r\n]+)')
            if url then
                gui.SettingsView.ModalInner.Body.OriginInputBg.OriginInput.Text = url
            end

            -- Only load name, NEVER automatically load a raw token into the UI (safety precaution)!
            local currentUser = Auth.ACTIVE_PLUGIN and Auth.ACTIVE_PLUGIN:GetSetting("user.name") or ""
            gui.SettingsView.ModalInner.Body.UsernameInputBg.UsernameInput.Text = currentUser

            gui.SettingsView.Visible = not gui.SettingsView.Visible
        end)

        --// save settings
        gui.SettingsView.ModalInner.Body.ActionsRow.SaveBtn.Activated:Connect(function()
            local url = gui.SettingsView.ModalInner.Body.OriginInputBg.OriginInput.Text
            if url and url ~= "" then
                local succ = pcall(function() arguments.execute("git", "remote", "add", "origin", url) end)
                if not succ then
                    pcall(function() arguments.execute("git", "remote", "set-url", "origin", url) end)
                end
            end

            local userSet = gui.SettingsView.ModalInner.Body.UsernameInputBg.UsernameInput.Text
            local tokenSet = gui.SettingsView.ModalInner.Body.TokenInputBg.TokenInput.Text

            if Auth.ACTIVE_PLUGIN then
                if userSet ~= "" then Auth.ACTIVE_PLUGIN:SetSetting("user.name", userSet) end
                if tokenSet ~= "" then Auth.ACTIVE_PLUGIN:SetSetting("user.token", tokenSet) end
            end

            gui.SettingsView.ModalInner.Body.TokenInputBg.TokenInput.Text = ""
            gui.SettingsView.Visible = false
            showModalMessage(gui.Modal, "Settings Updated", "Your repository config and auth details have been updated successfully.")
        end)

        --// cancel settings
        gui.SettingsView.ModalInner.Body.ActionsRow.CloseBtn.Activated:Connect(function()
            gui.SettingsView.Visible = false
        end)

        --// commit
        gui.Body.BottomArea.ActionsRow.CommitBtn.Activated:Connect(function()
            local changes = git.get_changes()
            if #changes == 0 then return end
            
            local summaryText = gui.Body.BottomArea.InputBg.Summary.Text
            local descText = gui.Body.BottomArea.InputBg.Description.Text
            
            if not summaryText or summaryText == "" then
                showModalMessage(gui.Modal, "Cannot commit!", "Commit summary is required.")
                return
            end

            local fullMessage = summaryText
            if descText and descText ~= "" then
                fullMessage = fullMessage .. "\n\n" .. descText
            end

            local succ, err = pcall(function()
                arguments.execute("git", "add", ".")
                arguments.execute("git", "commit", "-m", fullMessage)
            end)

            if succ then
                -- clear outputs and update tracking
                gui.Body.BottomArea.InputBg.Summary.Text = ""
                gui.Body.BottomArea.InputBg.Description.Text = ""
                populateChangesList()
            else
                showModalMessage(gui.Modal, "Commit Failed!", err:match(":%d+: (.+)$") or err)
            end
        end)

        --// pull
        gui.Body.BottomArea.ActionsRow.PullBtn.Activated:Connect(function()
            local succ, err = pcall(function()
                arguments.execute("git", "pull")
            end)

            if succ then
                populateChangesList()
                showModalMessage(gui.Modal, "Success", "Successfully pulled from remote!")
            else
                showModalMessage(gui.Modal, "Pull Failed!", err:match(":%d+: (.+)$") or err)
            end
        end)

        --// push
        gui.Body.BottomArea.ActionsRow.PushBtn.Activated:Connect(function()
            local succ, err = pcall(function()
                arguments.execute("git", "push")
            end)

            if succ then
                showModalMessage(gui.Modal, "Success", "Successfully pushed to remote!")
            else
                showModalMessage(gui.Modal, "Push Failed!", err:match(":%d+: (.+)$") or err)
            end
        end)

        --// NOW WE DO STUFF!
        populateBranchList()
        populateChangesList()

        --// check changes very 5 seconds!
        task.spawn(function()
            while true do
                task.wait(5)
                pcall(populateChangesList)
            end
        end)
    end

    --// Check is initialized?
    if not bash.getGitFolderRoot() then
        --// TODO: Add ui feedback when initalized
        gui.InitRepoView.Visible = true

        --// user can choose to clone OR init
        gui.InitRepoView.CenterGroup.InitBtn.Activated:Connect(function()
            arguments.execute("git", "init")
            onReady()
        end)

        --// clone in
        gui.InitRepoView.CenterGroup.CloneBtn.Activated:Connect(function()
            arguments.execute("git", "clone", gui.InitRepoView.CenterGroup.CloneUrlBg.CloneUrl.Text)
            onReady()
        end)
    else -- Continue!
        onReady()
    end
end

function plugins.CreateUserFriendlyUI(plugin)
    --// Create terminal
    local window = DockWidgetPluginGuiInfo.new(
        Enum.InitialDockState.Left,
        true,
        false,
        -- Default of floating window
        1000,
        500,
        -- Default min w/h
        200,
        500
    )

    local user_friendly = plugin:CreateDockWidgetPluginGui("RoGitDesktopMode", window)
    user_friendly.Title = "RoGit"

    user_friendly.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    gui.create(user_friendly)

    --// Setup full behavior
    
    initDesktop(user_friendly)

    return user_friendly
end

--[[
Down here is the Terminal related stuff!
]]

--[[
Creates output of commands.
]]
function createCommandOutput(parent, text, optionalColor)
    local MAX_TEXT_LENGTH = 150000
    if #text > MAX_TEXT_LENGTH then
        local firstElement = nil
        for i = 1, #text, MAX_TEXT_LENGTH do
            local chunk = string.sub(text, i, i + MAX_TEXT_LENGTH - 1)
            local elm = createCommandOutput(parent, chunk, optionalColor)
            if not firstElement then firstElement = elm end
        end
        return firstElement
    end

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

    if parent and parent.Name == "commands_holder" then
        local children = parent:GetChildren()
        local uiFrames = {}
        for _, child in ipairs(children) do
            if child:IsA("Frame") then
                table.insert(uiFrames, child)
            end
        end
        local MAX_LINES = 400
        if #uiFrames > MAX_LINES then
            for i = 1, #uiFrames - MAX_LINES do
                uiFrames[i]:Destroy()
            end
        end
    end

    return output
end

--[[
Creates a input/entry (interactive) command prompt.
]]
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

    local promptText = user .. "@" .. name .. ">"
    local textWidth = game:GetService("TextService"):GetTextSize(promptText, 14, Enum.Font.Ubuntu, Vector2.new(10000, 100)).X + 4

    start.Size = UDim2.new(0, textWidth, 1, 0)
    start.Font = Enum.Font.Ubuntu
    start.Text = promptText
    start.TextColor3 = Color3.fromRGB(255, 255, 255)
    start.TextSize = 14.000
    start.TextXAlignment = Enum.TextXAlignment.Left

    entry.Name = "entry"
    entry.Parent = command
    entry.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    entry.BackgroundTransparency = 1.000
    entry.BorderSizePixel = 0
    entry.Selectable = false
    entry.Size = UDim2.new(1, -textWidth, 1, 0)
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

--[[
Handles the callback of the interactive commands.
]]
function handleCommandCallback(TextBox:TextBox, parent)
    local UserInputService = game:GetService("UserInputService")
local git_handlers = require(ServerScriptService.Server.libs.git_handlers)
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
            
            local toProcess = {}
            local idx = 1
            while idx <= #text do
                local c = text:sub(idx, idx)
                if c:match("%s") then
                    idx += 1
                elseif c == '"' or c == "'" then
                    local end_idx = text:find(c, idx + 1, true)
                    if end_idx then
                        table.insert(toProcess, text:sub(idx + 1, end_idx - 1))
                        idx = end_idx + 1
                    else
                        table.insert(toProcess, text:sub(idx + 1))
                        break
                    end
                else
                    local match_end = text:find("[%s\"']", idx)
                    if match_end then
                        table.insert(toProcess, text:sub(idx, match_end - 1))
                        idx = match_end
                    else
                        table.insert(toProcess, text:sub(idx))
                        break
                    end
                end
            end
            
            if #toProcess == 0 then return end
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

--[[
Create the bash terminal gui of the plugin.
]]
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

    --// Replace output calls with custom terminal ones.
    git.replaceOutputCallback(
        printOutput,
        warnOutput,
        errOutput
    )
    arguments.replacePrint(
        printOutput
    )
    remote.print = printOutput
    remote.warn = warnOutput
    remote.error = errOutput
    Auth.print = printOutput


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

--[[
self-explanatory, initialzes the plugin itself.
]]
function plugins.initializePlugin(plugin)
    git.setPlugin(plugin)
    local toolbar = plugin:CreateToolbar("roGit")

    local buttons = {
        ["BashMode"] = toolbar:CreateButton("Git Terminal", "", "rbxassetid://78663253184043"),
        ["UserFriendly"] = toolbar:CreateButton("RoGit", "", "rbxassetid://93856691842639")
    }
    buttons.BashMode.ClickableWhenViewportHidden = true
    buttons.UserFriendly.ClickableWhenViewportHidden = true

    --// Bash Mode (Terminal)
    local bashTerminalGui = nil
    local userFriendlyGui = nil
    
    buttons.BashMode.Click:Connect(function()
        if not bashTerminalGui then
            bashTerminalGui = plugins.createBashTerminal(plugin)
        else
            bashTerminalGui.Enabled = not bashTerminalGui.Enabled
        end
    end)

    buttons.UserFriendly.Click:Connect(function()
        if not userFriendlyGui then
            userFriendlyGui = plugins.CreateUserFriendlyUI(plugin)
        else
            userFriendlyGui.Enabled = not userFriendlyGui.Enabled
        end
    end)
end

return plugins