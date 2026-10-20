-- =================================================================
-- Show LSP loading progress
-- =================================================================
-- as native progress messages, like go test and bru: one line per server
-- task, updated in place; animates the statusline and drives the terminal's
-- progress bar
local titles = {} -- task title from its 'begin'; 'report'/'end' may omit it

vim.api.nvim_create_autocmd('LspProgress', {
    callback = function(ev)
        local value = ev.data.params.value
        if type(value) ~= 'table' or not value.kind then return end -- not work-done progress

        local id = ('lsp.%d.%s'):format(ev.data.client_id, ev.data.params.token)
        titles[id] = value.title or titles[id]

        -- e.g. "Loading workspace 71/213"; Neovim prefixes the percentage
        -- (from `percent` below) itself, so it isn't repeated in the text
        local text = titles[id] or ''
        if value.message then text = text .. ' ' .. value.message end
        if value.kind == 'end' then titles[id] = nil end

        local client = vim.lsp.get_client_by_id(ev.data.client_id)
        vim.api.nvim_echo({ { vim.trim(text), 'Comment' } }, false, {
            id = id,
            kind = 'progress',
            source = 'vim.lsp',
            title = client and client.name or 'lsp',
            status = value.kind == 'end' and 'success' or 'running',
            percent = value.percentage,
        })
    end,
})

-- =================================================================
-- Enable global LSP features (not tied to a specific attach)
-- =================================================================
vim.schedule(function()
    vim.lsp.inlay_hint.enable(true)
    vim.lsp.codelens.enable(true)
    vim.lsp.linked_editing_range.enable(true)
end)

-- =================================================================
-- Enable LSP features on a per-buffer basis (LspAttach)
-- =================================================================
vim.api.nvim_create_autocmd('LspAttach', {
    group = vim.api.nvim_create_augroup("enable_lsp_features", {}),
    callback = function(ev)
        local client = assert(vim.lsp.get_client_by_id(ev.data.client_id))

        -- Autocomplete (must stay per-client/buffer)
        local chars = vim.split(
            "abcdefghijklmnopqrstuvwxyz" ..
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ" ..
            "0123456789" ..
            ".:_>/@#!<$-",
            ""
        )
        if client:supports_method('textDocument/completion') then
            client.server_capabilities.completionProvider.triggerCharacters = chars
            vim.lsp.completion.enable(true, client.id, ev.buf, { autotrigger = true })
        end

        -- Folding (window-local option, must stay per-attach). Applied to
        -- every window showing the buffer, not the current one: attach is
        -- async, so focus may have moved on. BufWinEnter covers windows
        -- opened on the buffer later.
        if client:supports_method("textDocument/foldingRange") then
            local function set_lsp_folds(win)
                vim.wo[win][0].foldmethod = "expr"
                vim.wo[win][0].foldexpr = "v:lua.vim.lsp.foldexpr()"
                vim.wo[win][0].foldlevel = 99
            end
            for _, win in ipairs(vim.fn.win_findbuf(ev.buf)) do
                set_lsp_folds(win)
            end
            local group = vim.api.nvim_create_augroup('lsp_folds', { clear = false })
            vim.api.nvim_clear_autocmds({ group = group, buffer = ev.buf })
            vim.api.nvim_create_autocmd('BufWinEnter', {
                group = group,
                buffer = ev.buf,
                desc = 'LSP folds in new windows on this buffer',
                callback = function()
                    set_lsp_folds(vim.api.nvim_get_current_win())
                end,
            })
        end

        if client:supports_method("textDocument/documentColor") then
            vim.lsp.document_color.enable(true, { bufnr = ev.buf })
        end

        if not client:supports_method('textDocument/willSaveWaitUntil')
            and client:supports_method('textDocument/formatting') then
            -- a re-attach (e.g. :lsp restart) brings a new client id; drop the
            -- previous attach's autocmd for this server instead of stacking
            local group = vim.api.nvim_create_augroup('format_on_save', { clear = false })
            local desc = 'Format on save: ' .. client.name
            for _, au in ipairs(vim.api.nvim_get_autocmds({ group = group, buffer = ev.buf })) do
                if au.desc == desc then
                    vim.api.nvim_del_autocmd(au.id)
                end
            end
            vim.api.nvim_create_autocmd('BufWritePre', {
                group = group,
                buffer = ev.buf,
                desc = desc,
                callback = function()
                    vim.lsp.buf.format({ bufnr = ev.buf, id = client.id, timeout_ms = 1000 })
                end,
            })
        end

        -- Force a hint refresh shortly after attach.
        -- Neovim bug: hints aren't drawn on text already on screen when enabled
        -- directly on LspAttach; only newly-revealed text gets them (e.g. scrolling).
        -- Toggling off/on after a short delay forces a redraw that fixes this.
        -- https://github.com/neovim/neovim/issues/26511
        if client:supports_method("textDocument/inlayHint") then
            vim.defer_fn(function()
                vim.lsp.inlay_hint.enable(false, { bufnr = ev.buf })
                vim.lsp.inlay_hint.enable(true, { bufnr = ev.buf })
            end, 100)
        end
    end,
})
