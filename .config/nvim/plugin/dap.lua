vim.schedule(function()
    vim.pack.add({
        { src = "https://github.com/mfussenegger/nvim-dap" },
        { src = "https://github.com/leoluz/nvim-dap-go" },
        { src = "https://github.com/igorlfs/nvim-dap-view" },
        { src = "https://github.com/theHamsta/nvim-dap-virtual-text" },
    })

    require("dap-go").setup()
    require("dap-view").setup({ auto_toggle = true })
    require("nvim-dap-virtual-text").setup({
        display_callback = function(variable)
            local name = string.lower(variable.name)
            local value = string.lower(variable.value)
            if name:match("secret") or name:match("api")
                or value:match("secret") or value:match("api") then
                return " ***** "
            end
            if #variable.value > 15 then
                return " " .. string.sub(variable.value, 1, 15) .. "... "
            end
            return " " .. variable.value
        end,
    })

    local dap = require("dap")
    dap.listeners.before.attach.dapview_config = function()
        require("dap-view").open()
    end
    dap.listeners.before.launch.dapview_config = function()
        require("dap-view").open()
    end
    dap.listeners.before.event_terminated.dapview_config = function()
        require("dap-view").close()
    end
    dap.listeners.before.event_exited.dapview_config = function()
        require("dap-view").close()
    end
end)

-->> <leader>dc: Debug continue
vim.keymap.set("n", "<leader>dc",
    function() require("dap").continue() end,
    { desc = "[D]ebug [C]ontinue" }
)

-->> <leader>db: Debug breakpoint toggle
vim.keymap.set("n", "<leader>db",
    function() require("dap").toggle_breakpoint() end,
    { desc = "[D]ebug [B]reakpoint toggle" }
)

-->> <leader>di: Debug step into
vim.keymap.set("n", "<leader>di",
    function() require("dap").step_into() end,
    { desc = "[D]ebug Step [I]nto" }
)

-->> <leader>du: Debug step out
vim.keymap.set("n", "<leader>du",
    function() require("dap").step_out() end,
    { desc = "[D]ebug Step O[U]t" }
)

-->> <leader>dn: Debug step next (over)
vim.keymap.set("n", "<leader>dn",
    function() require("dap").step_over() end,
    { desc = "[D]ebug Step [N]ext" }
)

-->> <leader>dt: Debug terminate
vim.keymap.set("n", "<leader>dt",
    function() require("dap").terminate() end,
    { desc = "[D]ebug [T]erminate" }
)
