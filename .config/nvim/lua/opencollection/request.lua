-- Build a request's method, URL and body without running it: read the YAML files and
-- interpolate `{{vars}}` statically. Secret values are never resolved (shown as ********).
--
-- Precedence, lowest to highest: opencollection.yml `request.variables` < environment
-- (with its `extends` chain) < folder.yml `request.variables` (outermost to innermost)
-- < the request's own `runtime.variables`.
-- Not resolvable without a run: script-set vars, runtime vars, process.env.*, {{$dynamic}}.
local yaml = require("opencollection.yaml")
local env = require("opencollection.env")

local M = {}

local MASK = "********"

---A scalar or typed (`{ type, data }`) YAML value as text.
local function text(v)
    if type(v) == "table" then v = v.data end
    return (v == nil or v == vim.NIL) and "" or tostring(v)
end

---Enabled `{ name, value }` entries of a list (variables, params, form fields).
---@return { name: string, value: string, type: string? }[]
local function enabled(list)
    return vim.iter(type(list) == "table" and list or {})
        :filter(function(v) return type(v) == "table" and type(v.name) == "string" and v.disabled ~= true end)
        :map(function(v) return { name = v.name, value = text(v.value), type = v.type } end)
        :totable()
end

---@param file string absolute request path
---@param root string collection root
---@param name string? environment name
---@return { method: string?, url: string?, body: string?, mode: string?, unresolved: string[], masked: boolean, err: string?, body_err: string? }
function M.build(file, root, name)
    local req, err = yaml.read(file)
    local section = type(req) == "table" and (req.http or req.graphql) or nil
    if type(section) ~= "table" or type(section.url) ~= "string" or section.url == "" then
        return { unresolved = {}, masked = false, err = err or ("no request url in " .. file) }
    end

    -- variables, lowest precedence first
    local vars = {}
    local function merge_request_vars(path)
        local d = vim.fn.filereadable(path) == 1 and yaml.read(path)
        for _, v in ipairs(enabled(type(d) == "table" and type(d.request) == "table" and d.request.variables)) do
            vars[v.name] = v.value
        end
    end
    merge_request_vars(vim.fs.joinpath(root, "opencollection.yml"))
    local e = name and env.load(root, name) or { vars = {}, secrets = {} }
    vars = vim.tbl_extend("force", vars, e.vars)
    local dir = root
    for part in vim.gsplit(vim.fs.relpath(root, vim.fs.dirname(file)) or "", "/", { trimempty = true }) do
        if part ~= "." then
            dir = vim.fs.joinpath(dir, part)
            merge_request_vars(vim.fs.joinpath(dir, "folder.yml"))
        end
    end
    for _, v in ipairs(enabled(type(req.runtime) == "table" and req.runtime.variables)) do vars[v.name] = v.value end
    for _, s in ipairs(e.secrets) do vars[s] = MASK end -- secrets stay obfuscated, whatever else defines them

    local function interpolate(s)
        for _ = 1, 10 do -- vars may reference other vars
            local n
            s, n = s:gsub("{{%s*([^{}]-)%s*}}", function(k) return vars[k] end)
            if n == 0 then break end
        end
        return s
    end

    -- url, with path params (`/users/:id`) filled in
    local path_params = {}
    for _, p in ipairs(enabled(section.params)) do
        if p.type == "path" then path_params[p.name] = p.value end
    end
    local url = interpolate(section.url):gsub("/:([%w_%-]+)", function(k)
        if path_params[k] then return "/" .. interpolate(path_params[k]) end
    end)

    -- body
    local b = type(section.body) == "table" and section.body or {}
    local body, mode, body_err
    if req.graphql then
        local ok, variables = pcall(vim.json.decode, interpolate(text(b.variables)))
        body, mode = vim.json.encode({ query = interpolate(text(b.query)), variables = ok and variables or vim.empty_dict() }), "graphql"
    elseif vim.list_contains({ "json", "text", "xml", "sparql" }, b.type) then
        body, mode = interpolate(text(b.data)), b.type
    elseif b.type == "form-urlencoded" then
        local fields = vim.tbl_map(function(f) return f.name .. "=" .. f.value end, enabled(b.data))
        body, mode = interpolate(table.concat(fields, "&")), b.type
    elseif b.type and b.type ~= "none" then
        body_err = "body type '" .. tostring(b.type) .. "' is not supported"
    end

    -- what could not be resolved
    local unresolved = {}
    for k in (url .. (body or "")):gmatch("{{%s*([^{}]-)%s*}}") do
        if not vim.list_contains(unresolved, k) then unresolved[#unresolved + 1] = k end
    end

    return {
        method = type(section.method) == "string" and section.method:upper() or (req.graphql and "POST" or "GET"),
        url = url,
        body = body,
        mode = mode,
        body_err = body_err,
        unresolved = unresolved,
        masked = (url .. (body or "")):find(MASK, 1, true) ~= nil,
    }
end

return M
