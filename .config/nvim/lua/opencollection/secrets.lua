-- Resolve an environment's `secret: true` variables (own and inherited via `extends`) to values.
--
-- Default source is 1Password, by naming convention (nothing to configure):
--   item = collection name (opencollection.yml `info.name`), section = environment, field = secret name
--   a section named "all" (or no section) holds values shared by every environment;
--   a field in the environment's own section overrides it
-- Optional override: `<collection>/.env`. For a secret `app_key` in env `Production`
-- the first match wins: PRODUCTION_APP_KEY, then app_key / APP_KEY. A value starting
-- with `op://` is resolved with `op read`, anything else is used as is.
--
-- 1Password account: `OP_ACCOUNT=` in .env, or $BRUNO_OP_ACCOUNT; otherwise every account
-- from `op account list` is tried, and the one that has the item is used for the session.
-- Vault (only needed when two vaults hold an item with the same name): $BRUNO_OP_VAULT.
local yaml = require("opencollection.yaml")

local M = {}

local cache = {}    -- resolved values for the session: op:// ref or item field -> value
local accounts = {} -- collection -> the 1Password account that has its item
local warned = {}   -- .env files already checked against .gitignore

---@param root string
---@return string
local function collection_name(root)
    local d = yaml.read(vim.fs.joinpath(root, "opencollection.yml"))
    return type(d) == "table" and type(d.info) == "table" and d.info.name or vim.fs.basename(root)
end

---@param s string
local function upper(s) return (s:upper():gsub("[^%w]", "_")) end

---`KEY=value` lines of the collection's .env (quotes stripped, comments skipped).
---@param path string
---@return table<string,string>
local function read_dotenv(path)
    local out = {}
    if vim.fn.filereadable(path) == 0 then return out end
    for _, line in ipairs(vim.fn.readfile(path)) do
        local k, v = line:match("^%s*([%w_.%-]+)%s*=%s*(.-)%s*$")
        if k then out[k] = v:match('^"(.*)"$') or v:match("^'(.*)'$") or v end
    end

    -- warn once per session when it sits in a git repo without being ignored
    if not warned[path] and vim.fn.executable("git") == 1 then
        warned[path] = true
        local r = vim.system({ "git", "check-ignore", "-q", path }, { cwd = vim.fs.dirname(path) }):wait()
        if r.code == 1 then
            vim.notify(path .. " is NOT gitignored: it could be committed by accident.\n"
                .. "Add it to .gitignore (shared) or .git/info/exclude (local only).", vim.log.levels.WARN)
        end
    end
    return out
end

---Field `name` of a 1Password item: the env's own section, then "all", then no section.
---@return string?
local function find_field(item, env, name)
    local shared, unsectioned
    for _, f in ipairs(item.fields or {}) do
        if f.label and f.label:lower() == name:lower() and f.value ~= nil then
            local section = f.section and f.section.label and f.section.label:lower()
            if section == env:lower() then return f.value end
            if section == "all" then shared = shared or f.value end
            if not section then unsectioned = unsectioned or f.value end
        end
    end
    return shared or unsectioned
end

