-- read by the startup time notification in lua/autocmd.lua
vim.g.config_start = vim.uv.hrtime()

-- ====================================================================
-- Open file:line:col from CLI arg (replaces fileline.nvim)
-- ====================================================================
if vim.fn.argc() == 1 then
    local arg = vim.fn.argv(0) --[[@as string]]
    local file, line, col = arg:match("^(.+):(%d+):?(%d*)$")
    if file and vim.uv.fs_stat(file) then
        vim.schedule(function()
            vim.cmd.edit(vim.fn.fnameescape(file))
            vim.api.nvim_win_set_cursor(0, {
                tonumber(line),
                col ~= "" and (tonumber(col) - 1) or 0,
            })
        end)
    end
end

-- ====================================================================
-- Bruno requests: no built-in rule, and ftplugin/ runs only after detection
-- ====================================================================
vim.filetype.add({ extension = { bru = "bru" } })

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
            emsg         = "msg", -- error messages (E###)
            echoerr      = "msg", -- :echoerr output

            -- pager: long/scrollable output you want to read
            list_cmd     = "pager", -- :ls, :set, :map, etc.
            shell_out    = "pager", -- :! stdout
            shell_err    = "pager", -- :! stderr
            shell_cmd    = "pager", -- :! command echo
            shell_ret    = "msg",   -- :! return code
            verbose      = "pager", -- 'verbose' output
            lua_error    = "pager", -- lua runtime errors
            rpc_error    = "pager", -- RPC/client errors

            -- cmd: errors/confirms need attention
            confirm      = "cmd",
        },
        msg = {
            timeout = 2000,
            height  = 0.1,
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
for _, f in ipairs(vim.fn.readdir(directory)) do
    if f:sub(-4) == ".lua" then
        local module = f:sub(1, -5) -- strips .lua
        local ok, err = pcall(require, module)
        if not ok then
            vim.notify(
                "Error loading " .. module .. ": " .. err,
                vim.log.levels.ERROR
            )
        end
    end
end
