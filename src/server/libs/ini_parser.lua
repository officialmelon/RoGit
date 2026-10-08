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

    --// sorted, so the same settings always give the same text (.gitmodules is tracked)
    local sections = {}
    for sect_name in pairs(ini_table) do table.insert(sections, sect_name) end
    table.sort(sections)

    for _, sect_name in ipairs(sections) do
        local sect_tbl = ini_table[sect_name]
        table.insert(out_lines, "[" .. sect_name .. "]")
        local keys = {}
        for key in pairs(sect_tbl) do table.insert(keys, key) end
        table.sort(keys)
        for _, key in ipairs(keys) do
            table.insert(out_lines, "\t" .. key .. " = " .. tostring(sect_tbl[key]))
        end
    end

    return table.concat(out_lines, "\n") .. (#out_lines > 0 and "\n" or "")
end

return ini_parser