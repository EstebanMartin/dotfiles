---@type vim.lsp.Config
return {
    init_options = {
        documentFormatting = true,
    },
    filetypes = { 'go', 'json' },
    ---@type lspconfig.settings.efm
    settings = {
        rootMarkers = { '.git/', 'go.mod' },
        languages = {
            go = {
                {
                    -- lint the whole package dir, not just ${INPUT}: given a single
                    -- file, golangci-lint typechecks it alone and reports symbols
                    -- from sibling files as "undefined" (typecheck). efm keeps
                    -- only the diagnostics for the current buffer's file.
                    lintCommand = 'golangci-lint run --output.text.path=stdout --show-stats=false --path-mode=abs "$(dirname ${INPUT})"',
                },
            },
            json = {
                {
                    formatCommand = 'fixjson',
                    formatStdin = true,
                },
            },
        },
    },
}
