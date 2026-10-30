-- Bruno OpenCollection (YAML) collections: run requests with `bru`, show the response.
-- Independent of the `.bru` plugin in lua/bruno: own commands, state and response window.
local env = require("opencollection.env")
local ui = require("opencollection.ui")

local M = {}

local MARKER = "opencollection.yml"
local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- one run at a time: a new run (or :OcCancel) bumps `id`, and the old run's
-- coroutine is simply never resumed again
local run = { id = 0 } ---@type { id: integer, proc: vim.SystemObj?, timer: integer?, win: integer?, start: number? }

---@param file string
---@return boolean
function M.is_request(file)
    local root = vim.fs.root(file, MARKER)
    local name = vim.fs.basename(file)
    return root ~= nil and file:match("%.yml$") ~= nil
        and name ~= MARKER and name ~= "folder.yml"
        and vim.fs.dirname(file) ~= vim.fs.joinpath(root, "environments")
end

local function stop()
    if run.proc then run.proc:kill(15) end
    if run.timer then vim.fn.timer_stop(run.timer) end
    run.proc, run.timer, run.win = nil, nil, nil
    vim.cmd.redrawstatus({ bang = true })
end

---Run a request file (default: current buffer) and show the response.
---@param opts { file: string?, env: string? }?
function M.run(opts)
    opts = opts or {}
    local file = opts.file or vim.api.nvim_buf_get_name(0)
    if not M.is_request(file) then return vim.notify("Not an OpenCollection request", vim.log.levels.WARN) end
    local root = vim.fs.root(file, MARKER) --[[@as string]]
    if vim.api.nvim_buf_get_name(0) == file and vim.bo.modified then vim.cmd("silent write") end

    local name = opts.env or env.effective(root)
    if not name and #env.list(root) > 0 then
        -- unresolved {{vars}} otherwise: choose an environment first
        return env.pick(root, function(choice) M.run({ file = file, env = choice }) end)
    end

    stop()
    run.id = run.id + 1
    local id, origin = run.id, vim.api.nvim_get_current_win()
    local co

    ---Run a command from inside the coroutine and wait for it (the editor stays responsive).
    ---@param cmd string[]
    ---@param o vim.SystemOpts?
    ---@return vim.SystemCompleted
    local function system(cmd, o)
        run.proc = vim.system(cmd, vim.tbl_extend("force", { text = true }, o or {}), function(res)
            vim.schedule(function()
                if run.id ~= id then return end -- cancelled or superseded
                run.proc = nil
                local ok, err = coroutine.resume(co, res)
                if not ok then
                    stop()
                    vim.notify(debug.traceback(co, err), vim.log.levels.ERROR)
                end
            end)
        end)
        return coroutine.yield()
    end

    co = coroutine.create(function()
        -- what this run is based on, so :OcCurl can tell when the result went stale
        local stamp = { file = file, ftime = vim.fn.getftime(file), env = name and env.ftimes(root, name) }
        local vars, err = require("opencollection.secrets").resolve(root, name, system)
        local result
        if vars then result, err = require("opencollection.runner").run(file, root, name, vars, system) end
        stop()
        if not result then return vim.notify(err, vim.log.levels.ERROR) end
        result.env, result.stamp = name, stamp
        ui.show(result, origin)
    end)

    run.win, run.start = origin, vim.uv.hrtime()
    run.timer = vim.fn.timer_start(100, function() vim.cmd.redrawstatus({ bang = true }) end, { ["repeat"] = -1 })
    coroutine.resume(co)
end

---Kill the in-flight request, keeping the previous response untouched.
function M.cancel()
    if not run.win then return vim.notify("OpenCollection: no request running") end
    run.id = run.id + 1
    stop()
    vim.notify("OpenCollection: request cancelled")
end

