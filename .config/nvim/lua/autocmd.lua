-- =============================================================================
-- Workaround: OSC 11 background color detection inside tmux
-- =============================================================================
-- Tmux intercepts OSC 11 queries, causing Neovim to miss terminal bg changes.
-- Sending the DCS passthrough sequence on FocusGained forces tmux to re-query
-- and cache the actual background color from the outer terminal, allowing
-- Neovim to detect light/dark mode changes.
-- Ref: https://github.com/neovim/neovim/issues/17070#issuecomment-1086775760
vim.api.nvim_create_autocmd("FocusGained", {
    callback = function()
        if vim.env.TMUX then
            vim.uv.fs_write(
                2,                 -- fd 2 = stderr, points directly to terminal (bypasses nvim buffering)
                "\27Ptmux;"        -- DCS start + tmux passthrough prefix
                .. "\27\27]11;?\7" -- double-escaped OSC 11 query (tmux strips one \27); \7 = BEL terminator
                .. "\27\\",        -- DCS terminator (String Terminator)
                -1,                -- write at current position (no offset)
                function() end     -- no-op callback (required by libuv API)
            )
        end
    end,
})

-- =================================================================
-- Startup Time Notification
-- =================================================================
-- vim.g.config_start is set at the top of init.lua, so this covers the
-- whole config, not just what loads after this file
local _start = vim.g.config_start or vim.uv.hrtime()
vim.api.nvim_create_autocmd("UIEnter", {
    once = true,
    callback = function()
        local ms = (vim.uv.hrtime() - _start) / 1e6
        local msg = ("Config loaded in %.0f ms"):format(ms)
        vim.notify(msg, vim.log.levels.INFO)
    end,
})

-- =================================================================
-- Highlight selection on yank
-- =================================================================
vim.api.nvim_create_autocmd("TextYankPost", {
    group = vim.api.nvim_create_augroup(
        "highlight_yank", { clear = true }
    ),
    pattern = "*",
    desc = "highlight selection on yank",
    callback = function()
        vim.hl.on_yank({ timeout = 300, visual = true })
    end,
})
