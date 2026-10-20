-- =============================================================================
-- Run the Bruno request in this buffer, show the response in a reusable vsplit
-- =============================================================================
-- Requires: bru (bruno-cli), jq
--
-- Flow:
--   <localleader>r -> run()          write the buffer, spawn `bru run` async
--                  -> render()       jq the reporter JSON into lines + header
--                  -> show_response() put them in the shared vsplit
--   <localleader>e -> select_env()   pick the collection's environment
--
-- Where state lives. This file is an ftplugin, so it re-executes for *every*
-- .bru buffer and any module-local would reset each time:
--   vim.g  cross-buffer  the one response buffer/window, the env per collection
--   vim.b  per-buffer    this buffer's collection root
-- Keep that split; see the notes at each section for why.

-- .bru files that aren't runnable requests
local NON_REQUEST = { ["collection.bru"] = true, ["folder.bru"] = true }

-- Namespace for the response header. nvim_create_namespace returns the same id
-- for a given name, so re-running this ftplugin keeps addressing one namespace.
local NS = vim.api.nvim_create_namespace("bru.response")

-- =============================================================================
-- Environments
-- =============================================================================
-- Selection is per collection and survives across buffers, so it lives in
-- vim.g, keyed by collection root: two collections open at once keep separate
-- envs.

-- Sentinel for "run without --env". Stored verbatim rather than as nil, so an
-- explicit choice stays distinguishable from "never chose" — otherwise clearing
-- would look unset to ensure_default_env(), which would silently re-seed an
-- environment on the next buffer open.
local NO_ENV = "(none)"

-- Set the active environment for a collection. vim.g hands back a copy on
-- read, so every write has to read-mutate-reassign the whole table; this is
-- the one place that happens, since ensure_default_env() and select_env()
-- both need it.
---@param root string collection root
---@param value string
local function set_env(root, value)
    local envs = vim.g.bru_envs or {}
    envs[root] = value
    vim.g.bru_envs = envs
end

-- Environment names, sorted. The sort is load-bearing: ensure_default_env()
-- takes the first entry, so it has to be stable rather than filesystem order.
---@param root string collection root
---@return string[] names
local function env_names(root)
    local paths = vim.fn.glob(root .. "/environments/*.bru", false, true)
    local names = vim.iter(paths)
        :map(function(path) return vim.fn.fnamemodify(path, ":t:r") end)
        :totable()
    table.sort(names)
    return names
end

-- The active env, or nil to run without --env. Cheap by design: BruWinbar calls
-- this on every redraw, so it only reads stored state. Choosing the default
-- is ensure_default_env()'s job.
---@param root string
---@return string|nil
local function current_env(root)
    local chosen = (vim.g.bru_envs or {})[root]
    if chosen == NO_ENV then return nil end
    return chosen -- nil until a default is seeded, or if there are no envs
end

