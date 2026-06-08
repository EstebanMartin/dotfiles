-- ====================================================================
-- get_oil_winbar: show current directory in winbar
-- ====================================================================
function _G.get_oil_winbar()
    local bufnr = vim.api.nvim_win_get_buf(vim.g.statusline_winid)
    local dir = require("oil").get_current_dir(bufnr)
    if dir then
        return vim.fn.fnamemodify(dir, ":~")
    end
    -- no directory available (e.g. over ssh), use buffer name
    return vim.api.nvim_buf_get_name(bufnr)
end

-- ====================================================================
-- Setup
-- ====================================================================
local function setup()
    vim.pack.add({
        { src = 'https://github.com/stevearc/oil.nvim' },
    })
    ---@module 'oil'
    ---@type oil.SetupOpts
    require("oil").setup({
        watch_for_changes = true,
        use_default_keymaps = false,
        win_options = {
            winbar = "%!v:lua.get_oil_winbar()",
        },
        keymaps = {
            ["<CR>"]  = "actions.select",
            ["<C-s>"] = {
                "actions.select",
                opts = { horizontal = true },
                desc = "Open in horizontal split",
            },
            ["<C-v>"] = {
                "actions.select",
                opts = { vertical = true },
                desc = "Open in vertical split",
            },
            ["-"]     = { "actions.parent", mode = "n" },
            ["<BS>"]  = { "actions.parent", mode = "n" },
            ["="]     = { "actions.open_cwd", mode = "n" },
            ["~"]     = "<cmd>edit $HOME<CR>",
            ["gq"]    = "actions.close",
            ["gc"]    = { "actions.cd", mode = "n" },
            ["g?"]    = { "actions.show_help", mode = "n" },
            ["g."]    = { "actions.toggle_hidden", mode = "n" },
        },
    })
end

-- load immediately if nvim was opened on a directory, otherwise defer
if vim.fn.argc() > 0
    and vim.fn.isdirectory(vim.fn.argv(0) --[[@as string]]) == 1
then
    setup()
else
    vim.schedule(setup)
end

-- ====================================================================
-- -: Open parent directory
-- ====================================================================
vim.keymap.set("n", "-", function()
    require("oil").open()
end, { desc = "Open parent directory" })
