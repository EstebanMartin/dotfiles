-- ====================================================================
-- Leaders
-- ====================================================================
vim.g.mapleader = " "      -- global leader key
vim.g.maplocalleader = ";" -- filetype-specific leader

-- ====================================================================
-- <BS>: select child node (treesitter or LSP) — visual mode only
-- ====================================================================
local bs = vim.api.nvim_replace_termcodes("<BS>", true, false, true)
vim.keymap.set({ "x" }, "<BS>", function()
    if vim.bo.buftype ~= "" then
        -- non-normal buffer: pass <BS> through as-is
        vim.fn.feedkeys(bs, "in")
    elseif vim.treesitter.get_parser(nil, nil, { error = false }) then
        -- TS parser available: shrink selection to child node
        require("vim.treesitter._select").select_child(vim.v.count1)
    else
        -- fall back to LSP selection range (negative = shrink)
        vim.lsp.buf.selection_range(-vim.v.count1)
    end
end, { desc = "Select child node (TS/LSP) or <BS>" })

-- ====================================================================
-- <CR>: select parent node (treesitter or LSP)
-- ====================================================================
local cr = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
vim.keymap.set({ "n", "x" }, "<CR>", function()
    if vim.bo.buftype ~= "" then
        -- non-normal buffer: pass <CR> through as-is
        vim.fn.feedkeys(cr, "in")
    elseif vim.treesitter.get_parser(nil, nil, { error = false }) then
        -- TS parser available: expand selection to parent node
        require("vim.treesitter._select").select_parent(vim.v.count1)
    else
        -- fall back to LSP selection range
        vim.lsp.buf.selection_range(vim.v.count1)
    end
end, { desc = "Select parent node (TS/LSP) or <CR>" })

-- ====================================================================
-- <C-w>D: diagnostics to quickfix, cursor at nearest
-- ====================================================================
vim.keymap.set("n", "<C-w>D", function()
    local line = vim.fn.line(".")
    vim.diagnostic.setqflist()
    local min, nearest = math.huge, 1
    for i, e in ipairs(vim.fn.getqflist()) do
        local d = math.abs(e.lnum - line)
        if d < min then nearest, min = i, d end
    end
    vim.cmd.copen()
    vim.api.nvim_win_set_cursor(0, { nearest, 0 })
end, { desc = "Diagnostics quickfix at nearest" })

vim.keymap.set("i", "<C-y>",
    ---@return string
    function()
        if vim.fn.pumvisible() == 0 then
            return "<C-y>" -- no popup → fallback
        end

        local info = vim.fn.complete_info({ "selected", "items" })

        if not info.items or #info.items == 0 then
            return "<C-e>" -- popup empty → cancel
        end

        if info.selected == -1 then
            return "<C-n><C-y>" -- select first, then confirm
        end

        return "<C-y>" -- confirm selected
    end,
    {
        expr = true,
        replace_keycodes = true,
        desc = "Accept completion",
    }
)

-- ====================================================================
-- Keeping the cursor centered
-- ====================================================================
vim.keymap.set('n', '<C-d>', '<C-d>zz', { desc = 'Scroll downwards' })
vim.keymap.set('n', '<C-u>', '<C-u>zz', { desc = 'Scroll upwards' })
vim.keymap.set('n', 'n', 'nzzzv', { desc = 'Next result' })
vim.keymap.set('n', 'N', 'Nzzzv', { desc = 'Previous result' })

-- ====================================================================
-- Indent while remaining in visual mode
-- ====================================================================
vim.keymap.set('v', '<', '<gv')
vim.keymap.set('v', '>', '>gv')

-- ====================================================================
-- <Esc>: exit terminal mode
-- ====================================================================
vim.keymap.set("t", "<Esc>", [[<C-\><C-n>]], {
    desc = "Exit terminal mode",
    silent = true,
})
