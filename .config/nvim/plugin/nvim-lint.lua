vim.schedule(function()
    vim.pack.add({
        { src = "https://github.com/mfussenegger/nvim-lint" },
    })
    local parser = require("lint.parser").from_errorformat(
        "%f:%l:%c: %m", {}
    )
    require("lint").linters.ddgolint = {
        name = "ddgolint",
        cmd = "ddgolint",
        stdin = false,
        args = {},
        stream = "stdout",
        parser = parser,
    }
    require("lint").linters.riteve = {
        name = "riteve",
        cmd = "riteve",
        stdin = false,
        args = {},
        stream = "stdout",
        parser = parser,
    }
    require("lint").linters_by_ft = {
        go = { "ddgolint" },
    }
end)

vim.api.nvim_create_autocmd({ "BufWritePost", "BufWinEnter" }, {
    pattern = "*.go",
    callback = function()
        vim.schedule(function()
            require("lint").try_lint()
        end)
    end,
    desc = "Run Go linters",
})
