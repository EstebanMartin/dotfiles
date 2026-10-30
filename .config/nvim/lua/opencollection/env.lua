-- Environments (`environments/<name>.yml`): the one picked per collection root, the
-- collection default, and their variables with `extends` applied. Names are file names,
-- as `bru --env` takes them.
local yaml = require("opencollection.yaml")

local M = {}

local STORE = vim.fs.joinpath(vim.fn.stdpath("state"), "opencollection.json")

local picked   -- root -> env name, loaded from STORE on first use
local defaults = {} -- root -> { ftime, name }: the winbar asks on every redraw

---@param root string
---@param name string
---@return string
local function path(root, name)
    return vim.fs.joinpath(root, "environments", name .. ".yml")
end

---@param root string
---@return string[]
function M.list(root)
    local names = {}
    for file, t in vim.fs.dir(vim.fs.joinpath(root, "environments")) do
        if t == "file" and file:match("%.yml$") then names[#names + 1] = file:gsub("%.yml$", "") end
    end
    table.sort(names)
    return names
end

---The environment picked for this collection.
---@param root string
---@return string?
function M.get(root)
    if not picked then
        local ok, d = pcall(vim.json.decode, vim.fn.filereadable(STORE) == 1 and vim.fn.readblob(STORE) or "{}")
        picked = ok and type(d) == "table" and d or {}
    end
    return picked[root]
end

---@param root string
---@param name string
function M.set(root, name)
    M.get(root) -- loads the store
    picked[root] = name
    vim.fn.mkdir(vim.fs.dirname(STORE), "p")
    vim.fn.writefile({ vim.json.encode(picked) }, STORE)
end

---`extensions.bruno.defaultEnvironment` of opencollection.yml, when that file exists.
---@param root string
---@return string?
function M.default(root)
    local file = vim.fs.joinpath(root, "opencollection.yml")
    local ftime = vim.fn.getftime(file)
    if not defaults[root] or defaults[root].ftime ~= ftime then
        local d = yaml.read(file)
        local bruno = type(d) == "table" and type(d.extensions) == "table" and d.extensions.bruno
        defaults[root] = { ftime = ftime, name = type(bruno) == "table" and bruno.defaultEnvironment or nil }
    end
    local name = defaults[root].name
    if type(name) == "string" and vim.fn.filereadable(path(root, name)) == 1 then return name end
end

---The environment runs use: the picked one, else the collection default.
---@param root string
---@return string?
function M.effective(root)
    return M.get(root) or M.default(root)
end

---@param root string
---@param cb fun(env: string)?
function M.pick(root, cb)
    local envs = M.list(root)
    if #envs == 0 then return vim.notify("No environments in " .. root .. "/environments", vim.log.levels.WARN) end
    local default = M.default(root)
    vim.ui.select(envs, {
        prompt = "OpenCollection env: ",
        format_item = function(e) return e == default and (e .. " (default)") or e end,
    }, function(choice)
        if not choice then return end
        M.set(root, choice)
        vim.notify("OpenCollection env: " .. choice)
        if cb then cb(choice) end
    end)
end

---The environment files of `name`, its `extends` ancestors first (a cycle ends the chain, as in bru).
---@param root string
---@param name string
---@return { file: string, data: table }[]
local function chain(root, name)
    local out, seen = {}, {}
    local cur = name ---@type string?
    while cur and not seen[cur] do
        seen[cur] = true
        local d = vim.fn.filereadable(path(root, cur)) == 1 and yaml.read(path(root, cur))
        if type(d) ~= "table" then break end
        table.insert(out, 1, { file = path(root, cur), data = d })
        cur = type(d.extends) == "string" and d.extends or nil
    end
    return out
end

---Variables of an environment with its `extends` chain applied (the child wins).
---@param root string
---@param name string
---@return { vars: table<string,string>, secrets: string[] }
function M.load(root, name)
    local vars, is_secret = {}, {}
    for _, e in ipairs(chain(root, name)) do
        for _, v in ipairs(type(e.data.variables) == "table" and e.data.variables or {}) do
            if type(v) == "table" and type(v.name) == "string" and v.disabled ~= true and v.enabled ~= false then
                local value = type(v.value) == "table" and v.value.data or v.value -- typed: { type, data }
                vars[v.name] = value == nil and "" or tostring(value)
                is_secret[v.name] = v.secret == true or nil
            end
        end
    end
    local secrets = vim.tbl_keys(is_secret)
    table.sort(secrets)
    return { vars = vars, secrets = secrets }
end

---Modification times of the environment's files, to tell when a run result went stale.
---@param root string
---@param name string
---@return integer[]
function M.ftimes(root, name)
    return vim.tbl_map(function(e) return vim.fn.getftime(e.file) end, chain(root, name))
end

return M
