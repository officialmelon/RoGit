--[[
Three-way merging for roGit.

Instances are stored as JSON blobs (a list of `{name, value, valueType}` properties), so a merge happens in layers:
 1. entity level: every instance is added/removed/changed by one side, or by both.
 2. property level: when both sides changed an instance, each property is merged on its own.
 3. text level: when both sides changed a script's `Source`, the lines are merged (diff3 style).

Everything in here is pure (no repository access), objects are read/written through callbacks.
]]
local merge = {}

local HttpService = game:GetService("HttpService")
local Utilities = require(script.Parent.utilities)

--// Largest LCS table we are willing to build (lines of base * lines of the other side).
local MAX_DIFF_CELLS = 4000000

--[[
Splits text into lines, keeping the line endings so that joining them gives back the exact text.
]]
local function split_lines(text)
    local lines = {}
    local pos = 1
    local len = #text
    while pos <= len do
        local nl = string.find(text, "\n", pos, true)
        if nl then
            lines[#lines + 1] = string.sub(text, pos, nl)
            pos = nl + 1
        else
            lines[#lines + 1] = string.sub(text, pos)
            pos = len + 1
        end
    end
    return lines
end

local function slice(list, first, last)
    local out = {}
    for i = first, last do
        out[#out + 1] = list[i]
    end
    return out
end

--[[
Finds the hunks needed to turn `base` into `other`.
A hunk replaces the base lines [s, e) with `lines`.
Returns nil when the files are too different/large to diff.
]]
local function diff_hunks(base, other)
    local n, m = #base, #other

    local pre = 0
    while pre < n and pre < m and base[pre + 1] == other[pre + 1] do
        pre += 1
    end
    local suf = 0
    while suf < n - pre and suf < m - pre and base[n - suf] == other[m - suf] do
        suf += 1
    end

    local bn, om = n - pre - suf, m - pre - suf
    if bn == 0 and om == 0 then
        return {}
    end
    if bn == 0 or om == 0 then
        return {{s = pre + 1, e = pre + bn + 1, lines = slice(other, pre + 1, pre + om)}}
    end
    if bn * om > MAX_DIFF_CELLS then
        return nil
    end

    --// dp[i][j] = length of the LCS of base[i..bn] and other[j..om] (middle sections only)
    local dp = table.create(bn + 1)
    dp[bn + 1] = table.create(om + 1, 0)
    for i = bn, 1, -1 do
        local row = table.create(om + 1, 0)
        local below = dp[i + 1]
        local baseLine = base[pre + i]
        for j = om, 1, -1 do
            if baseLine == other[pre + j] then
                row[j] = below[j + 1] + 1
            else
                local down, right = below[j], row[j + 1]
                row[j] = down >= right and down or right
            end
        end
        dp[i] = row
    end

    local hunks = {}
    local cur = nil
    local i, j = 1, 1
    while i <= bn or j <= om do
        if i <= bn and j <= om and base[pre + i] == other[pre + j] then
            if cur then
                hunks[#hunks + 1] = {s = cur.s, e = pre + i, lines = slice(other, cur.js, pre + j - 1)}
                cur = nil
            end
            i += 1
            j += 1
        else
            if not cur then
                cur = {s = pre + i, js = pre + j}
            end
            if j > om or (i <= bn and dp[i + 1][j] >= dp[i][j + 1]) then
                i += 1
            else
                j += 1
            end
        end
    end
    if cur then
        hunks[#hunks + 1] = {s = cur.s, e = pre + bn + 1, lines = slice(other, cur.js, pre + om)}
    end

    return hunks
end

local function hunks_overlap(x, y)
    return x.s == y.s or (x.s < y.e and y.s < x.e)
end

local function hunks_equal(x, y)
    if x.s ~= y.s or x.e ~= y.e or #x.lines ~= #y.lines then return false end
    for i = 1, #x.lines do
        if x.lines[i] ~= y.lines[i] then return false end
    end
    return true
end

local function with_newline(text)
    if text ~= "" and text:sub(-1) ~= "\n" then
        return text .. "\n"
    end
    return text
end

local function conflict_markers(ours, theirs, labels)
    return "<<<<<<< " .. labels.ours .. "\n" .. with_newline(ours)
        .. "=======\n" .. with_newline(theirs)
        .. ">>>>>>> " .. labels.theirs .. "\n"
end

--[[
Merges three versions of a text.
`prefer` ("ours"/"theirs") settles overlapping edits.
`labels` ({ours = "HEAD", theirs = "feature"}) writes git style <<<<<<< ======= >>>>>>> blocks for overlapping edits.
Returns the merged text and whether it holds conflict markers; nil when there is a conflict and neither option was given.
]]
function merge.merge_text(base, ours, theirs, prefer, labels)
    if ours == theirs then return ours, false end
    if base == ours then return theirs, false end
    if base == theirs then return ours, false end

    local baseLines = split_lines(base)
    local ourHunks = diff_hunks(baseLines, split_lines(ours))
    local theirHunks = diff_hunks(baseLines, split_lines(theirs))
    if not ourHunks or not theirHunks then
        if prefer == "ours" then return ours, false end
        if prefer == "theirs" then return theirs, false end
        if labels then return conflict_markers(ours, theirs, labels), true end
        return nil, true
    end

    local out = {}
    local pos = 1
    local conflicted = false

    local function emit_base_until(stop)
        for k = pos, stop - 1 do
            out[#out + 1] = baseLines[k]
        end
        if stop > pos then pos = stop end
    end
    local function emit_hunk(h)
        emit_base_until(h.s)
        for _, line in ipairs(h.lines) do
            out[#out + 1] = line
        end
        if h.e > pos then pos = h.e end
    end

    --// The text of base[s, e) with one side's hunks applied
    local function render(s, e, hunks)
        local lines = {}
        local p = s
        for _, h in ipairs(hunks) do
            for k = p, h.s - 1 do lines[#lines + 1] = baseLines[k] end
            for _, line in ipairs(h.lines) do lines[#lines + 1] = line end
            if h.e > p then p = h.e end
        end
        for k = p, e - 1 do lines[#lines + 1] = baseLines[k] end
        return table.concat(lines)
    end

    local a, c = 1, 1
    while a <= #ourHunks or c <= #theirHunks do
        local x, y = ourHunks[a], theirHunks[c]
        if x and y and hunks_overlap(x, y) then
            --// grow the region until nothing else on either side touches it
            local s, e = math.min(x.s, y.s), math.max(x.e, y.e)
            local ourRegion, theirRegion = {x}, {y}
            a += 1
            c += 1
            local grew = true
            while grew do
                grew = false
                local nx = ourHunks[a]
                if nx and (nx.s < e or nx.s == s) then
                    table.insert(ourRegion, nx)
                    if nx.e > e then e = nx.e end
                    a += 1
                    grew = true
                end
                local ny = theirHunks[c]
                if ny and (ny.s < e or ny.s == s) then
                    table.insert(theirRegion, ny)
                    if ny.e > e then e = ny.e end
                    c += 1
                    grew = true
                end
            end

            local ourText, theirText = render(s, e, ourRegion), render(s, e, theirRegion)
            emit_base_until(s)
            if ourText == theirText or prefer == "ours" then
                out[#out + 1] = ourText
            elseif prefer == "theirs" then
                out[#out + 1] = theirText
            elseif labels then
                out[#out + 1] = conflict_markers(ourText, theirText, labels)
                conflicted = true
            else
                return nil, true
            end
            pos = e
        elseif x and (not y or x.s < y.s) then
            emit_hunk(x)
            a += 1
        else
            emit_hunk(y)
            c += 1
        end
    end
    emit_base_until(#baseLines + 1)

    return table.concat(out), conflicted
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
Splits a serialized instance into a flat dictionary, so attributes and tags merge individually.
]]
local function flatten_properties(props)
    local flat = {}
    for _, prop in ipairs(props) do
        local value = prop.value
        if prop.name == "_attributes" and type(value) == "table" and type(value[1]) == "table" and value[1].name then
            for _, attr in ipairs(value) do
                flat["attr:" .. tostring(attr.name)] = attr
            end
        elseif prop.name == "_tags" and type(value) == "table" then
            for _, tag in ipairs(value) do
                flat["tag:" .. tostring(tag)] = tag
            end
        else
            flat["prop:" .. tostring(prop.name)] = prop
        end
    end
    return flat
end

local function unflatten_properties(flat)
    local props, attrs, tags = {}, {}, {}
    for key, item in pairs(flat) do
        if key:sub(1, 5) == "attr:" then
            table.insert(attrs, item)
        elseif key:sub(1, 4) == "tag:" then
            table.insert(tags, item)
        else
            table.insert(props, item)
        end
    end

    if #attrs > 0 then
        table.sort(attrs, function(a, b) return a.name < b.name end)
        table.insert(props, {name = "_attributes", value = attrs, valueType = "_attributes"})
    end
    if #tags > 0 then
        table.sort(tags)
        table.insert(props, {name = "_tags", value = tags, valueType = "_tags"})
    end

    table.sort(props, function(a, b) return a.name < b.name end)
    return props
end

local function decode_properties(content)
    if content == nil then return {} end
    local ok, props = pcall(function() return HttpService:JSONDecode(content) end)
    if ok and type(props) == "table" then return props end
    return nil
end

--[[
Merges the serialized properties of one instance.
Returns the merged JSON, plus a list of the properties that conflicted (empty on success).
]]
function merge.merge_properties(baseJson, oursJson, theirsJson, prefer, labels)
    local baseProps = decode_properties(baseJson)
    local ourProps = decode_properties(oursJson)
    local theirProps = decode_properties(theirsJson)
    if not baseProps or not ourProps or not theirProps then
        return nil, {"<unreadable instance data>"}, oursJson
    end

    local base, ours, theirs = flatten_properties(baseProps), flatten_properties(ourProps), flatten_properties(theirProps)

    local keys, seen = {}, {}
    for _, set in ipairs({base, ours, theirs}) do
        for key in pairs(set) do
            if not seen[key] then
                seen[key] = true
                table.insert(keys, key)
            end
        end
    end
    table.sort(keys)

    local result = {}
    local worktree = {}
    local conflicts = {}
    for _, key in ipairs(keys) do
        local b, o, t = base[key], ours[key], theirs[key]
        local winner, resolved = nil, true
        local fallback = nil --// what the place shows while the conflict is unresolved

        if deep_equal(o, t) then
            winner = o
        elseif deep_equal(b, o) then
            winner = t
        elseif deep_equal(b, t) then
            winner = o
        else
            resolved = false
            fallback = o
            --// Both sides changed it differently, scripts can still be merged line-by-line
            if key == "prop:Source" and type(o) == "table" and type(t) == "table"
                and type(o.value) == "string" and type(t.value) == "string"
                and (b == nil or type(b.value) == "string") then
                local merged, marked = merge.merge_text(b and b.value or "", o.value, t.value, prefer, labels)
                if merged then
                    local copy = table.clone(o)
                    copy.value = merged
                    if marked then
                        fallback = copy
                    else
                        winner = copy
                        resolved = true
                    end
                end
            end

            if not resolved and prefer == "ours" then
                winner, resolved = o, true
            elseif not resolved and prefer == "theirs" then
                winner, resolved = t, true
            end
        end

        if not resolved then
            table.insert(conflicts, (key:gsub("^%a+:", "")))
            if fallback ~= nil then worktree[key] = fallback end
        elseif winner ~= nil then
            result[key] = winner
            worktree[key] = winner
        end
    end

    if #conflicts > 0 then
        return nil, conflicts, HttpService:JSONEncode(unflatten_properties(worktree))
    end
    return HttpService:JSONEncode(unflatten_properties(result)), conflicts
end

--// exposed for diff.lua
merge.split_lines = split_lines
merge.diff_hunks = diff_hunks
merge.flatten_properties = flatten_properties
merge.decode_properties = decode_properties

local function entity_key(path)
    return path:match("^(.-)/%.properties$") or path
end

local function same_entry(a, b)
    if a == nil or b == nil then return a == b end
    return a.sha == b.sha
end

--[[
Merges three indexes ({path = {sha, mode}}).

opts.prefer       "ours" | "theirs" | nil, how to settle conflicts
opts.labels       {ours, theirs}: conflicting scripts get <<<<<<< markers in the worktree version
opts.read_blob    function(sha) -> content
opts.write_blob   function(content) -> sha

Returns merged index, conflicts ({{path, reason, worktree = entry or nil}}), merged (paths combined by property/text merging)
and the "worktree index": the merged index plus, for every conflict, the version to show in the place.
]]
function merge.merge_indexes(base, ours, theirs, opts)
    local prefer = opts.prefer

    local function entities(index)
        local ents = {}
        for path, data in pairs(index) do
            ents[entity_key(path)] = data
        end
        return ents
    end

    local b, o, t = entities(base), entities(ours), entities(theirs)

    local keys, seen = {}, {}
    for _, set in ipairs({b, o, t}) do
        for key in pairs(set) do
            if not seen[key] then
                seen[key] = true
                table.insert(keys, key)
            end
        end
    end
    table.sort(keys)

    local result = {}
    local conflicts = {}
    local merged = {}

    for _, key in ipairs(keys) do
        Utilities.roYield()
        local be, oe, te = b[key], o[key], t[key]

        if same_entry(oe, te) then
            result[key] = oe
        elseif same_entry(be, oe) then
            result[key] = te
        elseif same_entry(be, te) then
            result[key] = oe
        else
            local resolved = false
            local reason = "both modified"

            local worktree = oe or te
            if oe and te then
                local json, bad, worktreeJson = merge.merge_properties(
                    be and opts.read_blob(be.sha) or nil,
                    opts.read_blob(oe.sha),
                    opts.read_blob(te.sha),
                    prefer,
                    opts.labels
                )
                if json then
                    result[key] = {sha = opts.write_blob(json), mode = oe.mode}
                    table.insert(merged, key)
                    resolved = true
                else
                    reason = (be and "content" or "add/add") .. ": " .. table.concat(bad, ", ")
                    if worktreeJson then
                        worktree = {sha = opts.write_blob(worktreeJson), mode = oe.mode}
                    end
                end
            else
                reason = oe and "modify/delete: deleted in theirs" or "modify/delete: deleted in ours"
            end

            if not resolved then
                if prefer == "ours" then
                    result[key] = oe
                elseif prefer == "theirs" then
                    result[key] = te
                else
                    table.insert(conflicts, {path = key, reason = reason, worktree = worktree})
                end
            end
        end
    end

    --// An instance only gets a `.properties` blob when it has children, recompute that from the final set.
    local function build(entries)
        local hasChildren = {}
        for key in pairs(entries) do
            local parent = key:match("^(.*)/[^/]+$")
            while parent and not hasChildren[parent] do
                hasChildren[parent] = true
                parent = parent:match("^(.*)/[^/]+$")
            end
        end

        local index = {}
        for key, data in pairs(entries) do
            index[hasChildren[key] and (key .. "/.properties") or key] = {sha = data.sha, mode = data.mode}
        end
        return index
    end

    local worktreeEntries = table.clone(result)
    for _, conflict in ipairs(conflicts) do
        if conflict.worktree then
            worktreeEntries[conflict.path] = conflict.worktree
        end
    end

    return build(result), conflicts, merged, build(worktreeEntries)
end

return merge
