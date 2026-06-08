vim.schedule(function()
    vim.pack.add({
        { src = 'https://github.com/neovim/nvim-lspconfig' },
    })

    vim.lsp.config("yamlls", {
        settings = {
            yaml = {
                completion = true, -- enable completion
                hover = true,
                validate = true,
                schemaStore = {
                    -- auto-detect schemas from schemastore.org
                    enable = true,
                    url = "https://www.schemastore.org/api/json/catalog.json",
                },
            },
        },
    })

    vim.lsp.enable("fish_lsp")
    vim.lsp.enable('lua_ls')
    vim.lsp.enable("gopls")
    vim.lsp.enable("yamlls")
end)
