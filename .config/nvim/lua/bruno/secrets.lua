-- Resolve an environment's `vars:secret` names to values.
--
-- Default source is 1Password, by naming convention (nothing to configure):
--   item = collection name (bruno.json "name"), section = environment, field = secret name
--   a section named "all" (or no section) holds values shared by every environment;
--   a field in the environment's own section overrides it
--   e.g. Reddington / Production / app_key   <- `op item get Reddington`
-- Optional override: `<collection>/.env`. For a secret `app_key` in env `Production`
-- the first match wins: PRODUCTION_APP_KEY, then app_key / APP_KEY. A value starting
-- with `op://` is resolved with `op read`, anything else is used as is.
--
-- 1Password account: `OP_ACCOUNT=` in .env, or $BRUNO_OP_ACCOUNT; otherwise every account
-- from `op account list` is tried and the one that has the item is remembered.
-- Vault (only needed when two vaults hold an item with the same name): $BRUNO_OP_VAULT.
local M = {}

local cache = {} -- session cache of resolved values: key -> value

---@param root string
---@return string
local function collection_name(root)
    local f = io.open(vim.fs.joinpath(root, "bruno.json"), "r")
    local name
    if f then
        local ok, d = pcall(vim.json.decode, f:read("*a"))
        f:close()
        name = ok and type(d) == "table" and d.name or nil
    end
    return name or vim.fs.basename(root)
end

---@param root string
---@return string
function M.path(root)
    return vim.fs.joinpath(root, ".env")
end

---@param env string
---@param name string
---@return string[] candidate .env keys in priority order
local function candidates(env, name)
    local function up(x) return (x:upper():gsub("[^%w]", "_")) end
    return { up(env) .. "_" .. up(name), name, up(name) }
end

---@param entries table<string,string>
---@return string?
local function lookup(entries, env, name)
    for _, key in ipairs(candidates(env, name)) do
        local v = entries[key]
        if v and v ~= "" then return v end
    end
end

local warned = {}

---Warn once per session when the .env sits in a git repo without being ignored.
local function warn_if_not_ignored(path)
    if warned[path] or vim.fn.executable("git") == 0 then return end
    warned[path] = true
    local r = vim.system({ "git", "check-ignore", "-q", path }, { cwd = vim.fs.dirname(path) }):wait()
    if r.code == 1 then
        vim.notify(path .. " is NOT gitignored: it could be committed by accident.\n"
            .. "Add it to .gitignore (shared) or .git/info/exclude (local only).", vim.log.levels.WARN)
    end
end

---Secret names declared by `vars:secret [ a, b ]` in the environment file.
---@return string[]
function M.declared(root, env)
    local f = io.open(vim.fs.joinpath(root, "environments", env .. ".bru"), "r")
    if not f then return {} end
    local text = f:read("*a")
    f:close()
    local names = {}
    for name in (text:match("vars:secret%s*%[(.-)%]") or ""):gmatch("[^,%s]+") do
        names[#names + 1] = name
    end
    return names
end

---@return table<string, string>?
local function parse_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local out = {}
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_.%-]+)%s*=%s*(.-)%s*$")
        if k and not line:match("^%s*#") then
            out[k] = v:match('^"(.*)"$') or v:match("^'(.*)'$") or v
        end
    end
    f:close()
    return out
end

-- ---------------------------------------------------------------------------
-- remembered 1Password account per collection (state dir, not the config)
-- ---------------------------------------------------------------------------
local account_store = vim.fs.joinpath(vim.fn.stdpath("state"), "bruno-op.json")

local function load_accounts()
    local f = io.open(account_store, "r")
    if not f then return {} end
    local ok, d = pcall(vim.json.decode, f:read("*a"))
    f:close()
    return ok and type(d) == "table" and d or {}
end

local function remember_account(collection, account)
    local d = load_accounts()
    if d[collection] == account then return end
    d[collection] = account
    vim.fn.mkdir(vim.fs.dirname(account_store), "p")
    local f = io.open(account_store, "w")
    if f then
        f:write(vim.json.encode(d))
        f:close()
    end
end

