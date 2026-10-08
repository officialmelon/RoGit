--[[
git's $EDITOR, Studio style: commands that need text from you (commit messages, rebase -i todo lists...)
create a temporary ModuleScript inside .git, open it in the script editor and wait until you close its tab.

Lines starting with "--" are comments and get stripped (git uses "#"; "--" reads naturally in a Luau editor).
]]
local editor = {}

local Auth = require(script.Parent.localstore)
local bash = require(script.Parent.Parent.bash)
local output = require(script.Parent.output)

editor.COMMENT = "--"

--// Tests (or other tools) can replace this: function(text, name) -> edited text
editor.provider = nil

--[[
Removes comment lines and surrounding blank lines, like git's commit.cleanup=strip.
]]
function editor.strip(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if line:sub(1, #editor.COMMENT) ~= editor.COMMENT then
            table.insert(lines, (line:gsub("%s+$", "")))
        end
    end
    local result = table.concat(lines, "\n")
    result = result:gsub("^\n+", ""):gsub("\n\n\n+", "\n\n"):gsub("\n+$", "")
    return result
end

--[[
Opens `initial` for editing and returns what the user left in it (comments are NOT stripped here).
]]
function editor.edit(initial, name)
    if editor.provider then
        return editor.provider(initial, name)
    end

    local plugin = Auth.ACTIVE_PLUGIN or _G.ACTIVE_PLUGIN
    local root = bash.getGitFolderRoot() or game:GetService("ServerStorage")
    if not plugin then
        error("fatal: no editor available here; pass the text on the command line (e.g. -m)", 0)
    end

    local folder = root:FindFirstChild("EDITOR") or Instance.new("Folder")
    folder.Name = "EDITOR"
    folder.Parent = root

    --// a ModuleScript never runs on its own, so whatever is typed into it is harmless
    local document = Instance.new("ModuleScript")
    document.Name = name or "EDIT"
    document.Source = initial
    document.Parent = folder

    local ScriptEditorService = game:GetService("ScriptEditorService")
    local latest = initial
    local finished = Instance.new("BindableEvent")

    local function belongs(doc)
        local ok, target = pcall(function() return doc:GetScript() end)
        return ok and target == document
    end

    local changed = ScriptEditorService.TextDocumentDidChange:Connect(function(doc)
        if belongs(doc) then
            local ok, text = pcall(function() return doc:GetText() end)
            if ok then latest = text end
        end
    end)
    local closed = ScriptEditorService.TextDocumentDidClose:Connect(function(doc)
        if belongs(doc) then
            finished:Fire()
        end
    end)
    --// deleting the script also counts as "done"
    local removed = document.AncestryChanged:Connect(function()
        if not document.Parent then finished:Fire() end
    end)

    plugin:OpenScript(document)
    output.print("hint: Waiting for your editor to close the file... (close the '" .. document.Name .. "' tab when you're done)")
    finished.Event:Wait()

    changed:Disconnect()
    closed:Disconnect()
    removed:Disconnect()
    finished:Destroy()

    local text = latest
    pcall(function()
        if document.Parent and document.Source ~= initial then
            text = document.Source
        end
    end)
    pcall(function() document:Destroy() end)
    if #folder:GetChildren() == 0 then folder:Destroy() end
    return text
end

--[[
Asks for a message: `initial` is prefilled, `help` lines are added as comments. Returns the stripped message.
]]
function editor.message(initial, help, name)
    local lines = {initial or "", ""}
    for _, line in ipairs(help or {}) do
        table.insert(lines, editor.COMMENT .. (line ~= "" and (" " .. line) or ""))
    end
    return editor.strip(editor.edit(table.concat(lines, "\n"), name or "COMMIT_EDITMSG"))
end

return editor
