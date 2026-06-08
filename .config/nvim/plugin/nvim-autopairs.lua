vim.api.nvim_create_autocmd({ "InsertEnter" }, {
    callback = function()
        vim.pack.add({
            { src = "https://github.com/windwp/nvim-autopairs" },
        })
        require("nvim-autopairs").setup({})
    end,
})
