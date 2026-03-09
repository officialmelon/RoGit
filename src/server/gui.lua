local gui = {}

--[[
Okay so I designed out a plugin in Studio then converted it from an Instance to code.
SO its VERY messy here lol, however I dont think it needs any changes for now.

I will be refactoring this in the future however.
]]

function gui.create(Parent)
    local Plugin = Instance.new("Frame")
    Plugin.Name = "PluginGui"
    Plugin.Parent = Parent
    Plugin.BackgroundColor3 = Color3.fromRGB(13, 17, 23)
    Plugin.BorderSizePixel = 0
    Plugin.Size = UDim2.new(1, 0, 1, 0)

    local Header = Instance.new("Frame")
    Header.Name = "Header"
    Header.Parent = Plugin
    Header.BackgroundColor3 = Color3.fromRGB(1, 4, 9)
    Header.BorderSizePixel = 0
    Header.Size = UDim2.new(1, 0, 0, 56)

    local Divider = Instance.new("Frame")
    Divider.Name = "Divider"
    Divider.Parent = Header
    Divider.BackgroundColor3 = Color3.fromRGB(48, 54, 61)
    Divider.BorderSizePixel = 0
    Divider.Position = UDim2.new(0, 0, 1, -1)
    Divider.Size = UDim2.new(1, 0, 0, 1)

    local Title = Instance.new("TextLabel")
    Title.Name = "Title"
    Title.Parent = Header
    Title.BackgroundTransparency = 1.000
    Title.Position = UDim2.new(0, 16, 0, 0)
    Title.Size = UDim2.new(0, 100, 1, -1)
    Title.Font = Enum.Font.Ubuntu
    Title.Text = "<b>RoGit</b>"
    Title.TextColor3 = Color3.fromRGB(230, 237, 243)
    Title.TextSize = 16.000
    Title.TextXAlignment = Enum.TextXAlignment.Left

    local BranchBtn = Instance.new("TextButton")
    BranchBtn.Name = "BranchBtn"
    BranchBtn.Parent = Header
    BranchBtn.AnchorPoint = Vector2.new(1, 0.5)
    BranchBtn.BackgroundColor3 = Color3.fromRGB(33, 38, 45)
    BranchBtn.Position = UDim2.new(0.977220953, -16, 0.5, 0)
    BranchBtn.Size = UDim2.new(0, 0, 0, 26)
    BranchBtn.AutomaticSize = Enum.AutomaticSize.X
    BranchBtn.Font = Enum.Font.Ubuntu
    BranchBtn.Text = "main"
    BranchBtn.TextColor3 = Color3.fromRGB(230, 237, 243)
    BranchBtn.TextSize = 13.000
    BranchBtn.TextXAlignment = Enum.TextXAlignment.Right

    local UICorner = Instance.new("UICorner")
    UICorner.CornerRadius = UDim.new(0, 6)
    UICorner.Parent = BranchBtn

    local BranchIcon = Instance.new("ImageLabel")
    BranchIcon.Name = "BranchIcon"
    BranchIcon.Parent = BranchBtn
    BranchIcon.BackgroundTransparency = 1.000
    BranchIcon.Position = UDim2.new(0, -18, 0.5, -7)
    BranchIcon.Size = UDim2.new(0, 14, 0, 14)
    BranchIcon.Image = "rbxassetid://93856691842639"

    local SettingsBtn = Instance.new("TextButton")
    SettingsBtn.Name = "SettingsBtn"
    SettingsBtn.Parent = Header
    SettingsBtn.AnchorPoint = Vector2.new(1, 0.5)
    SettingsBtn.BackgroundColor3 = Color3.fromRGB(33, 38, 45)
    SettingsBtn.Position = UDim2.new(0.977220953, -100, 0.5, 0)
    SettingsBtn.Size = UDim2.new(0, 60, 0, 26)
    SettingsBtn.Font = Enum.Font.Ubuntu
    SettingsBtn.Text = "Settings"
    SettingsBtn.TextColor3 = Color3.fromRGB(230, 237, 243)
    SettingsBtn.TextSize = 12.000
    SettingsBtn.AutoButtonColor = false

    local UICorner_s = Instance.new("UICorner")
    UICorner_s.CornerRadius = UDim.new(0, 4)
    UICorner_s.Parent = SettingsBtn

    local UIPadding = Instance.new("UIPadding")
    UIPadding.Parent = BranchBtn
    UIPadding.PaddingLeft = UDim.new(0, 26)
    UIPadding.PaddingRight = UDim.new(0, 10)

    local Body = Instance.new("Frame")
    Body.Name = "Body"
    Body.Parent = Plugin
    Body.BackgroundTransparency = 1.000
    Body.Position = UDim2.new(0, 0, 0, 56)
    Body.Size = UDim2.new(1, 0, 1, -56)

    local ChangesArea = Instance.new("Frame")
    ChangesArea.Name = "ChangesArea"
    ChangesArea.Parent = Body
    ChangesArea.BackgroundTransparency = 1.000
    ChangesArea.Size = UDim2.new(1, 0, 1, -170)

    local UIPadding_2 = Instance.new("UIPadding")
    UIPadding_2.Parent = ChangesArea
    UIPadding_2.PaddingBottom = UDim.new(0, 12)
    UIPadding_2.PaddingLeft = UDim.new(0, 16)
    UIPadding_2.PaddingRight = UDim.new(0, 16)
    UIPadding_2.PaddingTop = UDim.new(0, 16)

    local ChangesLabel = Instance.new("TextLabel")
    ChangesLabel.Name = "ChangesLabel"
    ChangesLabel.Parent = ChangesArea
    ChangesLabel.BackgroundTransparency = 1.000
    ChangesLabel.Size = UDim2.new(1, 0, 0, 20)
    ChangesLabel.Font = Enum.Font.Ubuntu
    ChangesLabel.Text = "<b>Changes</b>   <font color='#8b949e'>0</font>"
    ChangesLabel.TextColor3 = Color3.fromRGB(230, 237, 243)
    ChangesLabel.TextSize = 14.000
    ChangesLabel.TextXAlignment = Enum.TextXAlignment.Left
    ChangesLabel.RichText = true

    local ConfigsRow = Instance.new("Frame")
    ConfigsRow.Name = "ConfigsRow"
    ConfigsRow.Parent = ChangesArea
    ConfigsRow.BackgroundTransparency = 1.000
    ConfigsRow.Position = UDim2.new(1, -200, 0, -2)
    ConfigsRow.Size = UDim2.new(0, 200, 0, 24)
    
    local UIListLayout_Configs = Instance.new("UIListLayout")
    UIListLayout_Configs.Parent = ConfigsRow
    UIListLayout_Configs.FillDirection = Enum.FillDirection.Horizontal
    UIListLayout_Configs.HorizontalAlignment = Enum.HorizontalAlignment.Right
    UIListLayout_Configs.SortOrder = Enum.SortOrder.LayoutOrder
    UIListLayout_Configs.Padding = UDim.new(0, 8)

    local DiscardBtn = Instance.new("TextButton")
    DiscardBtn.Name = "DiscardBtn"
    DiscardBtn.Parent = ConfigsRow
    DiscardBtn.BackgroundColor3 = Color3.fromRGB(33, 38, 45)
    DiscardBtn.Size = UDim2.new(0, 56, 1, 0)
    DiscardBtn.LayoutOrder = 1
    DiscardBtn.Font = Enum.Font.Ubuntu
    DiscardBtn.Text = "Discard"
    DiscardBtn.TextColor3 = Color3.fromRGB(255, 123, 114)
    DiscardBtn.TextSize = 12.000
    DiscardBtn.AutoButtonColor = false

    local UICorner_d = Instance.new("UICorner")
    UICorner_d.CornerRadius = UDim.new(0, 4)
    UICorner_d.Parent = DiscardBtn

    local ChangesBg = Instance.new("Frame")
    ChangesBg.Name = "ChangesBg"
    ChangesBg.Parent = ChangesArea
    ChangesBg.BackgroundColor3 = Color3.fromRGB(1, 4, 9)
    ChangesBg.Position = UDim2.new(0, 0, 0, 28)
    ChangesBg.Size = UDim2.new(1, 0, 1, -28)

    local UICorner_2 = Instance.new("UICorner")
    UICorner_2.CornerRadius = UDim.new(0, 6)
    UICorner_2.Parent = ChangesBg

    local List = Instance.new("ScrollingFrame")
    List.Name = "List"
    List.Parent = ChangesBg
    List.BackgroundTransparency = 1.000
    List.BorderSizePixel = 0
    List.Position = UDim2.new(0, 2, 0, 2)
    List.Size = UDim2.new(1, -4, 1, -4)
    List.ScrollBarThickness = 4

    local UIListLayout = Instance.new("UIListLayout")
    UIListLayout.Parent = List
    UIListLayout.SortOrder = Enum.SortOrder.LayoutOrder



    local BottomArea = Instance.new("Frame")
    BottomArea.Name = "BottomArea"
    BottomArea.Parent = Body
    BottomArea.BackgroundColor3 = Color3.fromRGB(13, 17, 23)
    BottomArea.BorderSizePixel = 0
    BottomArea.Position = UDim2.new(0, 0, 1, -170)
    BottomArea.Size = UDim2.new(1, 0, 0, 170)

    local Divider_2 = Instance.new("Frame")
    Divider_2.Name = "Divider"
    Divider_2.Parent = BottomArea
    Divider_2.BackgroundColor3 = Color3.fromRGB(48, 54, 61)
    Divider_2.BorderSizePixel = 0
    Divider_2.Position = UDim2.new(0, -16, 0, -16)
    Divider_2.Size = UDim2.new(1, 32, 0, 1)

    local UIPadding_3 = Instance.new("UIPadding")
    UIPadding_3.Parent = BottomArea
    UIPadding_3.PaddingBottom = UDim.new(0, 16)
    UIPadding_3.PaddingLeft = UDim.new(0, 16)
    UIPadding_3.PaddingRight = UDim.new(0, 16)
    UIPadding_3.PaddingTop = UDim.new(0, 16)

    local InputBg = Instance.new("Frame")
    InputBg.Name = "InputBg"
    InputBg.Parent = BottomArea
    InputBg.BackgroundColor3 = Color3.fromRGB(1, 4, 9)
    InputBg.Size = UDim2.new(1, 0, 0, 72)

    local UICorner_6 = Instance.new("UICorner")
    UICorner_6.CornerRadius = UDim.new(0, 6)
    UICorner_6.Parent = InputBg

    local Summary = Instance.new("TextBox")
    Summary.Name = "Summary"
    Summary.Parent = InputBg
    Summary.BackgroundTransparency = 1.000
    Summary.Position = UDim2.new(0, 10, 0, 2)
    Summary.Size = UDim2.new(1, -20, 0, 28)
    Summary.ClearTextOnFocus = false
    Summary.Font = Enum.Font.Ubuntu
    Summary.PlaceholderColor3 = Color3.fromRGB(139, 148, 158)
    Summary.PlaceholderText = "Summary (required)"
    Summary.Text = ""
    Summary.TextColor3 = Color3.fromRGB(230, 237, 243)
    Summary.TextSize = 13.000
    Summary.TextXAlignment = Enum.TextXAlignment.Left

    local Frame_7 = Instance.new("Frame")
    Frame_7.Parent = InputBg
    Frame_7.BackgroundColor3 = Color3.fromRGB(48, 54, 61)
    Frame_7.BorderSizePixel = 0
    Frame_7.Position = UDim2.new(0, 0, 0, 32)
    Frame_7.Size = UDim2.new(1, 0, 0, 1)

    local Description = Instance.new("TextBox")
    Description.Name = "Description"
    Description.Parent = InputBg
    Description.BackgroundTransparency = 1.000
    Description.Position = UDim2.new(0, 10, 0, 36)
    Description.Size = UDim2.new(1, -20, 1, -36)
    Description.ClearTextOnFocus = false
    Description.Font = Enum.Font.Ubuntu
    Description.PlaceholderColor3 = Color3.fromRGB(139, 148, 158)
    Description.PlaceholderText = "Description"
    Description.Text = ""
    Description.TextColor3 = Color3.fromRGB(230, 237, 243)
    Description.TextSize = 12.000
    Description.TextWrapped = true
    Description.TextXAlignment = Enum.TextXAlignment.Left
    Description.TextYAlignment = Enum.TextYAlignment.Top

    local ActionsRow = Instance.new("Frame")
    ActionsRow.Name = "ActionsRow"
    ActionsRow.Parent = BottomArea
    ActionsRow.BackgroundTransparency = 1.000
    ActionsRow.Position = UDim2.new(0, 0, 0, 88)
    ActionsRow.Size = UDim2.new(1, 0, 0, 32)

    local CommitBtn = Instance.new("TextButton")
    CommitBtn.Name = "CommitBtn"
    CommitBtn.Parent = ActionsRow
    CommitBtn.BackgroundColor3 = Color3.fromRGB(35, 134, 54)
    CommitBtn.Size = UDim2.new(1, -140, 1, 0)
    CommitBtn.Font = Enum.Font.Ubuntu
    CommitBtn.Text = "<b>Commit to main</b>"
    CommitBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    CommitBtn.TextSize = 13.000

    local UICorner_7 = Instance.new("UICorner")
    UICorner_7.CornerRadius = UDim.new(0, 6)
    UICorner_7.Parent = CommitBtn

    local PullBtn = Instance.new("TextButton")
    PullBtn.Name = "PullBtn"
    PullBtn.Parent = ActionsRow
    PullBtn.BackgroundColor3 = Color3.fromRGB(33, 38, 45)
    PullBtn.Position = UDim2.new(1.00886917, -132, 0, 0)
    PullBtn.Size = UDim2.new(0, 54, 1, 0)
    PullBtn.Font = Enum.Font.Ubuntu
    PullBtn.Text = "Pull"
    PullBtn.TextColor3 = Color3.fromRGB(230, 237, 243)
    PullBtn.TextSize = 13.000

    local UICorner_8 = Instance.new("UICorner")
    UICorner_8.CornerRadius = UDim.new(0, 6)
    UICorner_8.Parent = PullBtn

    local PushBtn = Instance.new("TextButton")
    PushBtn.Name = "PushBtn"
    PushBtn.Parent = ActionsRow
    PushBtn.BackgroundColor3 = Color3.fromRGB(33, 38, 45)
    PushBtn.Position = UDim2.new(1.01366091, -64, 0, 0)
    PushBtn.Size = UDim2.new(0, 54, 1, 0)
    PushBtn.Font = Enum.Font.Ubuntu
    PushBtn.Text = "Push"
    PushBtn.TextColor3 = Color3.fromRGB(230, 237, 243)
    PushBtn.TextSize = 13.000

    local UICorner_9 = Instance.new("UICorner")
    UICorner_9.CornerRadius = UDim.new(0, 6)
    UICorner_9.Parent = PushBtn

    local Modal = Instance.new("TextButton")
    Modal.Name = "Modal"
    Modal.Parent = Plugin
    Modal.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    Modal.BackgroundTransparency = 0.500
    Modal.BorderColor3 = Color3.fromRGB(0, 0, 0)
    Modal.BorderSizePixel = 0
    Modal.Size = UDim2.new(1, 0, 1, 0)
    Modal.Visible = false
    Modal.ZIndex = 120
    Modal.Active = true
    Modal.Text = ""
    Modal.AutoButtonColor = false

    local Modal_2 = Instance.new("Frame")
    Modal_2.Name = "Modal"
    Modal_2.Parent = Modal
    Modal_2.AnchorPoint = Vector2.new(0.5, 0.5)
    Modal_2.BackgroundColor3 = Color3.fromRGB(13, 17, 23)
    Modal_2.BorderColor3 = Color3.fromRGB(48, 54, 61)
    Modal_2.BorderSizePixel = 1
    Modal_2.Position = UDim2.new(0.5, 0, 0.5, 0)
    Modal_2.Size = UDim2.new(1, -64, 0, 160)
    Modal_2.AutomaticSize = Enum.AutomaticSize.Y
    Modal_2.ZIndex = 121

    local UICorner_10 = Instance.new("UICorner")
    UICorner_10.CornerRadius = UDim.new(0, 6)
    UICorner_10.Parent = Modal_2

    local UIListLayout_modal2 = Instance.new("UIListLayout")
    UIListLayout_modal2.Parent = Modal_2
    UIListLayout_modal2.HorizontalAlignment = Enum.HorizontalAlignment.Center
    UIListLayout_modal2.SortOrder = Enum.SortOrder.LayoutOrder
    UIListLayout_modal2.Padding = UDim.new(0, 12)

    local UIPadding_modal2 = Instance.new("UIPadding")
    UIPadding_modal2.Parent = Modal_2
    UIPadding_modal2.PaddingTop = UDim.new(0, 16)
    UIPadding_modal2.PaddingBottom = UDim.new(0, 16)
    UIPadding_modal2.PaddingLeft = UDim.new(0, 16)
    UIPadding_modal2.PaddingRight = UDim.new(0, 16)

    local Problem = Instance.new("TextLabel")
    Problem.Name = "Problem"
    Problem.Parent = Modal_2
    Problem.BackgroundTransparency = 1.000
    Problem.Size = UDim2.new(1, 0, 0, 0)
    Problem.AutomaticSize = Enum.AutomaticSize.Y
    Problem.LayoutOrder = 1
    Problem.Font = Enum.Font.Ubuntu
    Problem.TextSize = 14
    Problem.TextColor3 = Color3.fromRGB(230, 237, 243)
    Problem.TextWrapped = true
    Problem.RichText = true
    Problem.ZIndex = 122

    local PromptInputBg = Instance.new("Frame")
    PromptInputBg.Name = "PromptInputBg"
    PromptInputBg.Parent = Modal_2
    PromptInputBg.BackgroundColor3 = Color3.fromRGB(1, 4, 9)
    PromptInputBg.BorderColor3 = Color3.fromRGB(48, 54, 61)
    PromptInputBg.BorderSizePixel = 1
    PromptInputBg.Size = UDim2.new(1, 0, 0, 32)
    PromptInputBg.LayoutOrder = 2
    PromptInputBg.ZIndex = 122
    PromptInputBg.Visible = false

    local UICorner_promo = Instance.new("UICorner")
    UICorner_promo.CornerRadius = UDim.new(0, 6)
    UICorner_promo.Parent = PromptInputBg

    local PromptInput = Instance.new("TextBox")
    PromptInput.Name = "PromptInput"
    PromptInput.Parent = PromptInputBg
    PromptInput.BackgroundTransparency = 1.000
    PromptInput.Position = UDim2.new(0, 10, 0, 0)
    PromptInput.Size = UDim2.new(1, -20, 1, 0)
    PromptInput.ZIndex = 123
    PromptInput.Font = Enum.Font.Ubuntu
    PromptInput.Text = ""
    PromptInput.PlaceholderText = ""
    PromptInput.PlaceholderColor3 = Color3.fromRGB(139, 148, 158)
    PromptInput.TextColor3 = Color3.fromRGB(230, 237, 243)
    PromptInput.TextSize = 13.000
    PromptInput.TextXAlignment = Enum.TextXAlignment.Left

    local Options = Instance.new("Frame")
    Options.Name = "Options"
    Options.Parent = Modal_2
    Options.BackgroundTransparency = 1.000
    Options.Size = UDim2.new(1, 0, 0, 32)
    Options.LayoutOrder = 3
    Options.ZIndex = 122

    local UIListLayout_2 = Instance.new("UIListLayout")
    UIListLayout_2.Parent = Options
    UIListLayout_2.HorizontalAlignment = Enum.HorizontalAlignment.Center
    UIListLayout_2.SortOrder = Enum.SortOrder.LayoutOrder
    UIListLayout_2.VerticalAlignment = Enum.VerticalAlignment.Center

    local PullBtn_2 = Instance.new("TextButton")
    PullBtn_2.Name = "OkayBtn"
    PullBtn_2.Parent = Options
    PullBtn_2.BackgroundColor3 = Color3.fromRGB(33, 38, 45)
    PullBtn_2.Size = UDim2.new(0, 80, 1, 0)
    PullBtn_2.Font = Enum.Font.Ubuntu
    PullBtn_2.Text = "Okay!"
    PullBtn_2.TextColor3 = Color3.fromRGB(230, 237, 243)
    PullBtn_2.TextSize = 13.000
    PullBtn_2.ZIndex = 123

    local UICorner_11 = Instance.new("UICorner")
    UICorner_11.CornerRadius = UDim.new(0, 6)
    UICorner_11.Parent = PullBtn_2



    local InitRepoView = Instance.new("Frame")
    InitRepoView.Name = "InitRepoView"
    InitRepoView.Parent = Plugin
    InitRepoView.BackgroundColor3 = Color3.fromRGB(13, 17, 23)
    InitRepoView.BorderSizePixel = 0
    InitRepoView.Size = UDim2.new(1, 0, 1, 0)
    InitRepoView.ZIndex = 50

    local CenterGroup = Instance.new("Frame")
    CenterGroup.Name = "CenterGroup"
    CenterGroup.Parent = InitRepoView
    CenterGroup.AnchorPoint = Vector2.new(0.5, 0.5)
    CenterGroup.BackgroundTransparency = 1.000
    CenterGroup.Position = UDim2.new(0.5, 0, 0.5, 0)
    CenterGroup.Size = UDim2.new(1, -48, 0, 260)

    local UIListLayout_4 = Instance.new("UIListLayout")
    UIListLayout_4.Parent = CenterGroup
    UIListLayout_4.HorizontalAlignment = Enum.HorizontalAlignment.Center
    UIListLayout_4.SortOrder = Enum.SortOrder.LayoutOrder
    UIListLayout_4.Padding = UDim.new(0, 12)

    local InitTitle = Instance.new("TextLabel")
    InitTitle.Name = "InitTitle"
    InitTitle.Parent = CenterGroup
    InitTitle.BackgroundTransparency = 1.000
    InitTitle.LayoutOrder = 1
    InitTitle.Size = UDim2.new(1, 0, 0, 20)
    InitTitle.Font = Enum.Font.Ubuntu
    InitTitle.Text = "<b>No Repository Found</b>"
    InitTitle.TextColor3 = Color3.fromRGB(230, 237, 243)
    InitTitle.TextSize = 16.000

    local InitDesc = Instance.new("TextLabel")
    InitDesc.Name = "InitDesc"
    InitDesc.Parent = CenterGroup
    InitDesc.BackgroundTransparency = 1.000
    InitDesc.LayoutOrder = 2
    InitDesc.Size = UDim2.new(1, 0, 0, 40)
    InitDesc.Font = Enum.Font.Ubuntu
    InitDesc.Text = "Initialize a new repository or clone an existing one to get started."
    InitDesc.TextColor3 = Color3.fromRGB(139, 148, 158)
    InitDesc.TextSize = 13.000
    InitDesc.TextWrapped = true

    local InitBtn = Instance.new("TextButton")
    InitBtn.Name = "InitBtn"
    InitBtn.Parent = CenterGroup
    InitBtn.BackgroundColor3 = Color3.fromRGB(35, 134, 54)
    InitBtn.LayoutOrder = 3
    InitBtn.Size = UDim2.new(1, 0, 0, 36)
    InitBtn.Font = Enum.Font.Ubuntu
    InitBtn.Text = "<b>Initialize Repository</b>"
    InitBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    InitBtn.TextSize = 13.000

    local UICorner_12 = Instance.new("UICorner")
    UICorner_12.CornerRadius = UDim.new(0, 6)
    UICorner_12.Parent = InitBtn

    local Frame_8 = Instance.new("Frame")
    Frame_8.Parent = CenterGroup
    Frame_8.BackgroundTransparency = 1.000
    Frame_8.LayoutOrder = 4
    Frame_8.Size = UDim2.new(1, 0, 0, 20)

    local Frame_9 = Instance.new("Frame")
    Frame_9.Parent = Frame_8
    Frame_9.BackgroundColor3 = Color3.fromRGB(48, 54, 61)
    Frame_9.BorderSizePixel = 0
    Frame_9.Position = UDim2.new(0, 0, 0.5, 0)
    Frame_9.Size = UDim2.new(1, 0, 0, 1)

    local TextLabel_8 = Instance.new("TextLabel")
    TextLabel_8.Parent = Frame_8
    TextLabel_8.AnchorPoint = Vector2.new(0.5, 0.5)
    TextLabel_8.BackgroundColor3 = Color3.fromRGB(13, 17, 23)
    TextLabel_8.BorderSizePixel = 0
    TextLabel_8.Position = UDim2.new(0.5, 0, 0.5, 0)
    TextLabel_8.Size = UDim2.new(0, 40, 1, 0)
    TextLabel_8.Font = Enum.Font.Ubuntu
    TextLabel_8.Text = "or"
    TextLabel_8.TextColor3 = Color3.fromRGB(139, 148, 158)
    TextLabel_8.TextSize = 12.000

    local CloneUrlBg = Instance.new("Frame")
    CloneUrlBg.Name = "CloneUrlBg"
    CloneUrlBg.Parent = CenterGroup
    CloneUrlBg.BackgroundColor3 = Color3.fromRGB(1, 4, 9)
    CloneUrlBg.LayoutOrder = 5
    CloneUrlBg.Size = UDim2.new(1, 0, 0, 32)

    local UICorner_13 = Instance.new("UICorner")
    UICorner_13.CornerRadius = UDim.new(0, 6)
    UICorner_13.Parent = CloneUrlBg

    local CloneUrl = Instance.new("TextBox")
    CloneUrl.Name = "CloneUrl"
    CloneUrl.Parent = CloneUrlBg
    CloneUrl.BackgroundTransparency = 1.000
    CloneUrl.Position = UDim2.new(0, 10, 0, 0)
    CloneUrl.Size = UDim2.new(1, -20, 1, 0)
    CloneUrl.ClearTextOnFocus = false
    CloneUrl.Font = Enum.Font.Ubuntu
    CloneUrl.PlaceholderColor3 = Color3.fromRGB(139, 148, 158)
    CloneUrl.PlaceholderText = "URL (https://github.com/...)"
    CloneUrl.Text = ""
    CloneUrl.TextColor3 = Color3.fromRGB(230, 237, 243)
    CloneUrl.TextSize = 13.000
    CloneUrl.TextXAlignment = Enum.TextXAlignment.Left

    local CloneBtn = Instance.new("TextButton")
    CloneBtn.Name = "CloneBtn"
    CloneBtn.Parent = CenterGroup
    CloneBtn.BackgroundColor3 = Color3.fromRGB(33, 38, 45)
    CloneBtn.LayoutOrder = 6
    CloneBtn.Size = UDim2.new(1, 0, 0, 36)
    CloneBtn.Font = Enum.Font.Ubuntu
    CloneBtn.Text = "Clone Repository"
    CloneBtn.TextColor3 = Color3.fromRGB(230, 237, 243)
    CloneBtn.TextSize = 13.000

    local UICorner_14 = Instance.new("UICorner")
    UICorner_14.CornerRadius = UDim.new(0, 6)
    UICorner_14.Parent = CloneBtn

    local SettingsView = Instance.new("TextButton")
    SettingsView.Name = "SettingsView"
    SettingsView.Parent = Plugin
    SettingsView.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    SettingsView.BackgroundTransparency = 0.500
    SettingsView.BorderSizePixel = 0
    SettingsView.Size = UDim2.new(1, 0, 1, 0)
    SettingsView.Visible = false
    SettingsView.ZIndex = 100
    SettingsView.Text = ""
    SettingsView.AutoButtonColor = false

    local ModalInner = Instance.new("Frame")
    ModalInner.Name = "ModalInner"
    ModalInner.Parent = SettingsView
    ModalInner.AnchorPoint = Vector2.new(0.5, 0.5)
    ModalInner.BackgroundColor3 = Color3.fromRGB(13, 17, 23)
    ModalInner.Position = UDim2.new(0.5, 0, 0.5, 0)
    ModalInner.Size = UDim2.new(1, -32, 0, 360)

    local UICorner_15 = Instance.new("UICorner")
    UICorner_15.Parent = ModalInner

    local Header_2 = Instance.new("Frame")
    Header_2.Name = "Header"
    Header_2.Parent = ModalInner
    Header_2.BackgroundColor3 = Color3.fromRGB(1, 4, 9)
    Header_2.Size = UDim2.new(1, 0, 0, 44)

    local UICorner_16 = Instance.new("UICorner")
    UICorner_16.Parent = Header_2

    local Frame_10 = Instance.new("Frame")
    Frame_10.Parent = Header_2
    Frame_10.BackgroundColor3 = Color3.fromRGB(1, 4, 9)
    Frame_10.BorderSizePixel = 0
    Frame_10.Position = UDim2.new(0, 0, 1, -8)
    Frame_10.Size = UDim2.new(1, 0, 0, 8)

    local Frame_11 = Instance.new("Frame")
    Frame_11.Parent = Header_2
    Frame_11.BackgroundColor3 = Color3.fromRGB(48, 54, 61)
    Frame_11.BorderSizePixel = 0
    Frame_11.Position = UDim2.new(0, 0, 1, -1)
    Frame_11.Size = UDim2.new(1, 0, 0, 1)

    local Title_3 = Instance.new("TextLabel")
    Title_3.Name = "Title"
    Title_3.Parent = Header_2
    Title_3.BackgroundTransparency = 1.000
    Title_3.Position = UDim2.new(0, 16, 0, 0)
    Title_3.Size = UDim2.new(1, -32, 1, 0)
    Title_3.Font = Enum.Font.Ubuntu
    Title_3.Text = "<b>Repository Settings</b>"
    Title_3.TextColor3 = Color3.fromRGB(230, 237, 243)
    Title_3.TextSize = 13.000
    Title_3.TextSize = 13.000
    Title_3.TextXAlignment = Enum.TextXAlignment.Left

    local Body_2 = Instance.new("Frame")
    Body_2.Name = "Body"
    Body_2.Parent = ModalInner
    Body_2.BackgroundTransparency = 1.000
    Body_2.Position = UDim2.new(0, 0, 0, 44)
    Body_2.Size = UDim2.new(1, 0, 1, -44)

    local UIPadding_4 = Instance.new("UIPadding")
    UIPadding_4.Parent = Body_2
    UIPadding_4.PaddingBottom = UDim.new(0, 16)
    UIPadding_4.PaddingLeft = UDim.new(0, 16)
    UIPadding_4.PaddingRight = UDim.new(0, 16)
    UIPadding_4.PaddingTop = UDim.new(0, 16)

    local UIListLayout_5 = Instance.new("UIListLayout")
    UIListLayout_5.Parent = Body_2
    UIListLayout_5.SortOrder = Enum.SortOrder.LayoutOrder
    UIListLayout_5.Padding = UDim.new(0, 8)

    local OriginLbl = Instance.new("TextLabel")
    OriginLbl.Name = "OriginLbl"
    OriginLbl.Parent = Body_2
    OriginLbl.BackgroundTransparency = 1.000
    OriginLbl.LayoutOrder = 1
    OriginLbl.Size = UDim2.new(1, 0, 0, 20)
    OriginLbl.Font = Enum.Font.Ubuntu
    OriginLbl.Text = "<b>Remote Origin URL</b>"
    OriginLbl.TextColor3 = Color3.fromRGB(230, 237, 243)
    OriginLbl.TextSize = 12.000
    OriginLbl.TextXAlignment = Enum.TextXAlignment.Left

    local OriginInputBg = Instance.new("Frame")
    OriginInputBg.Name = "OriginInputBg"
    OriginInputBg.Parent = Body_2
    OriginInputBg.BackgroundColor3 = Color3.fromRGB(1, 4, 9)
    OriginInputBg.LayoutOrder = 2
    OriginInputBg.Position = UDim2.new(-0.252983302, 0, 0.0704225376, 0)
    OriginInputBg.Size = UDim2.new(1, 0, 0, 32)

    local UICorner_17 = Instance.new("UICorner")
    UICorner_17.CornerRadius = UDim.new(0, 6)
    UICorner_17.Parent = OriginInputBg

    local OriginInput = Instance.new("TextBox")
    OriginInput.Name = "OriginInput"
    OriginInput.Parent = OriginInputBg
    OriginInput.BackgroundTransparency = 1.000
    OriginInput.Position = UDim2.new(0, 10, 0, 0)
    OriginInput.Size = UDim2.new(1, -20, 1, 0)
    OriginInput.ClearTextOnFocus = false
    OriginInput.Font = Enum.Font.Ubuntu
    OriginInput.PlaceholderColor3 = Color3.fromRGB(139, 148, 158)
    OriginInput.PlaceholderText = "https://github.com/user/repo.git"
    OriginInput.Text = ""
    OriginInput.TextColor3 = Color3.fromRGB(230, 237, 243)
    OriginInput.TextSize = 13.000
    OriginInput.TextXAlignment = Enum.TextXAlignment.Left

    local Frame_12 = Instance.new("Frame")
    Frame_12.Parent = Body_2
    Frame_12.BackgroundTransparency = 1.000
    Frame_12.LayoutOrder = 3
    Frame_12.Size = UDim2.new(1, 0, 0, 16)

    local CredLbl = Instance.new("TextLabel")
    CredLbl.Name = "CredLbl"
    CredLbl.Parent = Body_2
    CredLbl.BackgroundTransparency = 1.000
    CredLbl.LayoutOrder = 4
    CredLbl.Size = UDim2.new(1, 0, 0, 20)
    CredLbl.Font = Enum.Font.Ubuntu
    CredLbl.Text = "<b>Authentication</b>"
    CredLbl.TextColor3 = Color3.fromRGB(230, 237, 243)
    CredLbl.TextSize = 12.000
    CredLbl.TextXAlignment = Enum.TextXAlignment.Left

    local UsernameInputBg = Instance.new("Frame")
    UsernameInputBg.Name = "UsernameInputBg"
    UsernameInputBg.Parent = Body_2
    UsernameInputBg.BackgroundColor3 = Color3.fromRGB(1, 4, 9)
    UsernameInputBg.LayoutOrder = 5
    UsernameInputBg.Size = UDim2.new(1, 0, 0, 32)

    local UICorner_18 = Instance.new("UICorner")
    UICorner_18.CornerRadius = UDim.new(0, 6)
    UICorner_18.Parent = UsernameInputBg

    local UsernameInput = Instance.new("TextBox")
    UsernameInput.Name = "UsernameInput"
    UsernameInput.Parent = UsernameInputBg
    UsernameInput.BackgroundTransparency = 1.000
    UsernameInput.Position = UDim2.new(0, 10, 0, 0)
    UsernameInput.Size = UDim2.new(1, -20, 1, 0)
    UsernameInput.ClearTextOnFocus = false
    UsernameInput.Font = Enum.Font.Ubuntu
    UsernameInput.PlaceholderColor3 = Color3.fromRGB(139, 148, 158)
    UsernameInput.PlaceholderText = "Username"
    UsernameInput.Text = ""
    UsernameInput.TextColor3 = Color3.fromRGB(230, 237, 243)
    UsernameInput.TextSize = 13.000
    UsernameInput.TextXAlignment = Enum.TextXAlignment.Left

    local TokenInputBg = Instance.new("Frame")
    TokenInputBg.Name = "TokenInputBg"
    TokenInputBg.Parent = Body_2
    TokenInputBg.BackgroundColor3 = Color3.fromRGB(1, 4, 9)
    TokenInputBg.LayoutOrder = 6
    TokenInputBg.Size = UDim2.new(1, 0, 0, 32)

    local UICorner_19 = Instance.new("UICorner")
    UICorner_19.CornerRadius = UDim.new(0, 6)
    UICorner_19.Parent = TokenInputBg

    local TokenInput = Instance.new("TextBox")
    TokenInput.Name = "TokenInput"
    TokenInput.Parent = TokenInputBg
    TokenInput.BackgroundTransparency = 1.000
    TokenInput.Position = UDim2.new(0, 10, 0, 0)
    TokenInput.Size = UDim2.new(1, -20, 1, 0)
    TokenInput.ClearTextOnFocus = false
    TokenInput.Font = Enum.Font.Ubuntu
    TokenInput.PlaceholderColor3 = Color3.fromRGB(139, 148, 158)
    TokenInput.PlaceholderText = "Personal Access Token"
    TokenInput.Text = ""
    TokenInput.TextColor3 = Color3.fromRGB(230, 237, 243)
    TokenInput.TextSize = 13.000
    TokenInput.TextXAlignment = Enum.TextXAlignment.Left

    local Frame_13 = Instance.new("Frame")
    Frame_13.Parent = Body_2
    Frame_13.BackgroundTransparency = 1.000
    Frame_13.LayoutOrder = 7
    Frame_13.Size = UDim2.new(1, 0, 0, 16)

    local ActionsRow_S = Instance.new("Frame")
    ActionsRow_S.Name = "ActionsRow"
    ActionsRow_S.Parent = Body_2
    ActionsRow_S.BackgroundTransparency = 1.000
    ActionsRow_S.LayoutOrder = 8
    ActionsRow_S.Size = UDim2.new(1, 0, 0, 36)

    local SaveBtn = Instance.new("TextButton")
    SaveBtn.Name = "SaveBtn"
    SaveBtn.Parent = ActionsRow_S
    SaveBtn.BackgroundColor3 = Color3.fromRGB(35, 134, 54)
    SaveBtn.Size = UDim2.new(1, -70, 1, 0)
    SaveBtn.Font = Enum.Font.Ubuntu
    SaveBtn.Text = "<b>Save Configuration</b>"
    SaveBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    SaveBtn.TextSize = 13.000
    SaveBtn.AutoButtonColor = false

    local UICorner_20 = Instance.new("UICorner")
    UICorner_20.CornerRadius = UDim.new(0, 6)
    UICorner_20.Parent = SaveBtn

    local CloseBtn = Instance.new("TextButton")
    CloseBtn.Name = "CloseBtn"
    CloseBtn.Parent = ActionsRow_S
    CloseBtn.BackgroundColor3 = Color3.fromRGB(33, 38, 45)
    CloseBtn.Position = UDim2.new(1, -60, 0, 0)
    CloseBtn.Size = UDim2.new(0, 60, 1, 0)
    CloseBtn.Font = Enum.Font.Ubuntu
    CloseBtn.Text = "Close"
    CloseBtn.TextColor3 = Color3.fromRGB(230, 237, 243)
    CloseBtn.TextSize = 13.000
    CloseBtn.AutoButtonColor = false

    local UICorner_20c = Instance.new("UICorner")
    UICorner_20c.CornerRadius = UDim.new(0, 6)
    UICorner_20c.Parent = CloseBtn

    local BranchDropdown = Instance.new("Frame")
    BranchDropdown.Name = "BranchDropdown"
    BranchDropdown.Parent = Plugin
    BranchDropdown.AnchorPoint = Vector2.new(1, 0)
    BranchDropdown.BackgroundColor3 = Color3.fromRGB(1, 4, 9)
    BranchDropdown.Position = UDim2.new(1, -16, 0, 48)
    BranchDropdown.Size = UDim2.new(0, 240, 0, 260)
    BranchDropdown.Visible = false
    BranchDropdown.ZIndex = 60

    local UICorner_21 = Instance.new("UICorner")
    UICorner_21.CornerRadius = UDim.new(0, 6)
    UICorner_21.Parent = BranchDropdown

    local SearchBg = Instance.new("Frame")
    SearchBg.Name = "SearchBg"
    SearchBg.Parent = BranchDropdown
    SearchBg.BackgroundColor3 = Color3.fromRGB(1, 4, 9)
    SearchBg.Position = UDim2.new(0, 10, 0, 10)
    SearchBg.Size = UDim2.new(1, -20, 0, 28)
    SearchBg.ZIndex = 61

    local UICorner_22 = Instance.new("UICorner")
    UICorner_22.CornerRadius = UDim.new(0, 4)
    UICorner_22.Parent = SearchBg

    local SearchInput = Instance.new("TextBox")
    SearchInput.Name = "SearchInput"
    SearchInput.Parent = SearchBg
    SearchInput.BackgroundTransparency = 1.000
    SearchInput.Position = UDim2.new(0, 8, 0, 0)
    SearchInput.Size = UDim2.new(1, -16, 1, 0)
    SearchInput.ZIndex = 62
    SearchInput.ClearTextOnFocus = false
    SearchInput.Font = Enum.Font.Ubuntu
    SearchInput.PlaceholderColor3 = Color3.fromRGB(139, 148, 158)
    SearchInput.PlaceholderText = "Filter branches"
    SearchInput.Text = ""
    SearchInput.TextColor3 = Color3.fromRGB(230, 237, 243)
    SearchInput.TextSize = 13.000
    SearchInput.TextXAlignment = Enum.TextXAlignment.Left

    local Frame_14 = Instance.new("Frame")
    Frame_14.Parent = BranchDropdown
    Frame_14.BackgroundColor3 = Color3.fromRGB(48, 54, 61)
    Frame_14.BorderSizePixel = 0
    Frame_14.Position = UDim2.new(0, 0, 0, 46)
    Frame_14.Size = UDim2.new(1, 0, 0, 1)
    Frame_14.ZIndex = 61

    local PopLabel = Instance.new("TextLabel")
    PopLabel.Name = "PopLabel"
    PopLabel.Parent = BranchDropdown
    PopLabel.BackgroundTransparency = 1.000
    PopLabel.Position = UDim2.new(0, 10, 0, 52)
    PopLabel.Size = UDim2.new(1, -20, 0, 20)
    PopLabel.ZIndex = 61
    PopLabel.Font = Enum.Font.Ubuntu
    PopLabel.Text = "<b>Branches</b>"
    PopLabel.TextColor3 = Color3.fromRGB(139, 148, 158)
    PopLabel.TextSize = 12.000
    PopLabel.TextXAlignment = Enum.TextXAlignment.Left

    local BranchList = Instance.new("ScrollingFrame")
    BranchList.Name = "BranchList"
    BranchList.Parent = BranchDropdown
    BranchList.BackgroundTransparency = 1.000
    BranchList.BorderSizePixel = 0
    BranchList.Position = UDim2.new(0, 0, 0, 76)
    BranchList.Size = UDim2.new(1, 0, 1, -114)
    BranchList.ZIndex = 61
    BranchList.ScrollBarThickness = 2

    local UIListLayout_6 = Instance.new("UIListLayout")
    UIListLayout_6.Parent = BranchList
    UIListLayout_6.SortOrder = Enum.SortOrder.LayoutOrder




    local Frame_15 = Instance.new("Frame")
    Frame_15.Parent = BranchDropdown
    Frame_15.BackgroundColor3 = Color3.fromRGB(48, 54, 61)
    Frame_15.BorderSizePixel = 0
    Frame_15.Position = UDim2.new(0, 0, 1, -38)
    Frame_15.Size = UDim2.new(1, 0, 0, 1)
    Frame_15.ZIndex = 61

    local AddBranchBtn = Instance.new("TextButton")
    AddBranchBtn.Name = "AddBranchBtn"
    AddBranchBtn.Parent = BranchDropdown
    AddBranchBtn.BackgroundTransparency = 1.000
    AddBranchBtn.Position = UDim2.new(0, 0, 1, -37)
    AddBranchBtn.Size = UDim2.new(1, 0, 0, 37)
    AddBranchBtn.ZIndex = 62
    AddBranchBtn.Text = ""

    local TextLabel_9 = Instance.new("TextLabel")
    TextLabel_9.Parent = AddBranchBtn
    TextLabel_9.BackgroundTransparency = 1.000
    TextLabel_9.Position = UDim2.new(0, 14, 0, 0)
    TextLabel_9.Size = UDim2.new(0, 14, 1, 0)
    TextLabel_9.ZIndex = 63
    TextLabel_9.Font = Enum.Font.Ubuntu
    TextLabel_9.Text = "+"
    TextLabel_9.TextColor3 = Color3.fromRGB(139, 148, 158)
    TextLabel_9.TextSize = 16.000

    local AddLbl = Instance.new("TextLabel")
    AddLbl.Name = "AddLbl"
    AddLbl.Parent = AddBranchBtn
    AddLbl.BackgroundTransparency = 1.000
    AddLbl.Position = UDim2.new(0, 36, 0, 0)
    AddLbl.Size = UDim2.new(1, -36, 1, 0)
    AddLbl.ZIndex = 63
    AddLbl.Font = Enum.Font.Ubuntu
    AddLbl.Text = "New branch"
    AddLbl.TextColor3 = Color3.fromRGB(139, 148, 158)
    AddLbl.TextSize = 13.000
    AddLbl.TextXAlignment = Enum.TextXAlignment.Left

    local CreateBranchModal = Instance.new("TextButton")
    CreateBranchModal.Name = "CreateBranchModal"
    CreateBranchModal.Parent = Plugin
    CreateBranchModal.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    CreateBranchModal.BackgroundTransparency = 0.500
    CreateBranchModal.BorderSizePixel = 0
    CreateBranchModal.Size = UDim2.new(1, 0, 1, 0)
    CreateBranchModal.Visible = false
    CreateBranchModal.Active = true
    CreateBranchModal.ZIndex = 110
    CreateBranchModal.Text = ""
    CreateBranchModal.AutoButtonColor = false

    local ModalInner_2 = Instance.new("Frame")
    ModalInner_2.Name = "ModalInner"
    ModalInner_2.Parent = CreateBranchModal
    ModalInner_2.AnchorPoint = Vector2.new(0.5, 0.5)
    ModalInner_2.BackgroundColor3 = Color3.fromRGB(13, 17, 23)
    ModalInner_2.Position = UDim2.new(0.5, 0, 0.5, 0)
    ModalInner_2.Size = UDim2.new(1, -32, 0, 240)
    ModalInner_2.ZIndex = 111

    local UICorner_23 = Instance.new("UICorner")
    UICorner_23.Parent = ModalInner_2

    local Header_3 = Instance.new("Frame")
    Header_3.Name = "Header"
    Header_3.Parent = ModalInner_2
    Header_3.BackgroundColor3 = Color3.fromRGB(1, 4, 9)
    Header_3.Size = UDim2.new(1, 0, 0, 44)
    Header_3.ZIndex = 112

    local UICorner_24 = Instance.new("UICorner")
    UICorner_24.Parent = Header_3

    local Frame_16 = Instance.new("Frame")
    Frame_16.Parent = Header_3
    Frame_16.BackgroundColor3 = Color3.fromRGB(1, 4, 9)
    Frame_16.BorderSizePixel = 0
    Frame_16.Position = UDim2.new(0, 0, 1, -8)
    Frame_16.Size = UDim2.new(1, 0, 0, 8)
    Frame_16.ZIndex = 112

    local Frame_17 = Instance.new("Frame")
    Frame_17.Parent = Header_3
    Frame_17.BackgroundColor3 = Color3.fromRGB(48, 54, 61)
    Frame_17.BorderSizePixel = 0
    Frame_17.Position = UDim2.new(0, 0, 1, -1)
    Frame_17.Size = UDim2.new(1, 0, 0, 1)
    Frame_17.ZIndex = 113

    local Title_4 = Instance.new("TextLabel")
    Title_4.Name = "Title"
    Title_4.Parent = Header_3
    Title_4.BackgroundTransparency = 1.000
    Title_4.Position = UDim2.new(0, 16, 0, 0)
    Title_4.Size = UDim2.new(1, -32, 1, 0)
    Title_4.ZIndex = 114
    Title_4.Font = Enum.Font.Ubuntu
    Title_4.Text = "<b>Create a Branch</b>"
    Title_4.TextColor3 = Color3.fromRGB(230, 237, 243)
    Title_4.TextSize = 13.000
    Title_4.TextXAlignment = Enum.TextXAlignment.Left


    local Body_3 = Instance.new("Frame")
    Body_3.Name = "Body"
    Body_3.Parent = ModalInner_2
    Body_3.BackgroundTransparency = 1.000
    Body_3.Position = UDim2.new(0, 0, 0, 44)
    Body_3.Size = UDim2.new(1, 0, 1, -44)
    Body_3.ZIndex = 112

    local UIPadding_5 = Instance.new("UIPadding")
    UIPadding_5.Parent = Body_3
    UIPadding_5.PaddingBottom = UDim.new(0, 16)
    UIPadding_5.PaddingLeft = UDim.new(0, 16)
    UIPadding_5.PaddingRight = UDim.new(0, 16)
    UIPadding_5.PaddingTop = UDim.new(0, 16)

    local UIListLayout_7 = Instance.new("UIListLayout")
    UIListLayout_7.Parent = Body_3
    UIListLayout_7.SortOrder = Enum.SortOrder.LayoutOrder
    UIListLayout_7.Padding = UDim.new(0, 8)

    local NameLbl = Instance.new("TextLabel")
    NameLbl.Name = "NameLbl"
    NameLbl.Parent = Body_3
    NameLbl.BackgroundTransparency = 1.000
    NameLbl.LayoutOrder = 1
    NameLbl.Size = UDim2.new(1, 0, 0, 20)
    NameLbl.ZIndex = 113
    NameLbl.Font = Enum.Font.Ubuntu
    NameLbl.Text = "<b>Name</b>"
    NameLbl.TextColor3 = Color3.fromRGB(230, 237, 243)
    NameLbl.TextSize = 12.000
    NameLbl.TextXAlignment = Enum.TextXAlignment.Left

    local NameBg = Instance.new("Frame")
    NameBg.Name = "NameBg"
    NameBg.Parent = Body_3
    NameBg.BackgroundColor3 = Color3.fromRGB(1, 4, 9)
    NameBg.LayoutOrder = 2
    NameBg.Size = UDim2.new(1, 0, 0, 32)
    NameBg.ZIndex = 113

    local UICorner_25 = Instance.new("UICorner")
    UICorner_25.CornerRadius = UDim.new(0, 6)
    UICorner_25.Parent = NameBg

    local NameInput = Instance.new("TextBox")
    NameInput.Name = "NameInput"
    NameInput.Parent = NameBg
    NameInput.BackgroundTransparency = 1.000
    NameInput.Position = UDim2.new(0, 10, 0, 0)
    NameInput.Size = UDim2.new(1, -20, 1, 0)
    NameInput.ZIndex = 114
    NameInput.ClearTextOnFocus = false
    NameInput.Font = Enum.Font.Ubuntu
    NameInput.Text = ""
    NameInput.TextColor3 = Color3.fromRGB(230, 237, 243)
    NameInput.TextSize = 13.000
    NameInput.TextXAlignment = Enum.TextXAlignment.Left

    local InfoLbl = Instance.new("TextLabel")
    InfoLbl.Name = "InfoLbl"
    InfoLbl.Parent = Body_3
    InfoLbl.BackgroundTransparency = 1.000
    InfoLbl.LayoutOrder = 3
    InfoLbl.Size = UDim2.new(1, 0, 0, 32)
    InfoLbl.ZIndex = 113
    InfoLbl.Font = Enum.Font.Ubuntu
    InfoLbl.Text = "Your new branch will be based on your currently checked out branch (<font color='#e6edf3'>main</font>)."
    InfoLbl.TextColor3 = Color3.fromRGB(139, 148, 158)
    InfoLbl.TextSize = 12.000
    InfoLbl.TextWrapped = true
    InfoLbl.TextXAlignment = Enum.TextXAlignment.Left
    InfoLbl.RichText = true

    local Frame_18 = Instance.new("Frame")
    Frame_18.Parent = Body_3
    Frame_18.BackgroundTransparency = 1.000
    Frame_18.LayoutOrder = 4
    Frame_18.Size = UDim2.new(1, 0, 0, 8)

    local Actions = Instance.new("Frame")
    Actions.Name = "Actions"
    Actions.Parent = Body_3
    Actions.BackgroundTransparency = 1.000
    Actions.LayoutOrder = 5
    Actions.Size = UDim2.new(1, 0, 0, 32)
    Actions.ZIndex = 113

    local CancelBtn = Instance.new("TextButton")
    CancelBtn.Name = "CancelBtn"
    CancelBtn.Parent = Actions
    CancelBtn.BackgroundColor3 = Color3.fromRGB(33, 38, 45)
    CancelBtn.Position = UDim2.new(1, -170, 0, 0)
    CancelBtn.Size = UDim2.new(0, 80, 1, 0)
    CancelBtn.ZIndex = 114
    CancelBtn.Font = Enum.Font.Ubuntu
    CancelBtn.Text = "Cancel"
    CancelBtn.TextColor3 = Color3.fromRGB(230, 237, 243)
    CancelBtn.TextSize = 13.000

    local UICorner_26 = Instance.new("UICorner")
    UICorner_26.CornerRadius = UDim.new(0, 6)
    UICorner_26.Parent = CancelBtn

    local CreateBtn = Instance.new("TextButton")
    CreateBtn.Name = "CreateBtn"
    CreateBtn.Parent = Actions
    CreateBtn.BackgroundColor3 = Color3.fromRGB(35, 134, 54)
    CreateBtn.Position = UDim2.new(1, -82, 0, 0)
    CreateBtn.Size = UDim2.new(0, 82, 1, 0)
    CreateBtn.ZIndex = 114
    CreateBtn.Font = Enum.Font.Ubuntu
    CreateBtn.Text = "<b>Create</b>"
    CreateBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    CreateBtn.TextSize = 13.000

    local UICorner_27 = Instance.new("UICorner")
    UICorner_27.CornerRadius = UDim.new(0, 6)
    UICorner_27.Parent = CreateBtn

    --// Quick patch
    for _, v in Plugin:GetDescendants() do
        if v:IsA("TextLabel") or v:IsA("TextButton") then
            v.RichText = true
        end
    end

    return Plugin
end

return gui