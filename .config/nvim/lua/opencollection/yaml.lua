-- Minimal YAML -> Lua decoder on top of the treesitter yaml parser.
-- Covers what OpenCollection files use: block/flow mappings and sequences, plain and
-- quoted scalars, literal (|) and folded (>) block scalars. Anchors, aliases and tags are ignored.
local M = {}

local ESCAPES = { n = "\n", t = "\t", r = "\r", ['"'] = '"', ["\\"] = "\\", ["/"] = "/", ["0"] = "\0", [" "] = " " }
local NULLS = { [""] = true, ["~"] = true, null = true, Null = true, NULL = true }
local BOOLS = { ["true"] = true, True = true, TRUE = true, ["false"] = false, False = false, FALSE = false }

---@param s string
local function plain(s)
    s = vim.trim((s:gsub("%s*\n%s*", " "))) -- multi-line plain scalars fold into one line
    if NULLS[s] then return nil end
    if BOOLS[s] ~= nil then return BOOLS[s] end
    -- YAML 1.2 core numbers only: tonumber alone would also take "0x1F", "inf", ...
    if s:match("^[-+]?%d+$") or s:match("^[-+]?%d*%.%d+$") or s:match("^[-+]?%d+%.?%d*[eE][-+]?%d+$") then
        return tonumber(s)
    end
    return s
end

---Literal (|) or folded (>) block scalar; `s` starts at the indicator line.
---@param s string
local function block_scalar(s)
    local header, rest = s:match("^([^\n]*)\n?(.*)$")
    local lines = vim.split(rest, "\n")
    while #lines > 0 and vim.trim(lines[#lines]) == "" do table.remove(lines) end
    -- content is dedented by the indentation of its least indented line
    local indent = math.huge
    for _, l in ipairs(lines) do
        if l:match("%S") then indent = math.min(indent, #l:match("^ *")) end
    end
    lines = vim.tbl_map(function(l) return l:sub(indent + 1) end, lines)

    local text = table.concat(lines, "\n")
    if header:find(">", 1, true) then
        -- folded: lines join with a space, a blank line becomes a newline
        local out = {}
        for i, l in ipairs(lines) do
            out[#out + 1] = (l == "" and "\n") or ((i > 1 and lines[i - 1] ~= "") and " " .. l) or l
        end
        text = table.concat(out)
    end
    -- chomping: "-" strips the final newline, the default keeps one
    return (header:find("-", 1, true) or text == "") and text or text .. "\n"
end

---@param node TSNode
---@param src string
---@return any
local function decode(node, src)
    local t = node:type()
    local text = t:match("scalar$") and vim.treesitter.get_node_text(node, src) or ""
    local children = vim.tbl_filter(function(c)
        return c:type() ~= "comment" and c:type() ~= "anchor" and c:type() ~= "tag"
    end, node:named_children())

    if t == "plain_scalar" then return plain(text) end
    if t == "double_quote_scalar" then
        text = text:sub(2, -2):gsub("[ \t]*\n[ \t]*", " ")
        text = text:gsub("\\u(%x%x%x%x)", function(h) return vim.fn.nr2char(tonumber(h, 16)) end)
        return (text:gsub("\\(.)", function(c) return ESCAPES[c] or ("\\" .. c) end))
    end
    if t == "single_quote_scalar" then return (text:sub(2, -2):gsub("[ \t]*\n[ \t]*", " "):gsub("''", "'")) end
    if t == "block_scalar" then return block_scalar(text) end

    if t == "block_mapping" or t == "flow_mapping" then
        local out = {}
        for _, pair in ipairs(children) do
            local k, v = pair:field("key")[1], pair:field("value")[1]
            local key = k and decode(k, src)
            if key ~= nil then out[tostring(key)] = v and decode(v, src) end
        end
        return out
    end

    if t == "block_sequence" or t == "flow_sequence" then
        local out = {}
        for _, item in ipairs(children) do
            local v
            if item:type() == "flow_pair" then -- `[a: 1]`: a single-pair mapping
                local k, val = item:field("key")[1], item:field("value")[1]
                v = { [tostring(k and decode(k, src))] = val and decode(val, src) }
            elseif item:type() == "block_sequence_item" then
                v = item:named_child(0) and decode(item:named_child(0), src)
            else -- flow sequence items are the values themselves
                v = decode(item, src)
            end
            out[#out + 1] = v == nil and vim.NIL or v -- vim.NIL keeps the index of a null item
        end
        return out
    end

    -- wrappers (stream, document, block_node, flow_node): the value inside
    return children[1] and decode(children[1], src)
end

---@param src string
---@return any value, string? err
function M.decode(src)
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, "yaml")
    if not ok then return nil, "treesitter yaml parser is not available" end
    local root = parser:parse()[1]:root()
    if root:has_error() then
        local _, err = vim.treesitter.query.parse("yaml", "(ERROR) @e"):iter_captures(root, src)()
        return nil, ("invalid YAML near line %d"):format((err and err:start() or 0) + 1)
    end
    return decode(root, src)
end

---Decode a file, preferring its loaded buffer (so unsaved edits count).
---@param path string
---@return any value, string? err
function M.read(path)
    local buf = vim.fn.bufnr(path)
    if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
        return M.decode(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    end
    if vim.fn.filereadable(path) == 0 then return nil, "cannot read " .. path end
    return M.decode(vim.fn.readblob(path))
end

return M
