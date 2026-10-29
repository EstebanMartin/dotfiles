-- ====================================================================
-- Leaders
-- ====================================================================
vim.g.mapleader = " "      -- global leader key
vim.g.maplocalleader = ";" -- filetype-specific leader

-- ====================================================================
-- gf (visual): open file:line from selection, reusing adjacent split
-- ====================================================================
-- select some text like "path/to/file.go:42" and press gf to open it
vim.keymap.set("x", "gf", function()
    -- read the selection without touching a register, joining wrapped lines
    local text = table.concat(vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = vim.fn.mode() }))
    vim.cmd.normal({ vim.keycode("<Esc>"), bang = true }) -- leave visual mode

    -- try to split into "filename:linenumber"; if that doesn't match,
    -- just treat the whole selection as the filename
    local filename, line_num = text:match("^([^:]+):(%d+)$")
    filename = filename or text

    -- make sure the file actually exists before doing anything else
    if vim.fn.filereadable(filename) == 0 then
        vim.notify("Error: Target path '" .. text .. "' is not a valid file.", vim.log.levels.ERROR)
        return
    end

    -- prefer opening the file in a window that's already above or below
    -- the current one, instead of always creating a new split
    local cur_winnr = vim.fn.winnr()
    local below_winnr = vim.fn.winnr("j") -- window number below, if any
    local above_winnr = vim.fn.winnr("k") -- window number above, if any

    if below_winnr ~= cur_winnr then
        vim.api.nvim_set_current_win(vim.fn.win_getid(below_winnr))
    elseif above_winnr ~= cur_winnr then
        vim.api.nvim_set_current_win(vim.fn.win_getid(above_winnr))
    else
        -- no window above or below exists yet, so create one
        local buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_open_win(buf, true, {
            split = "below", win = 0,
        })
    end

    -- open the file, then jump to the line number if we found one
    vim.cmd.edit(vim.fn.fnameescape(filename))
    if line_num then
        vim.api.nvim_win_set_cursor(0, { tonumber(line_num), 0 })
    end
end, { desc = "Jump to file:line (join wrapped lines)" })

-- ====================================================================
-- gF (terminal): open file:line:col under cursor in the previous window
-- ====================================================================
-- native gF replaces the terminal itself; this keeps the terminal visible
-- and opens e.g. "lib/foo.go:209:64: cannot use..." where you came from
vim.api.nvim_create_autocmd("TermOpen", {
    desc = "Terminal gF opens file:line in previous window",
    callback = function(ev)
        vim.keymap.set("n", "gF", function()
            -- <cWORD> keeps the ":209:64:" suffix that <cfile> drops
            local word = vim.fn.expand("<cWORD>")
            local filename, line_num, col = word:match("^([^:]+):(%d+):?(%d*)")
            filename = filename or vim.fn.expand("<cfile>")

            if vim.fn.filereadable(filename) == 0 then
                vim.notify("Error: '" .. filename .. "' is not a readable file.", vim.log.levels.ERROR)
                return
            end

            -- winnr("#") is 0 when there's no previous window; split instead
            if vim.fn.winnr("#") ~= 0 and vim.fn.winnr("#") ~= vim.fn.winnr() then
                vim.cmd.wincmd("p")
            else
                vim.cmd.split()
            end

            vim.cmd.edit(vim.fn.fnameescape(filename))
            if line_num then
                local c = tonumber(col) or 1
                vim.api.nvim_win_set_cursor(0, { tonumber(line_num), math.max(c - 1, 0) })
            end
        end, { buffer = ev.buf, desc = "Open file:line:col in previous window" })
    end,
})

-- ====================================================================
-- <C-w>D: diagnostics to quickfix, cursor at nearest
-- ====================================================================
-- sends all diagnostics (errors/warnings) to the quickfix list, then
-- moves the cursor to whichever one is closest to where we started
vim.keymap.set("n", "<C-w>D", function()
    local line = vim.fn.line(".") -- remember our current line
    vim.diagnostic.setqflist()    -- fill the quickfix list with diagnostics

    -- find the quickfix entry that's closest to our original line
    local min, nearest = math.huge, 1
    for i, e in ipairs(vim.fn.getqflist()) do
        local d = math.abs(e.lnum - line)
        if d < min then
            nearest, min = i, d
        end
    end

    vim.cmd.copen()                                -- open the quickfix window
    vim.api.nvim_win_set_cursor(0, { nearest, 0 }) -- jump to the closest entry
end, { desc = "Diagnostics quickfix at nearest" })

-- ====================================================================
-- Auto-close brackets
-- ====================================================================
-- Used by <C-l> below; mini.pairs (plugin/mini-nvim.lua) handles <CR>
-- inside a pair. Checking the character directly, rather than mapping on
-- a sequence like "{<Tab>": the latter makes "{" an ambiguous prefix of a
-- longer mapping, so Neovim holds it undisplayed for up to 'timeoutlen'
-- (1000ms here, unset) waiting to see whether <Tab> follows.
local bracket_pairs = { ["{"] = "}", ["["] = "]", ["("] = ")" }

---@return string? closing bracket, if the cursor sits right after its opener
local function pair_before_cursor()
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2] -- 0-based byte offset
    return bracket_pairs[line:sub(col, col)]
end

---@return string character right after the cursor, if any
local function char_after_cursor()
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2] -- 0-based byte offset
    return line:sub(col + 1, col + 1)
end

-- ====================================================================
-- <C-l>: add a missing closing bracket (insert mode)
-- ====================================================================
vim.keymap.set("i", "<C-l>", function()
    local close = pair_before_cursor()
    if not close then
        return ""
    end
    -- already balanced (closer already follows the cursor): just step
    -- over it instead of inserting a duplicate
    if char_after_cursor() == close then
        return "<Right>"
    end
    return close .. "<Left>"
end, { expr = true, replace_keycodes = true, desc = "Add missing closing bracket" })

-- ====================================================================
-- <C-y>: accept completion (insert mode)
-- ====================================================================
-- normally <C-y> just confirms the selected completion item, but this
-- makes it smarter about what to do depending on the completion menu's state
vim.keymap.set("i", "<C-y>",
    ---@return string
    function()
        -- no completion menu is showing, so just do the normal thing
        if vim.fn.pumvisible() == 0 then
            return "<C-y>"
        end

        local info = vim.fn.complete_info({ "selected", "items" })

        -- the menu is showing but has no items, so cancel it
        if not info.items or #info.items == 0 then
            return "<C-e>"
        end

        -- menu is showing but nothing is selected yet: select the
        -- first item, then confirm it
        if info.selected == -1 then
            return "<C-n><C-y>"
        end

        -- an item is already selected, so just confirm it
        return "<C-y>"
    end,
    {
        expr = true, -- the function's return value is treated as keys to press
        replace_keycodes = true,
        desc = "Accept completion",
    }
)

-- ====================================================================
-- Indent while remaining in visual mode
-- ====================================================================
-- "x" rather than "v": "v" also covers Select mode, where snippet
-- placeholders live and typed < > must replace the text, not indent
vim.keymap.set("x", "<", "<gv", { desc = "Indent left, keep selection" })
vim.keymap.set("x", ">", ">gv", { desc = "Indent right, keep selection" })
