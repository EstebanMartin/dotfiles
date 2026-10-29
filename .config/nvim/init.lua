-- read by the startup time notification in lua/autocmd.lua
vim.g.config_start = vim.uv.hrtime()

-- ====================================================================
-- Experimental UI2: floating cmdline and messages
-- ====================================================================
-- Nvim 0.13 moved msg timeout and cmd height into 'messagesopt' and errors on
-- the old keys; 0.12 rejects the new items, so pass the old keys there instead
local old_ui2 = not pcall(function() vim.opt.messagesopt:append("timeout:2000,maxheight:50") end)
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
            timeout = old_ui2 and 2000 or nil,
            height  = 0.1,
        },
        pager = {
            height = 0.5,
        },
        cmd = {
            height = old_ui2 and 0.5 or nil,
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
