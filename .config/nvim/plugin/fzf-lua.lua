vim.schedule(function()
    vim.pack.add({
        { src = "https://github.com/ibhagwan/fzf-lua" },
    })

    ---@module "fzf-lua"
    ---@type fzf-lua.Config|{}
    ---@diagnostic disable: missing-fields
    require("fzf-lua").setup({})
    require("fzf-lua").register_ui_select()
end)

-- =================================================================
-- gO: Fuzzy find document symbols
-- =================================================================
vim.keymap.set("n", "gO",
    function() FzfLua.lsp_document_symbols() end,
    { desc = "[F]uzzy [S]ymbols" }
)

-- =================================================================
-- grr: Fuzzy find references
-- =================================================================
vim.keymap.set("n", "grr",
    function() FzfLua.lsp_references() end,
    { desc = "[F]uzzy [R]eferences" }
)

-- =================================================================
-- <C-x><C-f>: Fuzzy complete path
-- =================================================================
vim.keymap.set({ "n", "x", "i" }, "<C-x><C-f>",
    function()
        FzfLua.complete_path({ cmd = "find ." })
    end,
    { silent = true, desc = "Fuzzy complete path" }
)

-- =================================================================
-- <leader>fd: Fuzzy find dap commands
-- =================================================================
vim.keymap.set("n", "<leader>fd",
    function() FzfLua.dap_commands() end,
    { desc = "[F]uzzy [D]ap Commands" }
)

-- =================================================================
-- <leader>ff: Fuzzy find files
-- =================================================================
vim.keymap.set("n", "<leader>ff",
    function() FzfLua.files() end,
    { desc = "[F]uzzy [F]iles" }
)

-- =================================================================
-- <leader>fg: Fuzzy find text (grep)
-- =================================================================
vim.keymap.set("n", "<leader>fg",
    function() FzfLua.live_grep_native() end,
    { desc = "[F]uzzy [G]rep" }
)

-- =================================================================
-- <leader>fr: Resume last fuzzy search
-- =================================================================
vim.keymap.set("n", "<leader>fr",
    function() FzfLua.resume() end,
    { desc = "[F]uzzy [R]esume" }
)

-- =================================================================
-- <leader>ft: Fuzzy find filetypes
-- =================================================================
vim.keymap.set("n", "<leader>ft",
    function() FzfLua.filetypes() end,
    { desc = "[F]uzzy file[T]ypes" }
)
