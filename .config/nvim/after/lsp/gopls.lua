---@type vim.lsp.Config
return {
    ---@type lspconfig.settings.gopls
    settings = {
        gopls = {
            -- extra static analysis passes gopls has but doesn't enable by default
            analyses = {
                unusedparams = true,
                unusedwrite = true,
                shadow = true,
                nilness = true,
                useany = true,
                unusedvariable = true,
            },
            staticcheck = true,     -- pulls in staticcheck's analyzers, off by default
            gofumpt = true,         -- stricter formatting than gofmt
            usePlaceholders = true, -- param placeholders on completion
            completeUnimported = true,
            -- inlay hints (all off by default)
            hints = {
                assignVariableTypes = true,
                compositeLiteralFields = true,
                compositeLiteralTypes = true,
                constantValues = true,
                functionTypeParameters = true,
                parameterNames = true,
                rangeVariableTypes = true,
            },
            codelenses = {
                gc_details = true, -- toggle compiler optimization details
                generate = true,
                test = true,
                tidy = true,
                upgrade_dependency = true,
                vendor = true,
            },
        },
    },
}