-- Seed the default environment for a collection, once, at buffer setup.
--
-- Defaulting to an environment rather than none: `bru run` sends unresolved
-- {{variables}} literally, so an inherited auth token goes out as the string
-- "Bearer {{api_token}}" and the API just returns 401 with nothing on screen
-- explaining why. Use ;e to switch — the winbar always shows which env is
-- in effect.
--
-- Stored rather than derived on demand because this globs the filesystem, and
-- current_env() is on the redraw path. Consequence: an environments/*.bru added
-- after the buffer was opened won't become the default until ;e or a reload.
---@param root string
local function ensure_default_env(root)
    local envs = vim.g.bru_envs or {}
    if envs[root] then return end -- already chosen, or already defaulted

    local first = env_names(root)[1]
    if not first then return end -- collection has no environments

    set_env(root, first)
end

-- =============================================================================
-- select_env: pick the environment for this collection
-- =============================================================================
local function select_env()
    local root = vim.b.bru_root
    if not root then
        vim.notify("bru: no bruno.json found above this file", vim.log.levels.ERROR)
        return
    end

    local names = env_names(root)
    if #names == 0 then
        vim.notify("bru: no environments in " .. root, vim.log.levels.WARN)
        return
    end

    local active = current_env(root) or names[1]

    -- put the active environment first so the picker's cursor starts on it —
    -- (none) is intentionally excluded here since real environments exist;
    -- it's only offered when a collection has no environments at all
    local choices = { active }
    for _, name in ipairs(names) do
        if name ~= active then
            table.insert(choices, name)
        end
    end

    vim.ui.select(choices, {
        prompt = "Bruno environment:",
        format_item = function(item)
            if item == active then return item .. "  ←" end
            return item
        end,
    }, function(choice)
        if not choice then return end -- cancelled

        set_env(root, choice)

        vim.cmd.redrawstatus({ bang = true }) -- re-evaluate the winbar
        vim.notify("bru: environment " .. choice)
    end)
end

-- =============================================================================
-- BruWinbar: winbar contents for .bru buffers
-- =============================================================================
-- Global so the winbar's %{} can reach it. Re-evaluated on every redraw, which
-- is what keeps the env label current after a switch.
-- Renders e.g.:  "  env: prod   running ×2…"
--
-- Named with the same _<snake_case> convention as _statusline/_json_path
-- elsewhere in this config, to signal "internal global" consistently.
---@return string
function _G._bru_winbar()
    -- 'winbar' is a *window* option and the window may later show something
    -- else, so confirm a .bru buffer is actually in it
    if vim.bo.filetype ~= "bru" or not vim.b.bru_root then return "" end

    local bar = "  env: " .. (current_env(vim.b.bru_root) or NO_ENV)

    -- 'busy' counts this buffer's requests in flight (see run())
    local running = vim.bo.busy
    if running == 0 then return bar end
    return bar .. "   running" .. (running > 1 and " ×" .. running or "") .. "…"
end

-- =============================================================================
-- The response window
-- =============================================================================
-- Handles live in vim.g, not upvalues: this ftplugin re-runs for every .bru
-- buffer, so locals would reset and each file would spawn its own split.

-- The shared scratch buffer, created on first use.
---@return integer buf
local function ensure_response_buf()
    local buf = vim.g.bru_response_buf
    if buf and vim.api.nvim_buf_is_valid(buf) then return buf end

    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "bruno://response")
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide" -- not "wipe": the buffer must outlive a :q
    vim.bo[buf].swapfile = false
    vim.g.bru_response_buf = buf
    return buf
end

-- Whether to split `win` horizontally ("split") or vertically ("vsplit").
--
-- Compares cells, not pixels, but a terminal cell is roughly twice as tall as
-- it is wide, so raw column/line counts would call almost every window
-- "wide" and vsplit would win by default. Scaling height by 2 approximates
-- the on-screen aspect instead: a window that reads as taller than it is
-- wide gets stacked below; one that reads as wider than tall gets a
-- side-by-side split.
---@param win integer
---@return string "split"|"vsplit"
local function split_direction(win)
    local width = vim.api.nvim_win_get_width(win)
    local height = vim.api.nvim_win_get_height(win) * 2
    return height > width and "split" or "vsplit"
end

-- A window showing `buf` next to `request_win`, splitting one off if needed,
-- and left focused — showing a response takes you to it, wherever it ends up.
-- `request_win` is the window the request was launched from, captured by run()
-- before the async `bru run` — by the time the response is ready the user may
-- have moved to a different window or tab, and the split must still land next
-- to the request, not wherever the user happened to be at launch. The tabpage
-- check matters too: a valid window on another tabpage would otherwise be
-- rewritten off-screen, and running would look like a no-op.
---@param buf integer
---@param request_win integer|nil window the request was run from
---@return integer win
local function ensure_response_window(buf, request_win)
    -- the request window is gone (buffer/window closed mid-flight); fall back
    -- to splitting off wherever the user currently is
    if not (request_win and vim.api.nvim_win_is_valid(request_win)) then
        request_win = vim.api.nvim_get_current_win()
    end
    local target_tab = vim.api.nvim_win_get_tabpage(request_win)

    local win = vim.g.bru_response_win
    local already_open = win
        and vim.api.nvim_win_is_valid(win)
        and vim.api.nvim_win_get_tabpage(win) == target_tab

    -- switching to a tab/window you're already on is a harmless no-op, so
    -- this can run unconditionally
    vim.api.nvim_set_current_tabpage(target_tab)

    if already_open then
        vim.api.nvim_set_current_win(win)
        return win
    end

    vim.api.nvim_set_current_win(request_win)
    vim.cmd(split_direction(request_win))
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.wo[win].wrap = false
    -- the split inherits the .bru window's winbar; hand that row to
    -- ftplugin/json.lua, which fills it with the jq path under the cursor
    vim.wo[win].winbar = ""
    vim.g.bru_response_win = win

    return win
end

-- Replace the response split's contents. Called for every render, so it also
-- covers the case where the window is already open: rewrite it in place.
---@param lines string[] the response body
---@param filetype string "json" or "text"
---@param header table[] virt_lines chunks: the two-line response header
---@param request_win integer|nil window the request was run from
local function show_response(lines, filetype, header, request_win)
    local buf = ensure_response_buf()
    local win = ensure_response_window(buf, request_win)

    -- Filetype *before* the text, not after: with 'foldmethod=expr', fold levels
    -- are evaluated when the buffer changes, so the treesitter parser has to
    -- already exist. Setting it afterwards leaves the cached zeros in place and
    -- every fold silently reports "E490: No fold found". It has to happen on
    -- every render, not just at creation — a DNS error switches json -> text.
    vim.bo[buf].filetype = filetype

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    -- Header as virtual lines rather than the winbar (json.lua owns that, via a
    -- CursorMoved autocmd showing the jq path) and rather than buffer text,
    -- which would break jq paths, folds and JSON validity. Set after the lines:
    -- replacing buffer contents drops extmarks.
    vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
    vim.api.nvim_buf_set_extmark(buf, NS, 0, 0, {
        virt_lines       = header,
        virt_lines_above = true,
    })

    -- reset the view so a short response isn't left scrolled off-screen
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
end

-- =============================================================================
-- Reading the report
-- =============================================================================
-- `bru run --reporter-json` writes an array of iterations; the request we ran is
-- [0].results[0]. jq rather than vim.json.decode for the *body*: it keeps the
-- server's key order, pretty-prints, and doesn't collapse {} and [] into the
-- same Lua value. vim.json.decode is fine for the small flat metadata object,
-- where key order is irrelevant.
--
-- Both run async via vim.system + callback: on a large response body, jq isn't
-- instant, and blocking here would freeze Neovim right after an already-async
-- `bru run`.

local RESULT = ".[0].results[0]"

---@class BruMeta
---@field status integer|string|nil
---@field statusText string|nil
---@field time integer|nil       response time in ms
---@field size integer|nil       response size in bytes
---@field method string|nil
---@field url string|nil
---@field error string|nil       transport-level failure, e.g. DNS
---@field dataType string        jq `type` of the body: object|array|string|null
---@field headers table<string,string>|nil  request headers, as actually sent

-- Flat summary of the request and its response. Notifies and calls `cb(nil)`
-- if the report can't be read.
---@param report string path to the --reporter-json file
---@param cb fun(meta: BruMeta|nil)
local function read_meta(report, cb)
    local query = RESULT .. [[ | {
        status:     .response.status,
        statusText: .response.statusText,
        time:       .response.responseTime,
        size:       .response.size,
        method:     .request.method,
        url:        .request.url,
        error:      .error,
        dataType:   (.response.data | type),
        headers:    (.request.headers // {})
    }]]

    vim.system({ "jq", "-c", query, report }, { text = true }, function(out)
        vim.schedule(function()
            if out.code ~= 0 then
                vim.notify("bru: could not parse reporter output\n" .. out.stderr, vim.log.levels.ERROR)
                cb(nil)
                return
            end

            local ok, meta = pcall(vim.json.decode, out.stdout, { luanil = { object = true } })
            if not ok or type(meta) ~= "table" then
                vim.notify("bru: unexpected reporter output shape", vim.log.levels.ERROR)
                cb(nil)
                return
            end

            cb(meta)
        end)
    end)
end

-- Variable names still unresolved in the request that was actually sent.
--
-- `bru run` substitutes nothing and fails nothing when a {{variable}} has no
-- value — it sends the placeholder verbatim and reports the run as passing, so
-- the only symptom is a puzzling 401 from the API. Two known ways to get here:
-- no environment selected, and a var declared under `vars:secret` (the Bruno GUI
-- stores those values outside the .bru file, where the CLI can't reach them).
--
-- In a URL query the placeholder arrives percent-encoded, hence the second
-- pattern: {{app_key}} becomes %7B%7Bapp_key%7D%7D.
--
-- Caveat: an empty value is indistinguishable from a deliberate one, so a
-- credential that resolves to "" (rather than to a literal placeholder) can't be
-- detected here.
---@param meta BruMeta
---@return string[] names sorted and deduplicated
local function unresolved_vars(meta)
    ---@type table<string, true>
    local found = {}

    ---@param text any header/url value; only strings are scanned
    local function scan(text)
        if type(text) ~= "string" then return end
        for name in text:gmatch("{{(.-)}}") do
            found[name] = true
        end
        for name in text:gmatch("%%7[Bb]%%7[Bb](.-)%%7[Dd]%%7[Dd]") do
            found[name] = true
        end
    end

    scan(meta.url)
    for _, value in pairs(meta.headers or {}) do
        scan(value)
    end

    local names = vim.tbl_keys(found)
    table.sort(names)
    return names
end

-- The response body, trailing whitespace stripped. Empty string when bodyless.
---@param report string
---@param meta BruMeta
---@param cb fun(body: string)
local function read_body(report, meta, cb)
    local path = RESULT .. ".response.data"

    local args
    if meta.dataType == "string" then
        -- -r prints strings (HTML, plain text) raw instead of as a quoted scalar
        args = { "jq", "-r", path, report }
    else
        args = { "jq", path, report }
    end

    vim.system(args, { text = true }, function(out)
        vim.schedule(function()
            -- extra parens: gsub also returns a match count, which would leak out
            cb(((out.stdout or ""):gsub("%s+$", "")))
        end)
    end)
end

---@param meta BruMeta
---@return string filetype for the response buffer
local function body_filetype(meta)
    if meta.dataType == "object" or meta.dataType == "array" then
        return "json"
    end
    return "text"
end

-- =============================================================================
-- The response header (two virt_lines above the body)
-- =============================================================================
--     GET https://httpbin.org/get
--     200 OK  ·  0.35s  ·  0.4 KB  ·  env: prod

local SEPARATOR = { "  ·  ", "Comment" }

-- Query params whose values are credentials and shouldn't be left on screen.
-- Matched case-insensitively; add names here as needed.
local SECRET_PARAMS = {
    app_id = true,
    app_key = true,
}

local MASK = "****"

-- Replace the value of every secret query param with MASK, so a shared screen
-- or screenshot of the response header doesn't leak credentials. Only the
-- displayed URL is masked — the request itself is already sent by this point.
---@param url string
---@return string
local function mask_secrets(url)
    -- one match per "?name=value" / "&name=value"; the value is matched but not
    -- captured, and stops at the next separator so a trailing &param or
    -- #fragment is left intact
    local masked = url:gsub("([?&])([^=&#]+)=[^&#]*", function(sep, name)
        if SECRET_PARAMS[name:lower()] then
            return sep .. name .. "=" .. MASK
        end
        return nil -- leave this param untouched
    end)
    return masked
end

-- The request URL as it should appear on screen. Shared by both display paths —
-- the header's request line and the bodyless-response notify — so the masking
-- stays identical between them.
---@param meta BruMeta
---@return string
local function display_url(meta)
    return mask_secrets(tostring(meta.url or "?"))
end

-- Line 1: what was sent.
---@param meta BruMeta
---@return table[] chunks
local function request_line(meta)
    return {
        { "  ",                         "Comment" },
        { tostring(meta.method or "?"), "@keyword" },
        { " " },
        { display_url(meta),            "@string.special.url" },
    }
end

-- Colour tracks the status class, so a failure reads as one at a glance rather
-- than needing the number parsed.
---@param status integer|string|nil
---@return string highlight group
local function status_highlight(status)
    local code = tonumber(status) or 0
    if code >= 500 then return "DiagnosticError" end
    if code >= 400 then return "DiagnosticWarn" end
    if code >= 200 and code < 300 then return "DiagnosticOk" end
    return "DiagnosticInfo"
end

-- Line 2: how it went.
---@param meta BruMeta
---@param env string|nil
---@return table[] chunks
local function status_line(meta, env)
    local status = ("%s %s"):format(meta.status or "?", meta.statusText or "")
    -- meta.time comes from bru as milliseconds; shown here in seconds
    local seconds = meta.time and (meta.time / 1000) or nil
    -- meta.size comes from bru as bytes; shown here in kilobytes
    local kb = meta.size and (meta.size / 1024) or nil
    return {
        { "  " },
        { status, status_highlight(meta.status) },
        SEPARATOR,
        { (seconds and ("%.2fs"):format(seconds) or "?"), "Comment" },
        SEPARATOR,
        { (kb and ("%.1f KB"):format(kb) or "?"),         "Comment" },
        SEPARATOR,
        { "env: " .. (env or NO_ENV), "Comment" },
    }
end

-- Line 2 when there was no response at all.
---@param env string|nil
---@return table[] chunks
local function error_line(env)
    return {
        { "  " },
        { "error",                         "DiagnosticError" },
        { "  ·  env: " .. (env or NO_ENV), "Comment" },
    }
end

-- =============================================================================
-- render: turn a finished `bru run` report into split contents
-- =============================================================================
---@param report string path to the --reporter-json file
---@param env string|nil environment the request ran under
---@param request_win integer|nil window the request was run from
---@param done fun() called once rendering (or a no-op notify) has finished
local function render(report, env, request_win, done)
    read_meta(report, function(meta)
        if not meta then
            done()
            return
        end

        -- Warn before rendering, and on every path below: a request sent with
        -- placeholders instead of values usually comes back as a plausible-looking
        -- 401, which the response split alone gives no way to explain.
        local missing = unresolved_vars(meta)
        if #missing > 0 then
            vim.notify(
                "bru: variables sent unresolved: " .. table.concat(missing, ", ")
                .. "\ncheck the environment (;e), and whether they are `vars:secret`"
                .. " — bru cannot read secret values",
                vim.log.levels.WARN
            )
        end

        -- Transport-level failure (DNS, refused connection): there is no response,
        -- so the message itself is the body.
        if meta.error then
            local lines = vim.split(tostring(meta.error), "\n")
            show_response(lines, "text", { request_line(meta), error_line(env) }, request_win)
            done()
            return
        end

        read_body(report, meta, function(body)
            -- 204s and friends have no body — an empty string, or null. Nothing
            -- worth a split, so report the status and leave any previous
            -- response on screen. Masked like the header: this message
            -- persists in :messages.
            if body == "" or meta.dataType == "null" then
                vim.notify(("bru: %s %s returned %s %s without a body"):format(
                    meta.method or "?",
                    display_url(meta),
                    meta.status or "?",
                    meta.statusText or ""
                ))
                done()
                return
            end

            show_response(
                vim.split(body, "\n"),
                body_filetype(meta),
                { request_line(meta), status_line(meta, env) },
                request_win
            )
            done()
        end)
    end)
end

-- =============================================================================
-- run: execute the request in the current buffer
-- =============================================================================
local function run()
    local buf = vim.api.nvim_get_current_buf()
    -- captured now, before the async `bru run`: by the time the response
    -- comes back the user may have moved to a different window or tab, and
    -- the response split must still land next to this window, not that one
    local request_win = vim.api.nvim_get_current_win()
    local file = vim.api.nvim_buf_get_name(buf)

    if file == "" then
        vim.notify("bru: buffer has no file", vim.log.levels.WARN)
        return
    end

    local name = vim.fs.basename(file)
    local in_environments = vim.fs.basename(vim.fs.dirname(file)) == "environments"
    if NON_REQUEST[name] or in_environments then
        vim.notify("bru: " .. name .. " is not a runnable request", vim.log.levels.WARN)
        return
    end

    -- `bru run` reads the file from disk, so pending edits would silently run
    -- the previous version
    if vim.bo[buf].modified then vim.cmd.write() end

    -- `bru run` resolves paths against the collection root (the bruno.json dir)
    local root = vim.b.bru_root
    if not root then
        vim.notify("bru: no bruno.json found above " .. file, vim.log.levels.ERROR)
        return
    end

    local report = vim.fn.tempname()
    local cmd = { "bru", "run", vim.fs.relpath(root, file), "--reporter-json", report }

    local env = current_env(root)
    if env then vim.list_extend(cmd, { "--env", env }) end

    -- Requests are async, so the only feedback would otherwise be the response
    -- appearing whenever it appears. Two native indicators cover it:
    --   'busy'            per-buffer counter of runs in flight, shown as
    --                     "running…" in this buffer's winbar only
    --   progress message  animates the statusline and drives the terminal's
    --                     progress bar
    -- Both span the request and the jq parsing that follows, since both are
    -- async; nvim_echo updates the message in place via progress.id.
    ---@param delta integer +1 when the run starts, -1 when it finishes
    local function add_busy(delta)
        -- the buffer may have been wiped while the request was in flight
        if not vim.api.nvim_buf_is_valid(buf) then return end
        vim.bo[buf].busy = math.max(vim.bo[buf].busy + delta, 0)
        pcall(vim.cmd.redrawstatus, { bang = true }) -- 'busy' doesn't redraw the winbar itself
    end

    add_busy(1)
    local progress = { kind = "progress", source = "bru", title = "bru", status = "running" }
    progress.id = vim.api.nvim_echo({ { "Running " .. name } }, false, progress)

    ---@param status "success"|"failed"
    local function finish(status)
        add_busy(-1)
        progress.status = status
        vim.api.nvim_echo({ { name .. (status == "success" and " done" or " failed") } }, false, progress)
    end

    vim.system(cmd, { cwd = root, text = true }, function(res)
        -- the callback runs off the main loop; nothing below is fast-event safe
        vim.schedule(function()
            -- A non-zero exit only means the request or its assertions failed;
            -- the report is still written and is exactly what we want to show.
            -- So gate on the report existing, and use the exit code only for
            -- the error message.
            if not vim.uv.fs_stat(report) then
                local detail = res.stderr ~= "" and res.stderr or res.stdout
                vim.notify(
                    "bru: run produced no report (exit " .. res.code .. ")\n" .. detail,
                    vim.log.levels.ERROR
                )
                finish("failed")
                return
            end

            render(report, env, request_win, function()
                finish(res.code == 0 and "success" or "failed")
                vim.fn.delete(report)
            end)
        end)
    end)
end

-- =============================================================================
-- Buffer setup
-- =============================================================================
-- Both resolved once per buffer, for the same reason: the winbar re-evaluates on
-- every redraw and shouldn't walk the filesystem each time.
vim.b.bru_root = vim.fs.root(0, "bruno.json")

if vim.b.bru_root then
    ensure_default_env(vim.b.bru_root)
end

-- Plain %{} rather than %{%…%}: the latter re-reads the result as statusline
-- items, so a % in an environment filename would be taken as a format item.
-- Shared by the assignment below and the BufWinEnter callback — the two must
-- stay in sync, so don't inline either one.
local WINBAR = "%{v:lua._bru_winbar()}"

vim.opt_local.winbar = WINBAR

-- ftplugin runs on FileType, which doesn't fire for an already-loaded buffer.
-- Without this, displaying a loaded .bru file in a window that never hosted one
-- (`:b ping.bru`, a buffer picker) leaves it with no winbar — and so no env label.
vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer   = 0,
    desc     = "Bruno: winbar follows this buffer into any window",
    callback = function() vim.opt_local.winbar = WINBAR end,
})

-- =============================================================================
-- Keymaps
-- =============================================================================
vim.keymap.set("n", "<localleader>r", run, {
    buffer = true,
    desc = "Bruno: run request and show response",
})

vim.keymap.set("n", "<localleader>e", select_env, {
    buffer = true,
    desc = "Bruno: select environment",
})
