local map = function(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = true, desc = desc })
end
map("<localleader>r", "<CMD>BrunoRun<CR>", "Bruno: [R]un request")
map("<localleader>x", "<CMD>BrunoCancel<CR>", "Bruno: cancel running request")
map("<localleader>e", "<CMD>BrunoEnv<CR>", "Bruno: pick [E]nvironment")
map("<localleader>c", "<CMD>BrunoCurl<CR>", "Bruno: copy [C]url")

-- show the selected environment on the request's own window
-- (the window id is passed in: g:statusline_winid isn't reliable for winbars)
vim.opt_local.winbar = ("%%{%%v:lua.require('bruno').winbar(%d)%%}"):format(vim.api.nvim_get_current_win())
