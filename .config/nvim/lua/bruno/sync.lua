-- Keep a request's url and its `params:query` / `params:path` blocks in sync on save, as
-- the Bruno app does while editing. Compared with the file on disk:
--   only the params changed -> the url query becomes the enabled query params, in order,
--     as `name=value` (just `name` when the value is empty), joined by `&`
--   only the url changed    -> the params follow the url: its query params (enabled), the
--     disabled query params kept, path params matching its `/:name` segments (existing
--     values kept, new ones empty, gone ones dropped)
--   both or neither         -> nothing is rewritten
-- (bru sends the url as written; the params are only its mirror for the app.)
local M = {}

local METHODS = {
    get = true, post = true, put = true, delete = true, patch = true,
    options = true, head = true, connect = true, trace = true,
}

---One `params:*` entry: `  ~"quoted key": value` (`~` = disabled).
---@param line string
---@return table? `{ name, value, enabled }`
local function parse_entry(line)
    local disabled, rest = line:match("^%s+(~?)(.*)$")
    if not rest or rest == "" then return nil end
    local name, value
    if rest:sub(1, 1) == '"' then
        local quoted, after = rest:match('^"(.-[^\\])":%s?(.*)$')
        name, value = quoted and quoted:gsub('\\"', '"'), after
    else
        name, value = rest:match("^([^:]+):%s?(.*)$")
    end
    if not name then return nil end
    return { name = name, value = vim.trim(value), enabled = disabled == "" }
end

