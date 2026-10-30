-- =================================================================
-- get_oil_winbar: show current directory in winbar
-- =================================================================
---@return string
function _G.get_oil_winbar()
    local bufnr = vim.api.nvim_win_get_buf(vim.g.statusline_winid)
    local dir = require("oil").get_current_dir(bufnr)
    if dir then
        return vim.fn.fnamemodify(dir, ":~")
    end
    -- no directory available (e.g. over ssh), use buffer name
    return vim.api.nvim_buf_get_name(bufnr)
end

-- =================================================================
-- Setup
-- =================================================================
local function setup()
    vim.pack.add({
        { src = 'https://github.com/stevearc/oil.nvim' },
    })
    ---@module 'oil'
    ---@type oil.SetupOpts
    require("oil").setup({
        lsp_file_methods = {
            autosave_changes = false,
        },
        win_options = {
            winbar = "%!v:lua.get_oil_winbar()",
        },
        watch_for_changes = true,
    })
end

-- opening a directory (nvim some/dir) must set oil up before the netrw-style
-- BufEnter, so only defer otherwise (argv(0) is "" with no arguments)
if vim.fn.isdirectory(vim.fn.argv(0)) == 1 then
    setup()
else
    vim.schedule(setup)
end

-- =================================================================
-- -: Open parent directory
-- =================================================================
vim.keymap.set("n", "-", function() require("oil").open() end, { desc = "Open parent directory" })
