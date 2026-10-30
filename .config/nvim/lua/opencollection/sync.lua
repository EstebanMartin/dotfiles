-- Keep a request's url and `params` in sync on save, as the Bruno app does while editing.
-- Compared with the file on disk:
--   only the params changed -> the url query becomes the enabled `type: query` params, in
--     order, as `name=value` (just `name` when the value is empty), joined by `&`
--   only the url changed    -> the params follow the url: its query params (enabled), the
--     disabled query params kept, path params matching its `/:name` segments (existing
--     values kept, new ones empty, gone ones dropped)
--   both or neither         -> nothing is rewritten
-- (bru sends the url as written; the params are only its mirror for the app.)
local yaml = require("opencollection.yaml")

local M = {}

-- the top-level http/graphql section's `url` and `params` pairs
local QUERY = [[
(stream (document (block_node (block_mapping (block_mapping_pair
  key: (_) @section (#any-of? @section "http" "graphql")
  value: (block_node (block_mapping
    (block_mapping_pair key: (_) @key (#any-of? @key "url" "params")) @pair)))))))
]]

---url and params of a decoded request, params as `{ name, value, type, enabled, description? }`.
---@param d any
---@return string? url, table[] params
local function read(d)
    local section = type(d) == "table" and (d.http or d.graphql) or nil
    if type(section) ~= "table" or type(section.url) ~= "string" then return nil, {} end
    local params = {}
    for _, p in ipairs(type(section.params) == "table" and section.params or {}) do
        if type(p) == "table" and (p.type == "query" or p.type == "path") then
            params[#params + 1] = {
                name = tostring(p.name or ""),
                value = p.value == nil and "" or tostring(p.value),
                type = p.type,
                enabled = p.disabled ~= true,
                description = p.description,
            }
        end
    end
    return section.url, params
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

    -- the url's query params; one matching an old enabled param keeps its description
    local url_query = {}
    for part in vim.gsplit(query, "&", { trimempty = true }) do
        local name, value = part:match("^([^=]*)=?(.*)$")
        local p = { name = name, value = value, type = "query", enabled = true }
        for i, old in ipairs(enabled_query) do
            if old.name == name or old.value == value then
                p.description = table.remove(enabled_query, i).description -- each match used once
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
                new_path[#new_path + 1] = { name = name, value = "", type = "path", enabled = true }
            end
        end
    end
    old_path = vim.tbl_filter(function(p) return segments[p.name] end, old_path)

    return vim.iter({ url_query, new_path, disabled_query, old_path }):flatten():totable()
end

---A YAML scalar: plain when it is simple text that reads back as itself, else a
---double-quoted (JSON) string, which is valid YAML.
---@param s string
---@return string
local function scalar(s)
    local d = s:match("^[%a/][%w/:._~%%+?&= -]*$") and not s:match(" $") and yaml.decode("v: " .. s)
    return (type(d) == "table" and d.v == s) and s or vim.json.encode(s)
end

---@param buf integer
function M.on_save(buf)
    local url, params = read(yaml.decode(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")))
    if not url then return end
    local file = vim.api.nvim_buf_get_name(buf)
    local old_url, old_params = read(vim.fn.filereadable(file) == 1 and yaml.decode(vim.fn.readblob(file)))

    local params_changed, url_changed
    if old_url then
        params_changed, url_changed = signature(old_params) ~= signature(params), old_url ~= url
    else -- new file: whichever side has query params leads
        params_changed = query_string(params) ~= ""
        url_changed = not params_changed
    end

    local new_url, new_params = url, params
    if params_changed and not url_changed then
        local base, hash = url:match("^([^?#]*)[^#]*(.*)$")
        local query = query_string(params)
        new_url = base .. (query ~= "" and "?" .. query or "") .. hash
    elseif url_changed and not params_changed then
        new_params = params_from_url(url, params)
    end
    if new_url == url and signature(new_params) == signature(params) then return end

    -- find the url and params pairs in the buffer
    local pairs_ = {}
    local tree = vim.treesitter.get_parser(buf, "yaml"):parse()[1]
    local query = vim.treesitter.query.parse("yaml", QUERY)
    for _, match in query:iter_matches(tree:root(), buf) do
        local key, pair
        for id, nodes in pairs(match) do
            if query.captures[id] == "key" then key = vim.treesitter.get_node_text(nodes[1], buf) end
            if query.captures[id] == "pair" then pair = nodes[1] end
        end
        pairs_[key] = pair
    end
    if not pairs_.url then return end

    if new_url ~= url then
        local value = pairs_.url:field("value")[1]
        local sr, sc, er, ec = value:range()
        vim.api.nvim_buf_set_text(buf, sr, sc, er, ec, { scalar(new_url) })
        vim.notify("OpenCollection: url updated from params")
    else
        -- rewrite the whole `params:` block (or add it after `url:`, or drop it when empty)
        local _, indent, url_end = pairs_.url:range()
        local pad = (" "):rep(indent)
        local lines = #new_params > 0 and { pad .. "params:" } or {}
        for _, p in ipairs(new_params) do
            vim.list_extend(lines, { pad .. "  - name: " .. scalar(p.name), pad .. "    value: " .. scalar(p.value), pad .. "    type: " .. p.type })
            if not p.enabled then lines[#lines + 1] = pad .. "    disabled: true" end
            if p.description then lines[#lines + 1] = pad .. "    description: " .. scalar(p.description) end
        end
        local first, last = url_end + 1, url_end + 1
        if pairs_.params then
            local _, _, er, ec = pairs_.params:range()
            first, last = pairs_.params:range(), ec == 0 and er or er + 1
        end
        vim.api.nvim_buf_set_lines(buf, first, last, false, lines)
        vim.notify("OpenCollection: params updated from url")
    end
end

return M
