-- Build a request's URL and body without running it: parse the .bru file and interpolate
-- `{{vars}}` statically. Secret values are never resolved (shown as ********).
--
-- Precedence, lowest to highest: collection.bru < environment < folder.bru
-- (outermost to innermost) < the request's own `vars:pre-request`.
-- Not resolvable without a run: script-set vars, runtime vars, process.env.*, {{$dynamic}}.
local secrets = require("bruno.secrets")

local M = {}

local METHODS = {
    get = true, post = true, put = true, delete = true, patch = true,
    options = true, head = true, connect = true, trace = true,
}

local MASK = "********"

---Contents of a file, preferring the loaded buffer (so unsaved edits count).
---@param path string
---@return string?
local function read(path)
    local buf = vim.fn.bufnr(path)
    if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
        return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    end
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

---Dictionary blocks (`name { key: value ... }`) of a .bru file; top-level `}` closes a block.
---@param text string
---@return table<string, table<string,string>>
local function blocks(text)
    local out, cur = {}, nil
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        if cur then
            if line:match("^}") then
                cur = nil
            else
                local k, v = line:match("^%s*([^:%s][^:]*):%s*(.-)%s*$")
                if k and not k:match("^~") then cur[k] = v end
            end
        else
            local name = line:match("^([%w:%-]+)%s*{%s*$")
            if name then
                cur = {}
                out[name] = cur
            end
        end
    end
    return out
end

---@param path string
---@return table<string,string>
local function vars_of(path, block)
    local text = read(path)
    return text and blocks(text)[block] or {}
end

---Parse the request and set up interpolation (shared by url and body).
---@return table? ctx, string? err
local function load(file, root, env)
    local text = read(file)
    if not text then return nil, "cannot read " .. file end
    local req = blocks(text)

    local vars = {}
    local function merge(t) for k, v in pairs(t) do vars[k] = v end end

    merge(vars_of(vim.fs.joinpath(root, "collection.bru"), "vars:pre-request"))
    if env then merge(vars_of(vim.fs.joinpath(root, "environments", env .. ".bru"), "vars")) end

    -- folders between the collection root and the request, outermost first
    local rel = vim.fs.relpath(root, vim.fs.dirname(file))
    local dir = root
    for part in vim.gsplit(rel and rel ~= "." and rel or "", "/", { plain = true, trimempty = true }) do
        dir = vim.fs.joinpath(dir, part)
        merge(vars_of(vim.fs.joinpath(dir, "folder.bru"), "vars:pre-request"))
    end
    merge(req["vars:pre-request"] or {})

    -- secrets stay obfuscated, whatever else defines the same name
    if env then
        for _, name in ipairs(secrets.declared(root, env)) do vars[name] = MASK end
    end

    local function interpolate(s)
        for _ = 1, 10 do -- vars may reference other vars
            local n
            s, n = s:gsub("{{%s*([^{}]-)%s*}}", function(name) return vars[name] end)
            if n == 0 then break end
        end
        return s
    end

    ---@return { masked: boolean, unresolved: string[] }
    local function report(s)
        local unresolved, seen = {}, {}
        for name in s:gmatch("{{%s*([^{}]-)%s*}}") do
            if not seen[name] then
                seen[name] = true
                unresolved[#unresolved + 1] = name
            end
        end
        return { masked = s:find(MASK, 1, true) ~= nil, unresolved = unresolved }
    end

    return { text = text, req = req, interpolate = interpolate, report = report }
end

---@param file string absolute .bru path
---@param root string collection root
---@param env string? environment name
---@return { url: string?, method: string?, unresolved: string[], masked: boolean, err: string? }
function M.build(file, root, env)
    local ctx, err = load(file, root, env)
    if not ctx then return { unresolved = {}, masked = false, err = err } end

    local method, url
    for name, kv in pairs(ctx.req) do
        if METHODS[name] and kv.url then method, url = name:upper(), kv.url end
    end
    if not url then return { unresolved = {}, masked = false, err = "no request url in " .. file } end

    url = ctx.interpolate(url)
    -- path params: /users/:id
    local path = ctx.req["params:path"] or {}
    url = url:gsub("/:([%w_%-]+)", function(name)
        if path[name] then return "/" .. ctx.interpolate(path[name]) end
    end)

    local rep = ctx.report(url)
    return { url = url, method = method, unresolved = rep.unresolved, masked = rep.masked }
end

---Raw lines of a text block (`body:json { ... }`), dedented by Bruno's two-space indent.
---@param text string
---@param name string
---@return string?
local function text_block(text, name)
    local out, inside = {}, false
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        if inside then
            if line:match("^}") then return table.concat(out, "\n") end
            out[#out + 1] = (line:gsub("^  ", ""))
        elseif line:match("^" .. vim.pesc(name) .. "%s*{%s*$") then
            inside = true
        end
    end
end

local TEXT_BODIES = { json = true, text = true, xml = true, sparql = true, graphql = true }

---The request body, interpolated like the URL. Secrets stay masked.
---@return { body: string?, mode: string?, unresolved: string[], masked: boolean, err: string? }
function M.body(file, root, env)
    local ctx, err = load(file, root, env)
    if not ctx then return { unresolved = {}, masked = false, err = err } end

    local mode
    for name, kv in pairs(ctx.req) do
        if METHODS[name] and kv.url then mode = kv.body end
    end
    if not mode or mode == "none" then
        return { unresolved = {}, masked = false, err = "request has no body" }
    end

    local body
    if TEXT_BODIES[mode] then
        body = text_block(ctx.text, "body:" .. mode)
    elseif mode == "formUrlEncoded" then
        local parts = {}
        local form = blocks(ctx.text)["body:form-urlencoded"] or {}
        for k, v in pairs(form) do parts[#parts + 1] = k .. "=" .. v end
        table.sort(parts)
        body = table.concat(parts, "&")
    else
        return { unresolved = {}, masked = false, mode = mode, err = "body mode '" .. mode .. "' is not supported" }
    end
    if not body then
        return { unresolved = {}, masked = false, mode = mode, err = "no body:" .. mode .. " block" }
    end

    body = ctx.interpolate(body)
    local rep = ctx.report(body)
    return { body = body, mode = mode, unresolved = rep.unresolved, masked = rep.masked }
end

return M
