--[[
Human readable diffs between two serialized instances.
]]
local diff = {}

local HttpService = game:GetService("HttpService")
local merge = require(script.Parent.merge)

local MAX_VALUE_LENGTH = 70

local function short_value(value)
    local text
    if type(value) == "string" then
        text = string.format("%q", value)
    elseif type(value) == "table" and type(value.Data) == "string" then
        text = string.format("<binary data, %d bytes>", #value.Data)
    elseif type(value) == "table" then
        local ok, encoded = pcall(function() return HttpService:JSONEncode(value) end)
        text = ok and encoded or tostring(value)
    else
        text = tostring(value)
    end
    if #text > MAX_VALUE_LENGTH then
        text = text:sub(1, MAX_VALUE_LENGTH - 3) .. "..."
    end
    return text
end

local function deep_equal(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not deep_equal(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

--[[
Appends a line diff of two strings (unified style, no context) to `out`.
]]
local function diff_text(out, oldText, newText)
    local oldLines = merge.split_lines(oldText)
    local hunks = merge.diff_hunks(oldLines, merge.split_lines(newText))
    if not hunks then
        table.insert(out, "      (file too large to diff)")
        return
    end

    for _, hunk in ipairs(hunks) do
        table.insert(out, string.format("      @@ line %d @@", hunk.s))
        for i = hunk.s, hunk.e - 1 do
            table.insert(out, "      \27[31m- " .. oldLines[i]:gsub("\n$", "") .. "\27[0m")
        end
        for _, line in ipairs(hunk.lines) do
            table.insert(out, "      \27[32m+ " .. line:gsub("\n$", "") .. "\27[0m")
        end
    end
end

--[[
Describes how an instance changed between two serialized blobs (either may be nil).
Returns a list of lines, empty if nothing changed.
]]
function diff.describe(oldJson, newJson)
    local oldProps = oldJson and merge.decode_properties(oldJson) or {}
    local newProps = newJson and merge.decode_properties(newJson) or {}
    if not oldProps or not newProps then
        return {"  (unreadable instance data)"}
    end

    local old, new = merge.flatten_properties(oldProps), merge.flatten_properties(newProps)

    local keys, seen = {}, {}
    for _, set in ipairs({old, new}) do
        for key in pairs(set) do
            if not seen[key] then
                seen[key] = true
                table.insert(keys, key)
            end
        end
    end
    table.sort(keys)

    local out = {}
    for _, key in ipairs(keys) do
        local o, n = old[key], new[key]
        if not deep_equal(o, n) then
            local kind, name = key:match("^(%a+):(.*)$")
            if kind == "tag" then
                table.insert(out, n and ("  \27[32m+ tag " .. name .. "\27[0m") or ("  \27[31m- tag " .. name .. "\27[0m"))
            elseif kind == "attr" then
                if o and n then
                    table.insert(out, string.format("  ~ attribute %s: %s -> %s", name, short_value(o.value), short_value(n.value)))
                elseif n then
                    table.insert(out, string.format("  \27[32m+ attribute %s = %s\27[0m", name, short_value(n.value)))
                else
                    table.insert(out, string.format("  \27[31m- attribute %s\27[0m", name))
                end
            elseif o and n then
                if name == "Source" and type(o.value) == "string" and type(n.value) == "string" then
                    table.insert(out, "  ~ Source:")
                    diff_text(out, o.value, n.value)
                else
                    table.insert(out, string.format("  ~ %s: %s -> %s", name, short_value(o.value), short_value(n.value)))
                end
            elseif n then
                table.insert(out, string.format("  \27[32m+ %s = %s\27[0m", name, short_value(n.value)))
            else
                table.insert(out, string.format("  \27[31m- %s\27[0m", name))
            end
        end
    end

    return out
end

return diff
