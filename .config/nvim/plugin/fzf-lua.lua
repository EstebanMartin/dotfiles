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


-->> <C-x><C-f>: Fuzzy complete path
vim.keymap.set({ "n", "v", "i" }, "<C-x><C-f>",
    function() FzfLua.complete_path({ cmd = "find ." }) end,
    { silent = true, desc = "Fuzzy complete path" }
)

-->> <leader>fd: Fuzzy find dap commands
vim.keymap.set("n", "<leader>fd",
    function() FzfLua.dap_commands() end,
    { desc = "[F]uzzy [D]ap Commands" }
)

-->> <leader>ff: Fuzzy find files
vim.keymap.set("n", "<leader>ff",
    function() FzfLua.files() end,
    { desc = "[F]uzzy [F]iles" }
)

-->> <leader>fg: Fuzzy find text (grep)
vim.keymap.set("n", "<leader>fg",
    function() FzfLua.live_grep_native() end,
    { desc = "[F]uzzy [G]rep" }
)

-->> <leader>fl: Fuzzy find lines
vim.keymap.set("n", "<leader>fl",
    function() FzfLua.lines() end,
    { desc = "[F]uzzy [L]ines" }
)

-->> <leader>fr: Resume last fuzzy search
vim.keymap.set("n", "<leader>fr",
    function() require("fzf-lua").resume() end,
    { desc = "[F]uzzy [R]esume" }
)

-->> <leader>fs: Fuzzy find document symbols
vim.keymap.set("n", "<leader>fs",
    function() require("fzf-lua").lsp_document_symbols() end,
    { desc = "[F]uzzy [S]ymbols" }
)

-->> <leader>ft: Fuzzy find filetypes
vim.keymap.set("n", "<leader>ft",
    function() require("fzf-lua").filetypes() end,
    { desc = "[F]uzzy file[T]ypes" }
)
