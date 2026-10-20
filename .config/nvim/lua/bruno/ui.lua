-- Response window: one scratch buffer, several views of the last result.
local M = {}

local VIEWS = { "body", "info", "headers", "tests", "request" }

local state = { buf = nil, view = "body", result = nil }

local function define_hl()
    local set = function(name, link) vim.api.nvim_set_hl(0, name, { link = link, default = true }) end
    set("BrunoTab", "TabLine")
    set("BrunoTabActive", "TabLineSel")
    set("BrunoTabFill", "TabLineFill")
end

---Milliseconds as ms (< 1s), seconds (< 1min) or minutes + seconds.
---@param ms number?
---@return string?
local function fmt_time(ms)
    if not ms then return nil end
    if ms < 1000 then return ("%dms"):format(ms) end
    if ms < 59995 then return ("%.2fs"):format(ms / 1000) end
    local secs = math.floor(ms / 1000 + 0.5)
    return ("%dm %ds"):format(math.floor(secs / 60), secs % 60)
end

local function fmt_size(n)
    if not n then return nil end
    if n < 1024 then return n .. "B" end
    if n < 1024 * 1024 then return ("%.1fKB"):format(n / 1024) end
    return ("%.1fMB"):format(n / 1024 / 1024)
end

---One "Name: value" line per value (set-cookie etc. are arrays).
---@param headers table<string, string|string[]>
---@return string[]
function M.header_lines(headers)
    local names = vim.tbl_keys(headers)
    table.sort(names)
    local lines = {}
    for _, k in ipairs(names) do
        local v = headers[k]
        for _, item in ipairs(type(v) == "table" and v or { v }) do
            lines[#lines + 1] = ("%s: %s"):format(k, tostring(item))
        end
    end
    return lines
end

local function test_counts(r)
    local pass = 0
    for _, t in ipairs(r.tests) do
        if t.status == "pass" then pass = pass + 1 end
    end
    return pass, #r.tests
end

local function label_of(r)
    return r.error and "ERROR" or ("%d %s"):format(r.status, r.status_text or "")
end

---Winbar is only the view tabs (kulala style); status, time and size live in the info view.
---@param r table
local function winbar(r)
    local tabs = {}
    for i, v in ipairs(VIEWS) do
        local text = v:sub(1, 1):upper() .. v:sub(2)
        if v == "tests" then
            local p, n = test_counts(r)
            if n > 0 then text = ("Tests %d/%d"):format(p, n) end
        end
        local hl = v == state.view and "BrunoTabActive" or "BrunoTab"
        -- %{i}@fn@...%X: clicking the label calls fn(i, ...)
        tabs[#tabs + 1] = ("%%%d@v:lua.BrunoViewClick@%%#%s# %s %%*%%X"):format(i, hl, text)
    end
    return table.concat(tabs, "%#BrunoTabFill# ") .. "%#BrunoTabFill#"
end

---@param r table
---@return string[] lines, string ft
local function view_lines(r, view)
    if view == "info" then
        local lines = { "Status:       " .. label_of(r) }
        if r.time then lines[#lines + 1] = "Time:         " .. fmt_time(r.time) end
        if r.size then lines[#lines + 1] = ("Size:         %s (%d bytes)"):format(fmt_size(r.size), r.size) end
        if r.content_type then lines[#lines + 1] = "Content-Type: " .. r.content_type end
        lines[#lines + 1] = "Request:      " .. r.method .. " " .. r.url
        if r.env then lines[#lines + 1] = "Environment:  " .. r.env end
        if r.error then lines[#lines + 1] = "Error:        " .. r.error end
        return lines, "text"
    elseif view == "headers" then
        return M.header_lines(r.headers), "text"
    elseif view == "tests" then
        local lines = {}
        for _, t in ipairs(r.tests) do
            local mark = t.status == "pass" and "✓" or "✗"
            lines[#lines + 1] = ("%s %s%s"):format(mark, t.name, t.error and (": " .. t.error) or "")
        end
        if #lines == 0 then lines = { "No tests or assertions" } end
        return lines, "text"
    elseif view == "request" then
        local lines = { r.method .. " " .. r.url }
        vim.list_extend(lines, M.header_lines(r.req_headers))
        local body = r.req_body
        if type(body) == "table" then body = vim.json.encode(body) end
        if body and body ~= "" then
            lines[#lines + 1] = ""
            vim.list_extend(lines, vim.split(tostring(body), "\n", { plain = true }))
        end
        return lines, "text"
    end
    local lines = vim.split(r.body, "\n", { plain = true })
    if r.truncated then table.insert(lines, 1, "-- truncated at 1MB --") end
    return lines, r.ft
end

local render, find_win

local function ensure_buf()
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then return state.buf end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.api.nvim_buf_set_name(buf, "bruno://response")
    local map = function(lhs, fn, desc) vim.keymap.set("n", lhs, fn, { buffer = buf, desc = desc }) end
    map("]v", function() M.cycle(1) end, "Bruno: next view")
    map("[v", function() M.cycle(-1) end, "Bruno: previous view")
    map("<localleader>v", function() M.pick_view() end, "Bruno: pick view")
    state.buf = buf
    return buf
end

---@param tab integer? tabpage to look in (default: current)
function find_win(tab)
    tab = tab or vim.api.nvim_get_current_tabpage()
    local ok, w = pcall(vim.api.nvim_tabpage_get_var, tab, "bruno_win")
    if ok and vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == state.buf then return w end
end

---@param tab integer? tabpage to render in (default: current)
function render(tab)
    local r, buf = state.result, state.buf
    if not r or not buf or not vim.api.nvim_buf_is_valid(buf) then return end
    local lines, ft = view_lines(r, state.view)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    local win = find_win(tab)
    if vim.bo[buf].filetype ~= ft then
        -- FileType autocmds set window-local options (treesitter folds) on window 0
        if win then
            vim.api.nvim_win_call(win, function()
                vim.bo[buf].filetype = ft
                -- the fold expr ran before the parser existed (empty buffer, or the
                -- previous view was text) and nothing invalidates it once the parser
                -- starts, so the buffer stays unfolded; setting the method recomputes
                vim.wo.foldmethod = "expr"
            end)
        else
            vim.bo[buf].filetype = ft
        end
    end
    if win then
        vim.wo[win].winbar = winbar(r)
        -- plain-text bodies (e.g. _cat tables) are column-aligned: don't soft-wrap them
        vim.wo[win].wrap = ft ~= "text"
    end
end

---@param r table normalized result
---@param origin integer? window the request was run from; the response opens in its tabpage
---                       (the run is async, so the current tab may have changed since)
function M.show(r, origin)
    define_hl()
    state.result = r
    -- new run: default view (body, or info when there is no body), unless the user sits on another view
    if state.view == "body" or state.view == "info" or not state.view then
        state.view = r.body ~= "" and "body" or "info"
    end
    local buf = ensure_buf()
    if not (origin and vim.api.nvim_win_is_valid(origin)) then origin = vim.api.nvim_get_current_win() end
    local tab = vim.api.nvim_win_get_tabpage(origin)
    if not find_win(tab) then
        -- win_call restores the previous window afterwards, keeping focus on the request
        vim.api.nvim_win_call(origin, function()
            vim.cmd("botright vsplit")
            local win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(win, buf)
            vim.wo[win].wrap = true
            vim.api.nvim_tabpage_set_var(tab, "bruno_win", win)
        end)
    end
    render(tab)
end

function M.set_view(view)
    if not vim.tbl_contains(VIEWS, view) then
        return vim.notify("Unknown view: " .. view, vim.log.levels.ERROR)
    end
    state.view = view
    render()
end

function M.pick_view()
    vim.ui.select(VIEWS, {
        prompt = "Bruno view: ",
        format_item = function(v) return v == state.view and (v .. " (current)") or v end,
    }, function(choice)
        if choice then M.set_view(choice) end
    end)
end

-- winbar click handler: needs a global for the %@v:lua.Name@ syntax
function _G.BrunoViewClick(idx, _, button)
    if button == "l" and VIEWS[idx] then M.set_view(VIEWS[idx]) end
    return 0
end

function M.cycle(dir)
    local i = vim.fn.index(VIEWS, state.view) + 1
    state.view = VIEWS[(i - 1 + dir) % #VIEWS + 1]
    render()
end

function M.close()
    local win = find_win()
    if win then vim.api.nvim_win_close(win, true) end
end

function M.toggle()
    if find_win() then return M.close() end
    if state.result then M.show(state.result) else vim.notify("No Bruno response yet") end
end

---@return table?
function M.last() return state.result end

return M
