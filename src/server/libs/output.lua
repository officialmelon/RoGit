--[[
Where command output goes. The terminal swaps these for its own printers (see plugin.lua),
modules print through here so they don't each need their globals replaced.
]]
local output = {}

output.print = print
output.warn = warn

function output.set(printCallback, warnCallback)
    output.print = printCallback or output.print
    output.warn = warnCallback or output.warn
end

return output
