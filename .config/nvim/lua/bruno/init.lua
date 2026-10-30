local runner = require("bruno.runner")
local ui = require("bruno.ui")
local env = require("bruno.env")
local curl = require("bruno.curl")
local secrets = require("bruno.secrets")

local M = {}

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- one run at a time: a new run cancels the previous one
local run_state = { id = 0 }

---Kill whatever is in flight: secret lookups (`op read`) and the `bru` process.
local function kill_inflight()
    if run_state.cancel_secrets then run_state.cancel_secrets() end
    if run_state.proc then pcall(run_state.proc.kill, run_state.proc, 15) end
    run_state.cancel_secrets, run_state.proc = nil, nil
end

local function stop_spinner()
    if run_state.timer then
        vim.fn.timer_stop(run_state.timer)
        run_state.timer = nil
    end
    run_state.running = nil
    vim.cmd("redrawstatus!")
end

---@param win integer window whose winbar shows the spinner
local function start_spinner(win)
    stop_spinner()
    run_state.running = { win = win, start = vim.uv.hrtime() }
    run_state.timer = vim.fn.timer_start(100, function() vim.cmd("redrawstatus!") end, { ["repeat"] = -1 })
end

---@param win integer window being drawn
---@return string
local function spinner_text(win)
    local r = run_state.running
    if not r or r.win ~= win then return "" end
    local secs = (vim.uv.hrtime() - r.start) / 1e9
    local frame = FRAMES[math.floor(secs * 10) % #FRAMES + 1]
    return ("  %%#DiagnosticInfo#%s running %.1fs%%*"):format(frame, secs)
end

---@param path string?
---@return string?
local function root_of(path)
    return vim.fs.root(path or 0, "bruno.json")
end

---mtime of a file as a comparable string ("" when missing).
---@param path string
---@return string
local function mtime(path)
    local st = vim.uv.fs_stat(path)
    return st and ("%d.%d"):format(st.mtime.sec, st.mtime.nsec) or ""
end

---Run a .bru file (default: current buffer) and show the response.
---@param opts { file: string?, env: string? }?
function M.run(opts)
    opts = opts or {}
    local file = opts.file or vim.api.nvim_buf_get_name(0)
    if file == "" or not file:match("%.bru$") then
        return vim.notify("Not a .bru file", vim.log.levels.WARN)
    end
    local root = root_of(file)
    if not root then
        return vim.notify("No bruno.json found above " .. file, vim.log.levels.ERROR)
    end
    if vim.api.nvim_buf_get_name(0) == file and vim.bo.modified then vim.cmd("silent write") end

    local name = opts.env or env.get(root)
    if not name and #env.list(root) > 0 and not opts.env_prompted then
        -- unresolved {{vars}} otherwise: choose an environment first
        return env.pick(root, function(choice)
            M.run(vim.tbl_extend("force", opts, { env = choice, env_prompted = true }))
        end)
    end
    -- what this run is based on, so :BrunoCurl can tell when the result went stale
    local stamp = {
        file = file,
        mtime = mtime(file),
        env_mtime = name and mtime(vim.fs.joinpath(root, "environments", name .. ".bru")) or "",
    }
    kill_inflight()
    run_state.id = run_state.id + 1
    local id = run_state.id
    local origin = vim.api.nvim_get_current_win()
    start_spinner(origin)

    -- 1) resolve the env's secrets (op://), 2) bru run with them as --env-var
    run_state.cancel_secrets = secrets.resolve(root, name, function(vars, serr)
        if id ~= run_state.id then return end
        if not vars then
            stop_spinner()
            return vim.notify(serr, vim.log.levels.ERROR)
        end
        run_state.proc = runner.run(file, root, name, vars, function(result, err)
            if id ~= run_state.id then return end -- superseded by a newer run
            stop_spinner()
            if not result then
                return vim.notify("bru failed:\n" .. err, vim.log.levels.ERROR)
            end
            result.env = name
            result.stamp = stamp
            ui.show(result, origin)
        end)
    end)
end

---Kill the in-flight request, keeping the previous response untouched.
function M.cancel()
    if not run_state.running then
        return vim.notify("Bruno: no request running")
    end
    kill_inflight()
    run_state.id = run_state.id + 1 -- the killed run's callback is now stale and ignored
    stop_spinner()
    vim.notify("Bruno: request cancelled")
end

---@param what "edit"|"clear"?
function M.secrets(what)
    if what == "clear" then
        secrets.clear_cache()
        return vim.notify("Bruno: cached secrets cleared")
    end
    local root = root_of()
    if not root then return vim.notify("No bruno.json found", vim.log.levels.ERROR) end
    local name = env.get(root)
    if not name then return vim.notify("Pick an environment first (:BrunoEnv)", vim.log.levels.WARN) end
    secrets.edit(root, name)
end

function M.pick_env()
    local root = root_of()
    if not root then return vim.notify("No bruno.json found", vim.log.levels.ERROR) end
    env.pick(root, function() vim.cmd.redrawstatus() end)
end

---Winbar for .bru buffers: the environment used by runs (evaluated on redraw).
---@return string
---@param win integer the window this winbar belongs to
function M.winbar(win)
    local root = root_of()
    local name = root and env.get(root)
    local text = ""
    if name then
        text = " env: %#Title#" .. name:gsub("%%", "%%%%") .. "%*"
    elseif root and #env.list(root) > 0 then
        text = " env: %#Comment#none selected%*"
    end
    return text .. spinner_text(win)
end

