-- Workspace setup (LuaJIT runtime, Neovim's runtime as the library) lives in
-- the project's .luarc.json, which lua_ls reads on its own; this config's is
-- at the root of ~/.config/nvim.
---@type vim.lsp.Config
return {
    ---@type lspconfig.settings.lua_ls
    settings = {
        Lua = {
            codeLens = {
                enable = true,
            },
            hint = {
                enable = true,
                setType = true,
                paramName = "All",
                paramType = true,
                semicolon = "All",
                arrayIndex = "All",
                await = true,
            },
        },
    },
}
