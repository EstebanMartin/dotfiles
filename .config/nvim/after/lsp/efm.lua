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
                    lintCommand = 'golangci-lint run --output.text.path=stdout --show-stats=false ${INPUT}',
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
