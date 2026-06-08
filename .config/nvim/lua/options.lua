-- ====================================================================
-- Clipboard
-- ====================================================================
vim.opt.clipboard = "unnamedplus" -- sync unnamed register with system clipboard

-- ====================================================================
-- Cmdline
-- ====================================================================
vim.opt.cmdheight = 0    -- hide cmdline when not in use
vim.opt.showmode = false -- hide -- INSERT -- from cmdline
vim.opt.shortmess:append({
    c = true,            -- completion: hide "match x of y"
    C = true,            -- completion: hide "scanning..." messages
    s = true,            -- search: hide "search hit BOTTOM/TOP"
    F = true,            -- file: hide file info when opening
})

-- ====================================================================
-- Comments
-- ====================================================================
-- ftplugins often re-enable these flags, reset them on every FileType
vim.api.nvim_create_autocmd("FileType", {
    desc = "Disable automatic comment continuation",
    callback = function()
        vim.opt_local.formatoptions:remove({
            "o", -- don't continue comments on 'o'/'O'
            "r", -- don't continue comments on <CR>
            "c", -- don't auto-wrap comments at 'textwidth'
        })
    end
})

-- ====================================================================
-- Completion
-- ====================================================================

vim.opt.complete = "o,."      -- use buffer and omnifunc
vim.opt.pumborder = "rounded" -- rounded border for completion menu
vim.opt.completeopt = {
    "menuone",                -- show menu even for a single item
    "fuzzy",                  -- enable fuzzy matching and ranking
    "noinsert",               -- don't insert text until a match is selected
    "nosort",
}
vim.o.autocomplete = true
vim.o.autocompletedelay = 250


-- ====================================================================
-- Diagnostics
-- ====================================================================
vim.diagnostic.config({
    severity_sort = true,     -- show higher severity first
    update_in_insert = false, -- don't update diagnostics in insert mode
    jump = { float = true },  -- show float when jumping with ]d / [d
    virtual_text = {
        source = "if_many",   -- show source only with multiple clients
    },
    float = {
        source = "if_many", -- show source only with multiple clients
    },
    signs = {
        text = {
            [vim.diagnostic.severity.ERROR] = "E",
            [vim.diagnostic.severity.WARN]  = "W",
            [vim.diagnostic.severity.INFO]  = "I",
            [vim.diagnostic.severity.HINT]  = "H",
        },
    },
})

-- ====================================================================
-- Files
-- ====================================================================
vim.opt.swapfile = false -- disable swap files
vim.opt.backup = false   -- disable backup files
vim.opt.undofile = true  -- persistent undo history
vim.opt.autoread = true  -- reload files changed outside Neovim
vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold" }, {
    desc = "Check if file changed on disk",
    command = "checktime", -- check if file changed on disk
})

-- ====================================================================
-- Folding
-- ====================================================================
vim.o.foldtext = ""         -- show folded line instead of fold summary
vim.opt.foldlevelstart = 99 -- start with all folds open
vim.opt.foldcolumn = "1"    -- show a single fold column on the left
vim.opt.fillchars:append({
    foldopen  = "v",        -- icon for open folds
    foldclose = ">",        -- icon for closed folds
    foldinner = " ",        -- hide fold level numbers in foldcolumn
    foldsep   = " ",        -- remove separator lines between folds
    eob       = " ",        -- hide ~ at end of buffer
})
vim.opt.foldmethod = "expr" -- expression-based folding

-- use treesitter for fold expressions
vim.opt.foldexpr = "v:lua.vim.treesitter.foldexpr()"

-- ====================================================================
-- Indentation
-- ====================================================================
vim.opt.expandtab = true -- convert tabs to spaces
vim.opt.shiftwidth = 4   -- spaces per indent level
vim.opt.tabstop = 4      -- spaces a <Tab> counts for

-- ====================================================================
-- Modelines
-- ====================================================================
vim.opt.modelines = 0 -- modelines off (security risk)

-- ====================================================================
-- Search
-- ====================================================================
vim.opt.ignorecase = true      -- ignore case in search patterns
vim.opt.smartcase = true       -- case-sensitive if pattern has uppercase
vim.opt.inccommand = "nosplit" -- live :substitute preview in buffer

-- ====================================================================
-- Terminal
-- ====================================================================
vim.opt.scrollback = 50000 -- keep more terminal history available

-- Auto-enter insert mode in terminal buffers
vim.api.nvim_create_autocmd({ "TermOpen", "BufEnter", "WinEnter" }, {
    pattern = "term://*",
    desc = "Auto-enter insert mode when switching to terminal",
    callback = function()
        vim.cmd.startinsert()
    end,
})
-- ====================================================================
-- UI
-- ====================================================================
vim.opt.termguicolors = true  -- enable 24-bit RGB colors in the terminal
vim.opt.updatetime = 250      -- ms before CursorHold triggers
vim.opt.number = true         -- absolute line numbers
vim.opt.relativenumber = true -- relative numbers for easier motion
vim.opt.signcolumn = "yes"    -- always show sign column
vim.opt.scrolloff = 8         -- keep 8 lines above/below cursor
vim.opt.winborder = "rounded" -- rounded border for float windows
vim.opt.splitbelow = true     -- horizontal splits open below
vim.opt.splitright = true     -- vertical splits open to the right
vim.opt.wrap = false          -- don't wrap long lines

-- Equalize window sizes on terminal resize
vim.api.nvim_create_autocmd("VimResized", {
    callback = function() vim.cmd("wincmd =") end,
})
