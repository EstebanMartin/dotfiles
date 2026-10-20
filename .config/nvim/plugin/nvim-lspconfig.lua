-- pack.add and lsp.enable must run in this order, in the same deferred
-- callback: lsp.enable() re-fires FileType via doautoall for buffers
-- already opened, and that retrigger needs nvim-lspconfig's default
-- configs already on the runtimepath.
vim.schedule(function()
    vim.pack.add({
        { src = 'https://github.com/neovim/nvim-lspconfig' },
    })

    vim.lsp.enable({
        "fish_lsp",
        "lua_ls",
        "gopls",
        "yamlls",
        "efm",
    })
end)

