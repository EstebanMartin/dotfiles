-- Environment selection, remembered per collection root.
local M = {}

local store = vim.fs.joinpath(vim.fn.stdpath("state"), "bruno.json")

local function load()
    local ok, d = pcall(function() return vim.json.decode(table.concat(vim.fn.readfile(store), "\n")) end)
    return ok and type(d) == "table" and d or {}
end

---@param root string
---@return string[]
function M.list(root)
    local names = vim.iter(vim.fs.dir(vim.fs.joinpath(root, "environments")))
        :map(function(name, t) return t == "file" and name:match("^(.+)%.bru$") or nil end)
        :totable()
    table.sort(names)
    return names
end

---@param root string
---@return string?
function M.get(root)
    return load()[root]
end

---@param root string
---@param name string?
function M.set(root, name)
    local d = load()
    d[root] = name
    vim.fn.mkdir(vim.fs.dirname(store), "p")
    vim.fn.writefile({ vim.json.encode(d) }, store)
end

---@param root string
---@param cb fun(env: string?)?
function M.pick(root, cb)
    local envs = M.list(root)
    if #envs == 0 then
        vim.notify("No environments in " .. root .. "/environments", vim.log.levels.WARN)
        return
    end
    vim.ui.select(envs, { prompt = "Bruno env: " }, function(choice)
        if not choice then return end
        M.set(root, choice)
        vim.notify("Bruno env: " .. choice)
        if cb then cb(choice) end
    end)
end

return M
