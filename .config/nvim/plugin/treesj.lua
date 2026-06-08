vim.schedule(function()
    vim.pack.add({
        { src = "https://github.com/Wansmer/treesj" },
    })
    require("treesj").setup({})
end)

-->> sj: Split or join blocks of code
vim.keymap.set("n", "sj",
    function() require("treesj").toggle({ recursive = false }) end,
    { desc = "[s]plit or [j]oin blocks of code" }
)

-->> sJ: Split or join blocks of code recursively
vim.keymap.set("n", "sJ",
    function() require("treesj").toggle({ recursive = true }) end,
    { desc = "[s]plit or [J]oin blocks of code recursively" }
)