---Winbar for request buffers: the environment runs use, and the spinner (evaluated on redraw).
---@param win integer the window this winbar belongs to
---@return string
function M.winbar(win)
    local root = vim.fs.root(vim.api.nvim_win_get_buf(win), MARKER)
    local text = ""
    if root then
        local picked, default = env.get(root), env.default(root)
        if picked then
            text = " env: %#Title#" .. picked:gsub("%%", "%%%%") .. "%*"
        elseif default then
            text = " env: %#Title#" .. default:gsub("%%", "%%%%") .. "%* %#Comment#(default)%*"
        elseif #env.list(root) > 0 then
            text = " env: %#Comment#none selected%*"
        end
    end
    if run.win == win then
        local secs = (vim.uv.hrtime() - run.start) / 1e9
        text = text .. ("  %%#DiagnosticInfo#%s running %.1fs%%*"):format(FRAMES[math.floor(secs * 10) % #FRAMES + 1], secs)
    end
    return text
end

function M.pick_env()
    local root = vim.fs.root(0, MARKER)
    if not root then return vim.notify("No opencollection.yml found", vim.log.levels.ERROR) end
    env.pick(root, function() vim.cmd.redrawstatus() end)
end

---@param what "edit"|"clear"
function M.secrets(what)
    local secrets = require("opencollection.secrets")
    if what == "clear" then
        secrets.clear_cache()
        return vim.notify("OpenCollection: cached secrets cleared")
    end
    local root = vim.fs.root(0, MARKER)
    if not root then return vim.notify("No opencollection.yml found", vim.log.levels.ERROR) end
    local name = env.effective(root)
    if not name then return vim.notify("Pick an environment first (:OcEnv)", vim.log.levels.WARN) end
    secrets.edit(root, name)
end

---Collection root for the finder: the one enclosing the buffer or cwd, else any in the repo.
---@param cb fun(root: string)
local function find_root(cb)
    local root = vim.fs.root(0, MARKER) or vim.fs.root(vim.uv.cwd(), MARKER)
    if root then return cb(root) end
    local top = vim.fs.root(0, ".git") or vim.uv.cwd()
    local roots = vim.tbl_map(vim.fs.dirname, vim.fs.find(MARKER, {
        path = top, type = "file", limit = math.huge,
        skip = function(dir) return dir ~= "node_modules" and dir ~= ".git" end,
    }))
    if #roots == 0 then return vim.notify("No OpenCollection collection found", vim.log.levels.ERROR) end
    if #roots == 1 then return cb(roots[1]) end
    vim.ui.select(roots, {
        prompt = "OpenCollection: ",
        format_item = function(r) return vim.fs.relpath(top, r) or r end,
    }, function(choice)
        if choice then cb(choice) end
    end)
end

function M.find()
    find_root(function(root)
        require("opencollection.finder").open(root, function(f) M.run({ file = f }) end)
    end)
end

---Copy a curl for the current request. Uses the last run when it is still current (the
---request exactly as sent: headers, auth, script changes); otherwise builds a basic curl
---from the files (method, url, body) without running anything.
function M.copy_curl()
    local file = vim.api.nvim_buf_get_name(0)
    if not M.is_request(file) then return vim.notify("Not an OpenCollection request", vim.log.levels.WARN) end
    local root = vim.fs.root(file, MARKER) --[[@as string]]
    local name = env.effective(root)
    if not name and #env.list(root) > 0 then
        return env.pick(root, function() M.copy_curl() end)
    end
    local curl = require("opencollection.curl")

    local last = ui.last()
    local st = last and last.stamp
    if st and st.file == file and last.env == name and not vim.bo.modified
        and st.ftime == vim.fn.getftime(file) and vim.deep_equal(st.env, name and env.ftimes(root, name)) then
        local cmd = curl.from_result(last)
        vim.fn.setreg("+", cmd)
        if cmd:find("********", 1, true) then -- bru masks secret values in its result file
            return vim.notify("curl copied, but bru masked secret values (********)", vim.log.levels.WARN)
        end
        return vim.notify("curl copied")
    end

    local req = require("opencollection.request").build(file, root, name)
    if req.err then return vim.notify(req.err, vim.log.levels.ERROR) end
    vim.fn.setreg("+", curl.from_request(req))
    local notes = { "no current run: basic curl (no headers/auth)" }
    if not name and #env.list(root) > 0 then notes[#notes + 1] = "no environment selected (:OcEnv)" end
    if #req.unresolved > 0 then notes[#notes + 1] = "unresolved: " .. table.concat(req.unresolved, ", ") end
    if req.masked then notes[#notes + 1] = "secret values masked (********)" end
    if req.body_err then notes[#notes + 1] = req.body_err end
    vim.notify("curl copied: " .. table.concat(notes, "; "), vim.log.levels.WARN)
end

---@param what "body"|"headers"
function M.yank(what)
    local r = ui.last()
    if not r then return vim.notify("Run a request first", vim.log.levels.WARN) end
    vim.fn.setreg("+", what == "headers" and table.concat(ui.header_lines(r.headers), "\n") or r.body)
    vim.notify(what .. " yanked")
end

M.toggle = ui.toggle
M.view = ui.set_view

return M
