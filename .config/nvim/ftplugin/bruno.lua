local map = function(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = true, desc = desc })
end
map("<localleader>r", "<CMD>BrunoRun<CR>", "Bruno: [R]un request")
map("<localleader>x", "<CMD>BrunoCancel<CR>", "Bruno: cancel running request")
map("<localleader>e", "<CMD>BrunoEnv<CR>", "Bruno: pick [E]nvironment")
map("<localleader>c", "<CMD>BrunoCurl<CR>", "Bruno: copy [C]url")

-- keep the url and the params blocks in sync on save, as the Bruno app does
-- (one group per buffer, so re-running this ftplugin (:e) replaces the autocmd)
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_create_autocmd("BufWritePre", {
    group = vim.api.nvim_create_augroup("bruno_sync_" .. buf, { clear = true }),
    buffer = buf,
    desc = "Bruno: sync the url query and the params",
    callback = function() require("bruno.sync").on_save(buf) end,
})

-- show the selected environment on the request's own window
-- (the window id is passed in: g:statusline_winid isn't reliable for winbars)
vim.opt_local.winbar = ("%%{%%v:lua.require('bruno').winbar(%d)%%}"):format(vim.api.nvim_get_current_win())