---Accounts to try, in order. A single entry when the user pinned one.
---@param collection string
---@param pinned string?
---@return string[]
local function accounts_to_try(collection, pinned)
    local explicit = pinned or vim.env.BRUNO_OP_ACCOUNT
    if explicit and explicit ~= "" then return { explicit } end
    local list = {}
    local r = vim.system({ "op", "account", "list", "--format", "json" }, { text = true }):wait()
    if r.code == 0 then
        local ok, d = pcall(vim.json.decode, r.stdout)
        for _, a in ipairs(ok and d or {}) do
            if a.url then list[#list + 1] = a.url end
        end
    end
    local saved = load_accounts()[collection]
    if saved then -- remembered account first
        list = vim.tbl_filter(function(a) return a ~= saved end, list)
        table.insert(list, 1, saved)
    end
    return #list > 0 and list or { "" } -- "" = let op decide
end

---Value of `name` for `env`. Precedence: the env's own section, then a section named
---"all", then a field outside any section.
local function find_field(item, env, name)
    local shared, unsectioned
    for _, f in ipairs(item.fields or {}) do
        if f.label and f.label:lower() == name:lower() and f.value ~= nil then
            local sec = f.section and f.section.label and f.section.label:lower()
            if sec == env:lower() then return f.value end
            if sec == "all" then shared = shared or f.value end
            if not sec then unsectioned = unsectioned or f.value end
        end
    end
    return shared or unsectioned
end

---@param root string
---@param env string?
---@param cb fun(vars: table<string,string>?, err: string?)
---@return fun() cancel
function M.resolve(root, env, cb)
    local names = env and M.declared(root, env) or {}
    if #names == 0 then
        cb({})
        return function() end
    end

    local collection = collection_name(root)
    local path = M.path(root)
    local entries = parse_file(path)
    if entries then warn_if_not_ignored(path) end
    entries = entries or {}

    local vars, procs, from_item = {}, {}, {}
    local done, cancelled = false, false

    local function finish(err)
        if done or cancelled then return end
        done = true
        if err then cb(nil, err) else cb(vars) end
    end

    local function run_op(cmd, on_exit)
        procs[#procs + 1] = vim.system(cmd, { text = true }, function(res)
            vim.schedule(function()
                if done or cancelled then return end
                on_exit(res)
            end)
        end)
    end

    -- ---- step 2: whatever is not in .env comes from the 1Password item ----
    local function fetch_item()
        if vim.fn.executable("op") == 0 then
            return finish("`op` (1Password CLI) not found in PATH")
        end
        local keys = {}
        local all_cached = true
        for _, n in ipairs(from_item) do
            keys[n] = table.concat({ "item", collection, env, n }, "\0")
            if not cache[keys[n]] then all_cached = false end
        end
        if all_cached then
            for _, n in ipairs(from_item) do vars[n] = cache[keys[n]] end
            return finish()
        end

        local accounts = accounts_to_try(collection, entries.OP_ACCOUNT)
        local errors = {}
        local function try(i)
            local account = accounts[i]
            if not account then
                local all = table.concat(errors, "\n")
                local auth = all:find("authorization", 1, true) or all:find("not signed in", 1, true)
                return finish((auth and "1Password did not authorize `op`: unlock the app and approve the prompt, then run again.\n%s"
                    or ("1Password item '" .. collection .. "' not found:\n%s")):format(all))
            end
            local cmd = { "op", "item", "get", collection, "--format", "json" }
            if account ~= "" then vim.list_extend(cmd, { "--account", account }) end
            if vim.env.BRUNO_OP_VAULT and vim.env.BRUNO_OP_VAULT ~= "" then
                vim.list_extend(cmd, { "--vault", vim.env.BRUNO_OP_VAULT })
            end
            run_op(cmd, function(res)
                local label = account ~= "" and account or "default account"
                if res.code ~= 0 then
                    local msg = vim.trim(res.stderr or "")
                    if msg:find("More than one item", 1, true) then
                        return finish(("Several items named '%s' in %s. Set BRUNO_OP_VAULT=<vault> in your shell.\n%s"):format(
                            collection, label, msg))
                    end
                    errors[#errors + 1] = ("  %s: %s"):format(label, msg:match("[^\n]+$") or msg)
                    return try(i + 1)
                end
                local ok, item = pcall(vim.json.decode, res.stdout, { luanil = { object = true, array = true } })
                if not ok or type(item) ~= "table" then
                    return finish("Could not parse `op item get` output for '" .. collection .. "'")
                end
                local missing = {}
                for _, n in ipairs(from_item) do
                    local v = find_field(item, env, n)
                    if v == nil then missing[#missing + 1] = n else vars[n] = v; cache[keys[n]] = v end
                end
                if #missing > 0 then
                    return finish(("1Password item '%s' (%s) has no field in section '%s' for: %s"):format(
                        collection, label, env, table.concat(missing, ", ")))
                end
                if account ~= "" then remember_account(collection, account) end
                finish()
            end)
        end
        try(1)
    end

    -- ---- step 1: .env values (plain, or op:// refs) ----
    local pending = 0
    local function after_files()
        if #from_item > 0 then fetch_item() else finish() end
    end
    for _, name in ipairs(names) do
        local value = lookup(entries, env, name)
        local ck = path .. "\0" .. name
        if not value then
            from_item[#from_item + 1] = name
        elseif not value:match("^op://") then
            vars[name] = value
        elseif cache[ck] then
            vars[name] = cache[ck]
        else
            if vim.fn.executable("op") == 0 then
                cb(nil, "`op` (1Password CLI) not found in PATH")
                return function() end
            end
            pending = pending + 1
            local cmd = { "op", "read", "--no-newline" }
            if entries.OP_ACCOUNT then vim.list_extend(cmd, { "--account", entries.OP_ACCOUNT }) end
            cmd[#cmd + 1] = value
            run_op(cmd, function(res)
                if res.code ~= 0 then
                    return finish(("op read failed for '%s':\n%s"):format(name, vim.trim(res.stderr or "")))
                end
                cache[ck] = res.stdout
                vars[name] = res.stdout
                pending = pending - 1
                if pending == 0 then after_files() end
            end)
        end
    end
    if pending == 0 then after_files() end

    return function()
        cancelled = true
        for _, p in ipairs(procs) do pcall(p.kill, p, 15) end
    end
end

function M.clear_cache() cache = {} end

---Show where each secret of the env would come from, and open the .env override file on request.
---@param root string
---@param env string
function M.edit(root, env)
    local names = M.declared(root, env)
    if #names == 0 then
        return vim.notify(("Environment '%s' declares no secrets"):format(env))
    end
    local path = M.path(root)
    if not vim.uv.fs_stat(path) then
        local lines = {
            "# Optional overrides. Without a value here, secrets come from 1Password:",
            ("#   item '%s', section '%s' (or 'all' for every env), field = secret name"):format(collection_name(root), env),
            "# A value can be plain, or op://VAULT/ITEM/FIELD",
            ("# per environment: %s_<NAME>=..., shared: <name>=..."):format(candidates(env, "x")[1]:gsub("_X$", "")),
            "# OP_ACCOUNT=your-team.1password.com",
        }
        vim.fn.writefile(lines, path)
        vim.uv.fs_chmod(path, tonumber("600", 8))
    end
    warn_if_not_ignored(path)
    vim.cmd.edit(vim.fn.fnameescape(path))
end

return M
