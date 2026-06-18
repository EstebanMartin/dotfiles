vim.schedule(function()
    vim.pack.add({ 'https://github.com/nvim-mini/mini.completion' })

    local process_items_opts = { kind_priority = { Text = -1, Snippet = 99 } }
    require('mini.completion').setup({
        lsp_completion = {
            -- Without this config autocompletion is set up through `:h 'completefunc'`.
            -- Although not needed, setting up through `:h 'omnifunc'` is cleaner
            -- (sets up only when needed) and makes it possible to use `<C-u>`.
            source_func = 'omnifunc',
            auto_setup = false,
            process_items = function(items, base)
                return MiniCompletion.default_process_items(items, base, process_items_opts)
            end,
        },
    })

    -- Set 'omnifunc' for LSP completion only when needed.
    vim.api.nvim_create_autocmd('LspAttach', {
        callback = function(ev)
            vim.bo[ev.buf].omnifunc = 'v:lua.MiniCompletion.completefunc_lsp'
        end,
        desc = "Set 'omnifunc'",
    })

    -- Advertise to servers that Neovim now supports certain set of completion and
    -- signature features through 'mini.completion'.
    vim.lsp.config('*', { capabilities = MiniCompletion.get_lsp_capabilities() })
end)
