-- Fuzzy finder over requests by logical path (folder names / request names), in the
-- order of Bruno's sidebar.
local yaml = require("opencollection.yaml")

local M = {}

---`info` of a request or folder.yml file.
---@param path string
---@return { name: string?, seq: number?, type: string? }, table? decoded file
local function info_of(path)
    local d = yaml.read(path)
    local info = type(d) == "table" and type(d.info) == "table" and d.info or {}
    return info, type(d) == "table" and d or nil
end

---@param dir string
---@param root string
---@param prefix string folder names above `dir`, joined by "/"
---@param out { display: string, file: string }[]
local function scan(dir, root, prefix, out)
    local items = {}
    for name, t in vim.fs.dir(dir) do
        local full = vim.fs.joinpath(dir, name)
        if t == "directory" and name ~= "node_modules" and name ~= ".git" and not (dir == root and name == "environments") then
            local info = vim.fn.filereadable(full .. "/folder.yml") == 1 and info_of(full .. "/folder.yml") or {}
            items[#items + 1] = { dir = full, name = info.name or name, seq = info.seq }
        elseif t == "file" and name:match("%.yml$") and name ~= "folder.yml" and name ~= "opencollection.yml" then
            local info, d = info_of(full)
            local section = d and (d.http or d.graphql)
            local method = type(section) == "table" and type(section.method) == "string" and section.method:upper()
            items[#items + 1] = { file = full, name = info.name or name:gsub("%.yml$", ""), seq = info.seq, method = method or (d and d.graphql and "GQL") }
        end
    end
    -- folders and requests mixed: by seq, then by name
    table.sort(items, function(a, b)
        if (a.seq or math.huge) ~= (b.seq or math.huge) then return (a.seq or math.huge) < (b.seq or math.huge) end
        return a.name:lower() < b.name:lower()
    end)
    for _, it in ipairs(items) do
        local path = prefix == "" and it.name or (prefix .. "/" .. it.name)
        if it.dir then
            scan(it.dir, root, path, out)
        else
            out[#out + 1] = { display = it.method and (it.method .. " " .. path) or path, file = it.file }
        end
    end
end

---@param root string
---@return { display: string, file: string }[]
function M.scan(root)
    local out = {}
    scan(root, root, "", out)
    return out
end

---@param root string
---@param run fun(file: string)
function M.open(root, run)
    local entries = vim.tbl_map(function(e) return e.display .. "\t" .. e.file end, M.scan(root))
    if #entries == 0 then return vim.notify("No requests in " .. root, vim.log.levels.WARN) end

    local function file_of(selected) return selected[1] and selected[1]:match("\t(.+)$") end
    require("fzf-lua").fzf_exec(entries, {
        prompt = "OpenCollection> ",
        fzf_opts = {
            ["--delimiter"] = "\t", ["--with-nth"] = "1", ["--nth"] = "1", ["--no-sort"] = true,
            ["--preview"] = vim.fn.executable("bat") == 1 and "bat --color=always --style=plain --language=yaml {2}" or "cat {2}",
        },
        actions = {
            ["enter"] = function(sel) vim.cmd.edit(vim.fn.fnameescape(file_of(sel))) end,
            ["ctrl-t"] = function(sel) vim.cmd.tabedit(vim.fn.fnameescape(file_of(sel))) end,
            ["ctrl-r"] = function(sel)
                vim.cmd.edit(vim.fn.fnameescape(file_of(sel)))
                run(file_of(sel))
            end,
        },
    })
end

return M
