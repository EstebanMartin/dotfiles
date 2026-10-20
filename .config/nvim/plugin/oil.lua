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

---@return boolean
local function is_dir_being_opened()
    if vim.fn.argc() == 0 then
        return false
    end
    local arg = vim.fn.argv(0) --[[@as string]]
    return vim.fn.isdirectory(arg) == 1
end

if is_dir_being_opened() then
    setup()
else
    vim.schedule(setup)
end

-- =================================================================
-- -: Open parent directory
-- =================================================================
local open =  function() require("oil").open() end
vim.keymap.set("n", "-", open, { desc = "Open parent directory" })
