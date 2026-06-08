vim.schedule(function()
    vim.pack.add({
        { src = "https://github.com/arborist-ts/arborist.nvim" },
    })
    require("arborist").setup()
end)
