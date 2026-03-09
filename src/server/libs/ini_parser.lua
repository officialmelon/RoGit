--[[
Parses ini files and allows me to modify with ease.
]]
local ini_parser = {}

--[[
Parses an ini file and returns a table.
]]
function ini_parser.parseIni(ini_string)
    local result = {}
    local current_section = nil

    for line in string.gmatch(ini_string, "[^\r\n]+") do 
        line = line:match("^%s*(.-)%s*$") -- whitespace
        if #line >0 and not line:match("^[;#]")  then
            
            local sect_name = line:match("^%[(.+)%]$")

            if sect_name then 
                current_section = sect_name
                result[current_section] = result[current_section] or {}
            else 
                local key, val = line:match("^([^=]+)=(.*)")
                if key and current_section then 
                    key = key:match("^%s*(.-)%s*$")
                    val = val:match("^%s*(.-)%s*$")
                    result[current_section][key] = val
                end
            end

        end
    end

    return result
end

--[[
Parses a table and outputs a ini string.
]]
function ini_parser.serializeIni(ini_table)
    
    local out_lines = {}

    for sect_name, sect_tbl in pairs(ini_table) do 
        table.insert(out_lines, "[" .. sect_name .. "]")
        for key, val in pairs(sect_tbl) do 
            table.insert(out_lines, key .. " = " .. tostring(val))
        end

        table.insert(out_lines, "")
    end

    return table.concat(out_lines, "\n")
end

return ini_parser