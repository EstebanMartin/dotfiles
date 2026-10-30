-- Bruno OpenCollection (YAML) collections. Request files stay `yaml` (yamlls, the yaml
-- ftplugin) and get the request maps and winbar only inside an opencollection.yml root.

vim.api.nvim_create_user_command("OcRun", function(o)
    require("opencollection").run({ env = o.args ~= "" and o.args or nil })
end, {
    nargs = "?",
    desc = "Run the current OpenCollection request",
    complete = function()
        local root = vim.fs.root(0, "opencollection.yml")
        return root and require("opencollection.env").list(root) or {}
    end,
})
vim.api.nvim_create_user_command("OcCancel", function() require("opencollection").cancel() end, { desc = "Cancel the running request" })
vim.api.nvim_create_user_command("OcSecrets", function(o)
    require("opencollection").secrets(o.args ~= "" and o.args or "edit")
end, {
    nargs = "?",
    complete = function() return { "edit", "clear" } end,
    desc = "Edit this env's secrets file (op:// refs), or clear cached secrets",
})
vim.api.nvim_create_user_command("OcEnv", function() require("opencollection").pick_env() end, { desc = "Pick OpenCollection environment" })
vim.api.nvim_create_user_command("OcFind", function() require("opencollection").find() end, { desc = "Find OpenCollection request" })
vim.api.nvim_create_user_command("OcCurl", function() require("opencollection").copy_curl() end, { desc = "Copy the request as curl (last run if current, else basic static curl)" })
vim.api.nvim_create_user_command("OcToggle", function() require("opencollection").toggle() end, { desc = "Toggle response window" })
vim.api.nvim_create_user_command("OcYank", function(o)
    require("opencollection").yank(o.args ~= "" and o.args or "body")
end, { nargs = "?", complete = function() return { "body", "headers" } end, desc = "Yank response body/headers" })
vim.api.nvim_create_user_command("OcView", function(o) require("opencollection").view(o.args) end, {
    nargs = 1, complete = function() return { "body", "info", "headers", "tests", "request" } end, desc = "Switch response view",
})

vim.keymap.set("n", "<leader>fo", "<CMD>OcFind<CR>", { desc = "[F]uzzy Find [O]penCollection request" })

vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("opencollection", { clear = true }),
    pattern = "yaml",
    callback = function(ev)
        local file = vim.api.nvim_buf_get_name(ev.buf)
        -- vim.fs.root first: cheap, and keeps the module unloaded for every other yaml file
        if not vim.fs.root(file, "opencollection.yml") or not require("opencollection").is_request(file) then return end

        local map = function(lhs, rhs, desc)
            vim.keymap.set("n", lhs, rhs, { buffer = ev.buf, desc = desc })
        end
        map("<localleader>r", "<CMD>OcRun<CR>", "OpenCollection: [R]un request")
        map("<localleader>x", "<CMD>OcCancel<CR>", "OpenCollection: cancel running request")
        map("<localleader>e", "<CMD>OcEnv<CR>", "OpenCollection: pick [E]nvironment")
        map("<localleader>c", "<CMD>OcCurl<CR>", "OpenCollection: copy [C]url")

        -- one group per buffer, so re-running FileType (:e) replaces the autocmd
        vim.api.nvim_create_autocmd("BufWritePre", {
            group = vim.api.nvim_create_augroup("opencollection_sync_" .. ev.buf, { clear = true }),
            buffer = ev.buf,
            desc = "OpenCollection: update the url query from the query params",
            callback = function() require("opencollection.sync").on_save(ev.buf) end,
        })

        -- show the selected environment on the request's own window
        -- (the window id is passed in: g:statusline_winid isn't reliable for winbars)
        vim.opt_local.winbar = ("%%{%%v:lua.require('opencollection').winbar(%d)%%}"):format(vim.api.nvim_get_current_win())
    end,
})