---The parts of a .bru request the sync needs, with their line numbers (1-based).
---@param lines string[]
---@return { url: string?, url_lnum: integer?, method_end: integer?, params: table[], blocks: table[], multiline: boolean }
local function parse(lines)
    local out = { params = {}, blocks = {}, multiline = false }
    local block, start, annotations
    for i, line in ipairs(lines) do
        if not block then
            local name = line:match("^([%w:%-]+)%s*{%s*$")
            if name then block, start, annotations = name, i, {} end
        elseif line:match("^}") then
            if METHODS[block] then out.method_end = i end
            if block == "params:query" or block == "params:path" then
                out.blocks[#out.blocks + 1] = { first = start, last = i }
            end
            block = nil
        elseif METHODS[block] and line:match("^%s+url:") then
            out.url, out.url_lnum = vim.trim(line:match("^%s+url:%s?(.*)$")), i
        elseif block == "params:query" or block == "params:path" then
            if line:find("'''", 1, true) then out.multiline = true end
            if line:match("^%s+@") then
                annotations[#annotations + 1] = vim.trim(line) -- e.g. @description(...), for the next entry
            else
                local p = parse_entry(line)
                if p then
                    p.type, p.annotations, annotations = block:sub(8), annotations, {}
                    out.params[#out.params + 1] = p
                end
            end
        end
    end
    return out
end

---What decides "changed": every param's type, name, value and state.
---@param params table[]
---@return string
local function signature(params)
    return vim.inspect(vim.tbl_map(function(p) return { p.type, p.name, p.value, p.enabled } end, params))
end

---Enabled query params, as Bruno's `stringifyQueryParams` writes them.
---@param params table[]
---@return string
local function query_string(params)
    local parts = {}
    for _, p in ipairs(params) do
        if p.type == "query" and p.enabled and vim.trim(p.name) ~= "" then
            parts[#parts + 1] = vim.trim(p.value) == "" and p.name or (p.name .. "=" .. p.value)
        end
    end
    return table.concat(parts, "&")
end

---The params the url implies, merged with the current ones the way Bruno does.
---@param url string
---@param current table[]
---@return table[]
local function params_from_url(url, current)
    local base, query = url:match("^([^?#]*)%??([^#]*)")
    local enabled_query = vim.tbl_filter(function(p) return p.type == "query" and p.enabled end, current)
    local disabled_query = vim.tbl_filter(function(p) return p.type == "query" and not p.enabled end, current)
    local old_path = vim.tbl_filter(function(p) return p.type == "path" end, current)

    -- the url's query params; one matching an old enabled param keeps its annotations
    local url_query = {}
    for part in vim.gsplit(query, "&", { trimempty = true }) do
        local name, value = part:match("^([^=]*)=?(.*)$")
        local p = { name = name, value = value, type = "query", enabled = true, annotations = {} }
        for i, old in ipairs(enabled_query) do
            if old.name == name or old.value == value then
                p.annotations = table.remove(enabled_query, i).annotations -- each match used once
                break
            end
        end
        url_query[#url_query + 1] = p
    end

    -- path params: one per `/:name` segment; existing ones keep their value
    local segments, new_path = {}, {}
    for segment in vim.gsplit(base, "/") do
        local name = segment:match("^:(.+)$")
        if name then
            segments[name] = true
            if not vim.iter(old_path):find(function(p) return p.name == name end) then
                new_path[#new_path + 1] = { name = name, value = "", type = "path", enabled = true, annotations = {} }
            end
        end
    end
    old_path = vim.tbl_filter(function(p) return segments[p.name] end, old_path)

    return vim.iter({ url_query, new_path, disabled_query, old_path }):flatten():totable()
end

---`params:query` and `params:path` blocks as bru writes them: enabled query params
---first, then the disabled ones; names quoted when they hold `:`, `"`, `{`, `}` or a space.
---Each block comes with the blank line above it.
---@param params table[]
---@return string[]
local function blocks_lines(params)
    local lines = {}
    for _, kind in ipairs({ "query", "path" }) do
        local of_kind = vim.tbl_filter(function(p) return p.type == kind end, params)
        local ordered = vim.list_extend(
            vim.tbl_filter(function(p) return p.enabled end, of_kind),
            vim.tbl_filter(function(p) return not p.enabled end, of_kind))
        if #ordered > 0 then
            vim.list_extend(lines, { "", "params:" .. kind .. " {" })
            for _, p in ipairs(ordered) do
                for _, a in ipairs(p.annotations) do lines[#lines + 1] = "  " .. a end
                local name = p.name:find('[:"{} ]') and ('"' .. p.name:gsub('"', '\\"') .. '"') or p.name
                lines[#lines + 1] = "  " .. (p.enabled and "" or "~") .. name .. ": " .. p.value
            end
            lines[#lines + 1] = "}"
        end
    end
    return lines
end

---@param buf integer
function M.on_save(buf)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local cur = parse(lines)
    if not cur.url or not cur.method_end or cur.multiline then return end
    local file = vim.api.nvim_buf_get_name(buf)
    local old = vim.fn.filereadable(file) == 1 and parse(vim.fn.readfile(file)) or nil

    local params_changed, url_changed
    if old and old.url then
        params_changed, url_changed = signature(old.params) ~= signature(cur.params), old.url ~= cur.url
    else -- new file: whichever side has query params leads
        params_changed = query_string(cur.params) ~= ""
        url_changed = not params_changed
    end

    if params_changed and not url_changed then
        local base, hash = cur.url:match("^([^?#]*)[^#]*(.*)$")
        local query = query_string(cur.params)
        local url = base .. (query ~= "" and "?" .. query or "") .. hash
        if url == cur.url then return end
        local line = lines[cur.url_lnum]
        vim.api.nvim_buf_set_lines(buf, cur.url_lnum - 1, cur.url_lnum, false, { line:match("^(%s+url:)") .. " " .. url })
        vim.notify("Bruno: url updated from params")
    elseif url_changed and not params_changed then
        local params = params_from_url(cur.url, cur.params)
        if signature(params) == signature(cur.params) then return end
        -- drop the old blocks (each with the blank line above it), bottom up so line
        -- numbers stay valid, then write the new ones right after the method block
        for i = #cur.blocks, 1, -1 do
            local b = cur.blocks[i]
            local first = lines[b.first - 1] == "" and b.first - 1 or b.first
            vim.api.nvim_buf_set_lines(buf, first - 1, b.last, false, {})
        end
        local method_end = parse(vim.api.nvim_buf_get_lines(buf, 0, -1, false)).method_end
        vim.api.nvim_buf_set_lines(buf, method_end, method_end, false, blocks_lines(params))
        vim.notify("Bruno: params updated from url")
    end
end

return M
