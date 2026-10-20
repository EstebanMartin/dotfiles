vim.schedule(function()
    vim.pack.add({
        { src = "https://github.com/angrypie/prompt-reference.nvim" },
    })
    require("prompt-reference").setup({})
end)

-->> ga: Add to review
vim.keymap.set("x", "ga",
    function()
        require("prompt-reference").add_selection()
    end,
    { desc = "Add to review" }
)

-->> gR: Jump between source and review
vim.keymap.set("n", "gR",
    function()
        require("prompt-reference").review()
    end,
    { desc = "Jump between source and review" }
)

-->> gC: Copy review
vim.keymap.set("n", "gC",
    function()
        require("prompt-reference").copy_all()
    end,
    { desc = "Copy review" }
)
