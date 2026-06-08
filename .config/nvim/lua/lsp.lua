-- ======================================================================
-- Show lsp loading progress
-- ======================================================================
vim.api.nvim_create_autocmd('LspProgress', {
    callback = function()
        local msg = vim.lsp.status()
        if msg == '' then return end
        vim.api.nvim_echo({ { msg, 'Comment' } }, false, {})
    end,
})


-- ======================================================================
-- Enable LSP features when a language server attaches to a buffer
-- ======================================================================
vim.api.nvim_create_autocmd('LspAttach', {
    group = vim.api.nvim_create_augroup("my.lsp", {}),
    callback = function(ev)
        local client = assert(vim.lsp.get_client_by_id(ev.data.client_id))

        -- Autocomplete
        -- local chars = vim.split(
        --     "abcdefghijklmnopqrstuvwxyz" ..
        --     "ABCDEFGHIJKLMNOPQRSTUVWXYZ" ..
        --     "0123456789" ..
        --     ".:_>(/@#\"'`!<$-",
        --     ""
        -- )
        -- if client:supports_method('textDocument/completion') then
        --     client.server_capabilities.completionProvider.triggerCharacters = chars
        --     vim.lsp.completion.enable(true, client.id, ev.buf, { autotrigger = true })
        -- end

        -- Folding
        if client:supports_method("textDocument/foldingRange") then
            local win = vim.api.nvim_get_current_win()
            vim.wo[win][0].foldmethod = "expr"
            vim.wo[win][0].foldexpr = "v:lua.vim.lsp.foldexpr()"
            vim.wo[win][0].foldlevel = 99
        end

        -- Inlay hints
        if client:supports_method('textDocument/inlayHint') then
            vim.lsp.inlay_hint.enable(true, { bufnr = ev.buf })
        end

        -- CodeLens
        if client:supports_method('textDocument/codeLens') then
            vim.lsp.codelens.enable(true, { bufnr = ev.buf })
        end

        -- Linked editing (e.g. HTML tags)
        if client:supports_method("textDocument/linkedEditingRange") then
            vim.lsp.linked_editing_range.enable(true, { bufnr = ev.buf })
        end

        -- On-type formatting (format as you type)
        if client:supports_method("textDocument/onTypeFormatting") then
            vim.lsp.on_type_formatting.enable(true, { client_id = client.id })
        end

        -- Format on save
        if not client:supports_method('textDocument/willSaveWaitUntil')
            and client:supports_method('textDocument/formatting') then
            vim.api.nvim_create_autocmd('BufWritePre', {
                group = vim.api.nvim_create_augroup('my.lsp', { clear = false }),
                buffer = ev.buf,
                callback = function()
                    vim.lsp.buf.format({ bufnr = ev.buf, id = client.id, timeout_ms = 1000 })
                end,
            })
        end
    end,
})
