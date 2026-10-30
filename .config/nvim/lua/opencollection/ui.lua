-- Response window: one scratch buffer, several views of the last result.
local M = {}

local VIEWS = { "body", "info", "headers", "tests", "request" }

local state = { buf = nil, view = "body", result = nil }

vim.api.nvim_set_hl(0, "OcTab", { link = "TabLine", default = true })
vim.api.nvim_set_hl(0, "OcTabActive", { link = "TabLineSel", default = true })
vim.api.nvim_set_hl(0, "OcTabFill", { link = "TabLineFill", default = true })

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
            lines[#lines + 1] = k .. ": " .. tostring(item)
        end
    end
    return lines
end

---Lines and filetype of a view of the result.
---@param r table
---@param view string
---@return string[] lines, string ft
local function view_lines(r, view)
    if view == "info" then
        local ms, time = r.time, nil
        if ms and ms < 1000 then
            time = ("%dms"):format(ms)
        elseif ms and ms < 59995 then
            time = ("%.2fs"):format(ms / 1000)
        elseif ms then
            local secs = math.floor(ms / 1000 + 0.5)
            time = ("%dm %ds"):format(math.floor(secs / 60), secs % 60)
        end
        local n = r.size
        local size = n and (n < 1024 and n .. "B" or n < 1024 * 1024 and ("%.1fKB"):format(n / 1024) or ("%.1fMB"):format(n / 1024 / 1024))
        local lines = { "Status:       " .. (r.error and "ERROR" or ("%d %s"):format(r.status, r.status_text or "")) }
        if time then lines[#lines + 1] = "Time:         " .. time end
        if size then lines[#lines + 1] = ("Size:         %s (%d bytes)"):format(size, n) end
        if r.content_type then lines[#lines + 1] = "Content-Type: " .. r.content_type end
        lines[#lines + 1] = "Request:      " .. r.method .. " " .. r.url
        if r.env then lines[#lines + 1] = "Environment:  " .. r.env end
        if r.error then lines[#lines + 1] = "Error:        " .. r.error end
        return lines, "text"
    elseif view == "headers" then
        return M.header_lines(r.headers), "text"
    elseif view == "tests" then
        local lines = vim.tbl_map(function(t)
            return (t.status == "pass" and "✓ " or "✗ ") .. t.name .. (t.error and (": " .. t.error) or "")
        end, r.tests)
        return #lines > 0 and lines or { "No tests or assertions" }, "text"
    elseif view == "request" then
        local lines = { r.method .. " " .. r.url }
        vim.list_extend(lines, M.header_lines(r.req_headers))
        local body = type(r.req_body) == "table" and vim.json.encode(r.req_body) or r.req_body
        if body and body ~= "" then
            lines[#lines + 1] = ""
            vim.list_extend(lines, vim.split(tostring(body), "\n"))
        end
        return lines, "text"
    end
    local lines = vim.split(r.body, "\n")
    if r.truncated then table.insert(lines, 1, "-- truncated at 1MB --") end
    return lines, r.ft
end

---The response window of a tabpage.
---@param tab integer? default: current
---@return integer?
local function find_win(tab)
    local ok, w = pcall(vim.api.nvim_tabpage_get_var, tab or 0, "opencollection_win")
    if ok and vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == state.buf then return w end
end

---@param tab integer? tabpage to render in (default: current)
local function render(tab)
    local r, buf = state.result, state.buf
    if not r or not buf or not vim.api.nvim_buf_is_valid(buf) then return end
    local lines, ft = view_lines(r, state.view)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    local win = find_win(tab)
    if not win then return end
    if vim.bo[buf].filetype ~= ft then
        -- FileType autocmds set window-local options (treesitter folds) on the current window
        vim.api.nvim_win_call(win, function()
            vim.bo[buf].filetype = ft
            -- the fold expr ran before the parser existed and nothing invalidates it once the
            -- parser starts, so the buffer would stay unfolded; setting the method recomputes
            vim.wo.foldmethod = "expr"
        end)
    end

    -- winbar: the view tabs; clicking one (%{i}@fn@...%X) calls OcViewClick(i)
    local tabs = {}
    for i, v in ipairs(VIEWS) do
        local label = v:sub(1, 1):upper() .. v:sub(2)
        if v == "tests" and #r.tests > 0 then
            local passed = #vim.tbl_filter(function(t) return t.status == "pass" end, r.tests)
            label = ("Tests %d/%d"):format(passed, #r.tests)
        end
        tabs[#tabs + 1] = ("%%%d@v:lua.OcViewClick@%%#%s# %s %%*%%X"):format(i, v == state.view and "OcTabActive" or "OcTab", label)
    end
    vim.wo[win].winbar = table.concat(tabs, "%#OcTabFill# ") .. "%#OcTabFill#"
    -- plain-text bodies (e.g. _cat tables) are column-aligned: don't soft-wrap them
    vim.wo[win].wrap = ft ~= "text"
end

function M.set_view(view)
    if not vim.list_contains(VIEWS, view) then return vim.notify("Unknown view: " .. view, vim.log.levels.ERROR) end
    state.view = view
    render()
end

-- winbar click handler: needs a global for the %@v:lua.Name@ syntax
function _G.OcViewClick(idx, _, button)
    if button == "l" and VIEWS[idx] then M.set_view(VIEWS[idx]) end
    return 0
end

---@param r table run result
---@param origin integer? window the request was run from; the response opens in its tabpage
---                       (the run is async, so the current tab may have changed since)
function M.show(r, origin)
    state.result = r
    -- new run: body (or info when there is no body), unless another view is open
    if state.view == "body" or state.view == "info" then state.view = r.body ~= "" and "body" or "info" end

    if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
        state.buf = vim.api.nvim_create_buf(false, true)
        vim.bo[state.buf].bufhidden = "hide"
        vim.api.nvim_buf_set_name(state.buf, "opencollection://response")
        local function cycle(dir)
            local i = vim.fn.index(VIEWS, state.view)
            M.set_view(VIEWS[(i + dir) % #VIEWS + 1])
        end
        vim.keymap.set("n", "]v", function() cycle(1) end, { buffer = state.buf, desc = "OpenCollection: next view" })
        vim.keymap.set("n", "[v", function() cycle(-1) end, { buffer = state.buf, desc = "OpenCollection: previous view" })
        vim.keymap.set("n", "<localleader>v", function()
            vim.ui.select(VIEWS, { prompt = "OpenCollection view: " }, function(v) if v then M.set_view(v) end end)
        end, { buffer = state.buf, desc = "OpenCollection: pick view" })
    end

    if not (origin and vim.api.nvim_win_is_valid(origin)) then origin = vim.api.nvim_get_current_win() end
    local tab = vim.api.nvim_win_get_tabpage(origin)
    if not find_win(tab) then
        -- win_call returns to the previous window afterwards, keeping focus on the request
        vim.api.nvim_win_call(origin, function()
            vim.cmd("botright vsplit")
            vim.api.nvim_win_set_buf(0, state.buf)
            vim.api.nvim_tabpage_set_var(tab, "opencollection_win", vim.api.nvim_get_current_win())
        end)
    end
    render(tab)
end

function M.toggle()
    local win = find_win()
    if win then return vim.api.nvim_win_close(win, true) end
    if not state.result then return vim.notify("No OpenCollection response yet") end
    M.show(state.result)
end

---@return table?
function M.last() return state.result end

return M
