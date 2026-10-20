---@type vim.lsp.Config
return {
    ---@type lspconfig.settings.yamlls
    settings = {
        yaml = {
            completion = true,
            hover = true,
            validate = true,
            schemaStore = {
                enable = true,
                url = "https://www.schemastore.org/api/json/catalog.json",
            },
            -- Enable LSP-native formatting (so :Format/gq work via LSP)
            format = {
                enable = true,
                singleQuote = false,
                bracketSpacing = true,
                proseWrap = "preserve",
            },
            -- Enforce alphabetical key ordering (adds a code action to fix order)
            keyOrdering = false,
            -- Strict schema validation: reject unknown properties
            disableAdditionalProperties = false,
            -- Don't suggest optional properties with defaults pre-filled
            disableDefaultProperties = true,
            -- Require picking a parent "skeleton" before suggesting nested props
            suggest = {
                parentSkeletonSelectedFirst = false,
            },
            -- Kubernetes CRD schema auto-detection (useful if you edit k8s manifests)
            kubernetesCRDStore = {
                enable = true,
            },
        },
    },
}
