-- ====================================================================
-- Leaders
-- ====================================================================
vim.g.mapleader = " "      -- global leader key
vim.g.maplocalleader = ";" -- filetype-specific leader

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
