---@type vim.lsp.Config
return {
    on_init = function(client)
        if client.workspace_folders then
            local path = client.workspace_folders[1].name
            if
                path ~= vim.fn.stdpath('config')
                and (
                    vim.uv.fs_stat(path .. '/.luarc.json')
                    or vim.uv.fs_stat(path .. '/.luarc.jsonc')
                )
            then
                return
            end
        end
        client.config.settings.Lua = vim.tbl_deep_extend(
            'force',
            client.config.settings.Lua --[[@as table]],
            {
                runtime = {
                    version = 'LuaJIT',
                    path = {
                        'lua/?.lua',
                        'lua/?/init.lua',
                    },
                },
                workspace = {
                    checkThirdParty = false,
                    library = vim.api.nvim_get_runtime_file('', true),
                },
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
            }
        )
        client:notify(
            'workspace/didChangeConfiguration',
            { settings = client.config.settings }
        )
    end,
    ---@type lspconfig.settings.lua_ls
    settings = {
        Lua = {},
    },
}
