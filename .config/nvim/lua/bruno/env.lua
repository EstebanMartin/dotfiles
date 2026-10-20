-- Environment selection, remembered per collection root.
local M = {}

local store = vim.fs.joinpath(vim.fn.stdpath("state"), "bruno.json")

local function load()
    local f = io.open(store, "r")
    if not f then return {} end
    local s = f:read("*a")
    f:close()
    local ok, d = pcall(vim.json.decode, s)
    return ok and type(d) == "table" and d or {}
end

---@param root string
---@return string[]
function M.list(root)
    local names = {}
    for name, t in vim.fs.dir(vim.fs.joinpath(root, "environments")) do
        if t == "file" and name:match("%.bru$") then
            names[#names + 1] = name:gsub("%.bru$", "")
        end
    end
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
    vim.fn.mkdir(vim.fn.fnamemodify(store, ":h"), "p")
    local f = io.open(store, "w")
    if f then
        f:write(vim.json.encode(d))
        f:close()
    end
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
