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

-- =============================================================================
-- Workaround: terminal progress bar for tasks with no known percentage
-- =============================================================================
-- Neovim's default handler (group nvim.progress, registered before this file
-- loads) always sends OSC 9;4 state 1 "normal" with the percentage, which
-- defaults to 0 for tasks that don't report one (go test, bru), so the
-- terminal draws an empty bar. Replace it: state 3 "indeterminate" (a pulsing
-- bar) when there's no percentage, the real percentage otherwise, 0 to remove.
-- Inside tmux, which drops OSC 9;4, the sequence is wrapped in the same DCS
-- passthrough as the OSC 11 workaround above (needs allow-passthrough on).
vim.api.nvim_create_autocmd("Progress", {
    group = vim.api.nvim_create_augroup("nvim.progress", { clear = true }),
    desc = "Terminal progress bar, pulsing when the percentage is unknown",
    callback = function(ev)
        local percent = ev.data.percent or 0
        local state = ev.data.status ~= "running" and "0;0"
            or percent > 0 and ("1;" .. percent)
            or "3;0"
        local osc = "\27]9;4;" .. state .. "\27\\"
        if vim.env.TMUX then
            -- tmux strips one \27 from each doubled pair before forwarding
            osc = "\27Ptmux;" .. osc:gsub("\27", "\27\27") .. "\27\\"
        end
        vim.api.nvim_ui_send(osc)
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

-- ===========================================================================
-- Open file line and column numbers natively
-- ===========================================================================
vim.api.nvim_create_autocmd('BufReadCmd', {
    group = vim.api.nvim_create_augroup('OpenFileLine', { clear = true }),
    pattern = { '*:[0-9]*', '*#L[0-9]*' },
    nested = true,
    callback = function(ev)
        local path, lnum, col = ev.file:match('^(.-):(%d+):(%d+)$')
        if not path then
            path, lnum = ev.file:match('^(.-):(%d+)$')
        end
        if not path then
            path, lnum = ev.file:match('^(.-)#L(%d+)')
        end

        -- Validate path exists on disk
        local stat = path and vim.uv.fs_stat(path)
        if not (stat and stat.type == 'file' and lnum) then
            return
        end

        -- Replace the phantom buffer with the real file
        vim.cmd.edit(vim.fn.fnameescape(path))

        -- Set cursor position (1-based line, 0-based col)
        vim.api.nvim_win_set_cursor(0, {
            tonumber(lnum),
            col and math.max(0, tonumber(col) - 1) or 0,
        })
    end,
})

