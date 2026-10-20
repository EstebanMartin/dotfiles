vim.pack.add({
    { src = "https://github.com/rose-pine/neovim", name = "rose-pine" },
})
require("rose-pine").setup({
  dim_inactive_windows = false,
  extend_background_behind_borders = false,
  styles = {
    italic = true,
    transparency = vim.uv.os_uname().sysname == 'Darwin'
      or string.find(vim.uv.os_uname().sysname, 'Windows') ~= nil
      or string.find(vim.uv.os_uname().release, 'WSL') ~= nil,
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
