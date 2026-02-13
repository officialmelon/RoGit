local Bash = {}

--[[
Bash-Esque file system
]]

function Bash.getDirectory(directory_path)
    assert(type(directory_path) == "string", "no directory supplied.")

    if directory_path == "." then 
        return game -- Game is the "root" path of everything, hence why we return that.
    end
end

return Bash