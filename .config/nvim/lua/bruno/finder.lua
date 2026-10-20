-- Fuzzy finder over requests by logical path (folder names / request names).
local M = {}

local SKIP_DIR = { node_modules = true, [".git"] = true }
local SKIP_FILE = { ["collection.bru"] = true, ["folder.bru"] = true }
local METHODS = { get = true, post = true, put = true, delete = true, patch = true, options = true, head = true }

---Read `meta { name, seq }` (and the HTTP method) from the head of a .bru file.
---@param path string
---@return { name: string?, seq: number?, method: string? }
local function parse_head(path)
    local out = {}
    -- io.open + explicit close: io.lines leaves the fd open on early exit until GC,
    -- which exhausts the fd limit on big collections
    local f = io.open(path, "r")
    if not f then return out end
    local in_meta = false
    local n = 0
    for line in f:lines() do
        n = n + 1
        if n > 40 then break end
        if line:match("^meta%s*{") then
            in_meta = true
        elseif in_meta and line:match("^}") then
            in_meta = false
        elseif in_meta then
            local k, v = line:match("^%s*([%w_]+):%s*(.-)%s*$")
            if k == "name" then out.name = v elseif k == "seq" then out.seq = tonumber(v) end
        else
            local m = line:match("^(%a+)%s*{")
            if m and METHODS[m] then
                out.method = m:upper()
                break
            end
        end
    end
    f:close()
    return out
end

---@param dir string
---@param root string
---@param prefix string[] display names of ancestor folders
---@param acc table[] flat output, already in sidebar order
local function scan(dir, root, prefix, acc)
    local items = {}
    for name, t in vim.fs.dir(dir) do
        local full = vim.fs.joinpath(dir, name)
        if t == "directory" and not SKIP_DIR[name] and not (dir == root and name == "environments") then
            local meta = {}
            local fb = vim.fs.joinpath(full, "folder.bru")
            if vim.uv.fs_stat(fb) then meta = parse_head(fb) end
            items[#items + 1] = { dir = full, name = meta.name or name, seq = meta.seq }
        elseif t == "file" and name:match("%.bru$") and not SKIP_FILE[name] then
            local meta = parse_head(full)
            items[#items + 1] = { file = full, name = meta.name or name:gsub("%.bru$", ""), seq = meta.seq, method = meta.method }
        end
    end
    -- mirror Bruno's sidebar: by seq (folders and requests mixed), then name
    table.sort(items, function(a, b)
        local sa, sb = a.seq or math.huge, b.seq or math.huge
        if sa ~= sb then return sa < sb end
        return a.name:lower() < b.name:lower()
    end)
    for _, it in ipairs(items) do
        if it.dir then
            scan(it.dir, root, vim.list_extend(vim.deepcopy(prefix), { it.name }), acc)
        else
            local path = table.concat(vim.list_extend(vim.deepcopy(prefix), { it.name }), "/")
            acc[#acc + 1] = { display = it.method and (it.method .. " " .. path) or path, file = it.file }
        end
    end
end

---@param root string
---@return { display: string, file: string }[]
function M.scan(root)
    local acc = {}
    scan(root, root, {}, acc)
    return acc
end

---@param opts { root: string, run: fun(file: string) }
function M.open(opts)
    local entries = vim.tbl_map(function(e) return e.display .. "\t" .. e.file end, M.scan(opts.root))
    if #entries == 0 then return vim.notify("No requests in " .. opts.root, vim.log.levels.WARN) end

    local function pick(selected)
        local file = selected and selected[1] and selected[1]:match("\t(.+)$")
        return file
    end
    require("fzf-lua").fzf_exec(entries, {
        prompt = "Bruno> ",
        fzf_opts = {
            ["--delimiter"] = "\t", ["--with-nth"] = "1", ["--nth"] = "1", ["--no-sort"] = true,
            ["--preview"] = vim.fn.executable("bat") == 1 and "bat --color=always --style=plain {2}" or "cat {2}",
        },
        actions = {
            ["enter"] = function(sel)
                local f = pick(sel)
                if f then vim.cmd.edit(vim.fn.fnameescape(f)) end
            end,
            ["ctrl-t"] = function(sel)
                local f = pick(sel)
                if f then vim.cmd.tabedit(vim.fn.fnameescape(f)) end
            end,
            ["ctrl-r"] = function(sel)
                local f = pick(sel)
                if f then
                    vim.cmd.edit(vim.fn.fnameescape(f))
                    opts.run(f)
                end
            end,
        },
    })
end

return M
