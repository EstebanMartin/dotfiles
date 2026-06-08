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
            vim.loop.fs_write(
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

-- ====================================================================
-- Experimental UI2: floating cmdline and messages
-- ====================================================================
require("vim._core.ui2").enable({
    msg = {
        targets = {
            -- msg: ephemeral popup: short, transient, no action needed
            bufwrite     = "msg", -- "file written" etc.
            undo         = "msg", -- undo/redo notifications
            search_cmd   = "msg", -- /pattern entered
            search_count = "msg", -- [1/10] match count
            completion   = "msg", -- ins-completion info
            progress     = "msg", -- nvim_echo progress
            quickfix     = "msg", -- :cn/:cp navigation
            echo         = "msg", -- :echo output
            echomsg      = "msg", -- :echomsg output
            lua_print    = "msg", -- print() from lua
            wmsg         = "msg", -- warnings (W10, hit-bottom, etc.)

            -- pager: long/scrollable output you want to read
            list_cmd     = "pager", -- :ls, :set, :map, etc.
            shell_out    = "pager", -- :! stdout
            shell_err    = "pager", -- :! stderr
            shell_cmd    = "pager", -- :! command echo
            shell_ret    = "pager", -- :! return code
            verbose      = "pager", -- 'verbose' output
            emsg         = "pager", -- error messages (E###)
            echoerr      = "pager", -- :echoerr output
            lua_error    = "pager", -- lua runtime errors
            rpc_error    = "pager", -- RPC/client errors

            -- cmd: errors/confirms need attention
            confirm      = "cmd",
        },
        msg = {
            timeout = 3000,
            height  = 0.3,
        },
        pager = {
            height = 0.5,
        },
        cmd = {
            height = 0.5,
        },
    },
})

-- ====================================================================
-- Load files at /lua
-- ====================================================================
local directory = vim.fn.stdpath("config") .. "/lua"
vim.iter(vim.fn.readdir(directory))
    :filter(function(f) return f:sub(-4) == ".lua" end)
    :each(function(f)
        local module = f:sub(1, -5) -- strips .lua
        local ok, err = pcall(require, module)
        if ok then return end
        vim.notify(
            "Error loading " .. module .. ": " .. err,
            vim.log.levels.ERROR
        )
    end)