---All collection roots in the repo containing `start` (or below `start` outside git).
---@param start string
---@return string[]
local function repo_collections(start)
    local top = vim.fs.root(start, ".git") or start
    local files
    if vim.fs.root(start, ".git") and vim.fn.executable("git") == 1 then
        -- fast and honors .gitignore (node_modules etc.); includes untracked files
        local r = vim.system({ "git", "-C", top, "ls-files", "-co", "--exclude-standard", "--", "bruno.json", "**/bruno.json" }, { text = true }):wait()
        files = vim.tbl_map(function(f) return vim.fs.joinpath(top, f) end, vim.split(vim.trim(r.stdout or ""), "\n", { trimempty = true }))
    else
        files = vim.fs.find("bruno.json", { path = top, type = "file", limit = math.huge })
        files = vim.tbl_filter(function(f) return not f:find("/node_modules/", 1, true) and not f:find("/.git/", 1, true) end, files)
    end
    return vim.tbl_map(vim.fs.dirname, files)
end

---Collection root for the finder: the one enclosing the buffer/cwd, else any in the repo.
---@param cb fun(root: string)
local function find_root(cb)
    local root = root_of() or root_of(vim.uv.cwd())
    if root then return cb(root) end
    local start = vim.fs.dirname(vim.api.nvim_buf_get_name(0))
    if start == "" or not vim.uv.fs_stat(start) then start = vim.uv.cwd() end
    local roots = repo_collections(start)
    if #roots == 0 and start ~= vim.uv.cwd() then roots = repo_collections(vim.uv.cwd()) end
    if #roots == 0 then return vim.notify("No Bruno collection found in this repo", vim.log.levels.ERROR) end
    if #roots == 1 then return cb(roots[1]) end
    local top = vim.fs.root(start, ".git") or start
    vim.ui.select(roots, {
        prompt = "Bruno collection: ",
        format_item = function(r) return vim.fs.relpath(top, r) or r end,
    }, function(choice)
        if choice then cb(choice) end
    end)
end

function M.find()
    find_root(function(root)
        require("bruno.finder").open({ root = root, run = function(f) M.run({ file = f }) end })
    end)
end


---Shared by the static copy commands: validate the buffer, pick an env if none is
---selected, then call `fn(file, root, env_name)`.
---@param fn fun(file: string, root: string, name: string?)
---@param prompted boolean?
local function with_request(fn, prompted)
    local file = vim.api.nvim_buf_get_name(0)
    if file == "" or not file:match("%.bru$") then
        return vim.notify("Not a .bru file", vim.log.levels.WARN)
    end
    local root = root_of(file)
    if not root then return vim.notify("No bruno.json found above " .. file, vim.log.levels.ERROR) end
    local name = env.get(root)
    if not name and #env.list(root) > 0 and not prompted then
        -- unresolved {{vars}} otherwise: choose an environment first
        return env.pick(root, function() with_request(fn, true) end)
    end
    fn(file, root, name)
end

---True when the last run result is for this exact request, env and file contents.
---@param r table last result
---@param file string
---@param root string
---@param name string?
local function is_current(r, file, root, name)
    local st = r.stamp
    if not st or st.file ~= file or r.env ~= name or vim.bo.modified then return false end
    if st.mtime ~= mtime(file) then return false end
    local env_file = name and vim.fs.joinpath(root, "environments", name .. ".bru") or nil
    return st.env_mtime == (env_file and mtime(env_file) or "")
end

---Copy a curl for the current request. Uses the last run when it is still current
---(full request as sent: headers, auth, script changes); otherwise builds a basic
---curl statically (method, URL, body) without running anything.
function M.copy_curl()
    with_request(function(file, root, name)
        local last = ui.last()
        if last and is_current(last, file, root, name) then
            local cmd = curl.build(last)
            vim.fn.setreg("+", cmd)
            -- bru masks secret values in its result file
            if cmd:find("********", 1, true) then
                vim.notify("curl copied, but bru masked secret values (********)", vim.log.levels.WARN)
            else
                vim.notify("curl copied")
            end
            return
        end

        local u = require("bruno.url")
        local req = u.build(file, root, name)
        if not req.url then return vim.notify(req.err, vim.log.levels.ERROR) end
        local b = u.body(file, root, name)
        local cmd = curl.build_static(req.method, req.url, b.body, b.mode)
        vim.fn.setreg("+", cmd)

        local notes = { "no current run: basic curl (no headers/auth)" }
        if not name and #env.list(root) > 0 then notes[#notes + 1] = "no environment selected (:BrunoEnv)" end
        local unresolved = vim.list_extend(vim.deepcopy(req.unresolved), b.unresolved)
        if #unresolved > 0 then notes[#notes + 1] = "unresolved: " .. table.concat(unresolved, ", ") end
        if req.masked or b.masked then notes[#notes + 1] = "secret values masked (********)" end
        if not b.body and b.mode and b.err and not b.err:match("no body$") then
            notes[#notes + 1] = b.err
        end
        vim.notify("curl copied: " .. table.concat(notes, "; "), vim.log.levels.WARN)
    end)
end

---@param what "body"|"headers"?
function M.yank(what)
    local r = ui.last()
    if not r then return vim.notify("Run a request first", vim.log.levels.WARN) end
    local text
    if what == "headers" then
        text = table.concat(ui.header_lines(r.headers), "\n")
    else
        text = r.body
    end
    vim.fn.setreg("+", text)
    vim.notify((what or "body") .. " yanked")
end

M.toggle = ui.toggle
M.view = ui.set_view

return M