---Runs inside the run coroutine: `system` waits for each `op` call without blocking the editor.
---@param root string
---@param env string?
---@param system fun(cmd: string[], opts: table?): vim.SystemCompleted
---@return table<string,string>? vars, string? err
function M.resolve(root, env, system)
    local names = env and require("opencollection.env").load(root, env).secrets or {}
    if #names == 0 then return {} end

    local dotenv = read_dotenv(vim.fs.joinpath(root, ".env"))
    local account = dotenv.OP_ACCOUNT or vim.env.BRUNO_OP_ACCOUNT
    if account == "" then account = nil end
    local vars, missing = {}, {}

    -- 1) .env values: plain, or op:// refs
    for _, name in ipairs(names) do
        local value = dotenv[upper(env) .. "_" .. upper(name)] or dotenv[name] or dotenv[upper(name)]
        if value and value:match("^op://") and not cache[value] then
            if vim.fn.executable("op") == 0 then return nil, "`op` (1Password CLI) not found in PATH" end
            local cmd = { "op", "read", "--no-newline", value }
            if account then vim.list_extend(cmd, { "--account", account }) end
            local res = system(cmd)
            if res.code ~= 0 then return nil, ("op read failed for '%s':\n%s"):format(name, vim.trim(res.stderr)) end
            cache[value] = res.stdout
        end
        value = value and (cache[value] or value)
        if value and value ~= "" then vars[name] = value else missing[#missing + 1] = name end
    end

    -- 2) the rest from the 1Password item named after the collection
    local collection = collection_name(root)
    local function key(name) return table.concat({ collection, env, name }, "\0") end
    missing = vim.tbl_filter(function(name)
        vars[name] = cache[key(name)]
        return vars[name] == nil
    end, missing)
    if #missing == 0 then return vars end
    if vim.fn.executable("op") == 0 then return nil, "`op` (1Password CLI) not found in PATH" end

    local candidates = { account or accounts[collection] }
    if #candidates == 0 then
        local list = system({ "op", "account", "list", "--format", "json" })
        local ok, d = pcall(vim.json.decode, list.stdout)
        candidates = vim.tbl_map(function(a) return a.url end, ok and type(d) == "table" and d or {})
        if #candidates == 0 then candidates = { "" } end -- "" = let op decide
    end

    local errors = {}
    for _, acc in ipairs(candidates) do
        local cmd = { "op", "item", "get", collection, "--format", "json" }
        if acc ~= "" then vim.list_extend(cmd, { "--account", acc }) end
        if (vim.env.BRUNO_OP_VAULT or "") ~= "" then vim.list_extend(cmd, { "--vault", vim.env.BRUNO_OP_VAULT }) end
        local res = system(cmd)
        local label = acc ~= "" and acc or "default account"
        if res.code == 0 then
            local ok, item = pcall(vim.json.decode, res.stdout, { luanil = { object = true, array = true } })
            if not ok then return nil, "Could not parse `op item get` output for '" .. collection .. "'" end
            local absent = {}
            for _, name in ipairs(missing) do
                local value = find_field(item, env, name)
                if value then
                    vars[name], cache[key(name)] = value, value
                else
                    absent[#absent + 1] = name
                end
            end
            if #absent > 0 then
                return nil, ("1Password item '%s' (%s) has no field in section '%s' for: %s"):format(
                    collection, label, env, table.concat(absent, ", "))
            end
            if acc ~= "" then accounts[collection] = acc end
            return vars
        end
        local msg = vim.trim(res.stderr)
        if msg:find("More than one item", 1, true) then
            return nil, ("Several items named '%s' in %s. Set BRUNO_OP_VAULT=<vault> in your shell.\n%s"):format(collection, label, msg)
        end
        errors[#errors + 1] = ("  %s: %s"):format(label, msg:match("[^\n]+$") or msg)
    end

    local all = table.concat(errors, "\n")
    if all:find("authorization", 1, true) or all:find("not signed in", 1, true) then
        return nil, "1Password did not authorize `op`: unlock the app and approve the prompt, then run again.\n" .. all
    end
    return nil, ("1Password item '%s' not found:\n%s"):format(collection, all)
end

function M.clear_cache() cache = {} end

---Open the collection's .env override file, creating it with a how-to header.
---@param root string
---@param env string
function M.edit(root, env)
    if #require("opencollection.env").load(root, env).secrets == 0 then
        return vim.notify(("Environment '%s' declares no secrets"):format(env))
    end
    local path = vim.fs.joinpath(root, ".env")
    if vim.fn.filereadable(path) == 0 then
        vim.fn.writefile({
            "# Optional overrides. Without a value here, secrets come from 1Password:",
            ("#   item '%s', section '%s' (or 'all' for every env), field = secret name"):format(collection_name(root), env),
            "# A value can be plain, or op://VAULT/ITEM/FIELD",
            ("# per environment: %s_<NAME>=..., shared: <name>=..."):format(upper(env)),
            "# OP_ACCOUNT=your-team.1password.com",
        }, path)
        vim.uv.fs_chmod(path, tonumber("600", 8))
    end
    read_dotenv(path) -- for the gitignore warning
    vim.cmd.edit(vim.fn.fnameescape(path))
end

return M
