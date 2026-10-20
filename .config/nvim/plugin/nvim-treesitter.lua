-- nvim-treesitter's main branch neither installs parsers nor starts
-- highlighting on its own: start it on every FileType (a no-op pcall when
-- the language has no parser) and install the parsers listed below.
vim.api.nvim_create_autocmd("FileType", {
    desc = "Start treesitter highlighting",
    callback = function(args)
        pcall(vim.treesitter.start, args.buf)
    end,
})

vim.schedule(function()
    -- registered before pack.add, so it also catches the first install
    vim.api.nvim_create_autocmd("PackChanged", {
        callback = function(args)
            local data = args.data --[[@as vim.event.packchanged.data]]
            if data.spec.name == "nvim-treesitter" and data.kind ~= "delete" then
                if not data.active then vim.cmd.packadd("nvim-treesitter") end
                vim.cmd("TSUpdate")
            end
        end,
    })

    vim.pack.add({
        'https://github.com/nvim-treesitter/nvim-treesitter',
    })

    -- async, and a no-op for parsers already installed (requires tree-sitter CLI)
    require("nvim-treesitter").install({
        "bash", "fish", "go", "gomod", "gosum", "json", "lua",
        "markdown", "markdown_inline", "yaml",
    })
end)
