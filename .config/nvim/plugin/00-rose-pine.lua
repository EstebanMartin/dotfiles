vim.pack.add({
    { src = "https://github.com/rose-pine/neovim", name = "rose-pine" },
})
require("rose-pine").setup({
  variant = "auto", -- follows vim.o.background: dark_variant when dark, "dawn" when light
  dark_variant = "main",
  dim_inactive_windows = false,
  extend_background_behind_borders = false,
  styles = {
    italic = true,
    transparency = vim.fn.has("mac") + vim.fn.has("win32") + vim.fn.has("wsl") > 0,
  },
  highlight_groups = {
    Keyword = { italic = true },
    Conditional = { italic = true },
    Function = { italic = true },
    Type = { italic = true },
    -- Treesitter groups set their own colors, so they don't inherit the above
    ["@keyword.conditional"] = { italic = true },
    ["@keyword.repeat"] = { italic = true },
    ["@keyword.return"] = { italic = true },
    ["@keyword.import"] = { italic = true },
    ["@keyword.exception"] = { italic = true },
    ["@function"] = { italic = true },
    ["@function.method"] = { italic = true },
    ["@function.method.call"] = { italic = true },
    ["@type"] = { italic = true },
  },
})
vim.cmd("colorscheme rose-pine")
