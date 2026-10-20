vim.filetype.add({ extension = { bru = "bruno" } })

vim.api.nvim_create_user_command("BrunoRun", function(o)
    require("bruno").run({ env = o.args ~= "" and o.args or nil })
end, {
    nargs = "?",
    desc = "Run the current .bru file",
    complete = function()
        local root = vim.fs.root(0, "bruno.json")
        return root and require("bruno.env").list(root) or {}
    end,
})
vim.api.nvim_create_user_command("BrunoCancel", function() require("bruno").cancel() end, { desc = "Cancel the running request" })
vim.api.nvim_create_user_command("BrunoSecrets", function(o)
    require("bruno").secrets(o.args ~= "" and o.args or "edit")
end, {
    nargs = "?",
    complete = function() return { "edit", "clear" } end,
    desc = "Edit this env's secrets file (op:// refs), or clear cached secrets",
})
vim.api.nvim_create_user_command("BrunoEnv", function() require("bruno").pick_env() end, { desc = "Pick Bruno environment" })
vim.api.nvim_create_user_command("BrunoFind", function() require("bruno").find() end, { desc = "Find Bruno request" })
vim.api.nvim_create_user_command("BrunoCurl", function() require("bruno").copy_curl() end, { desc = "Copy the request as curl (last run if current, else basic static curl)" })
vim.api.nvim_create_user_command("BrunoToggle", function() require("bruno").toggle() end, { desc = "Toggle response window" })
vim.api.nvim_create_user_command("BrunoYank", function(o)
    require("bruno").yank(o.args ~= "" and o.args or "body")
end, { nargs = "?", complete = function() return { "body", "headers" } end, desc = "Yank response body/headers" })
vim.api.nvim_create_user_command("BrunoView", function(o) require("bruno").view(o.args) end, {
    nargs = 1, complete = function() return { "body", "info", "headers", "tests", "request" } end, desc = "Switch response view",
})

vim.keymap.set("n", "<leader>fu", "<CMD>BrunoFind<CR>", { desc = "[F]uzzy Find [U]RL (Bruno request)" })
