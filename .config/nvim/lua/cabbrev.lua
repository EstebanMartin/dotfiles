local abbrevs = {
    -- cdr: cd to git repository root
    cdr = "execute 'cd' fnameescape(v:lua.vim.fs.root(0, '.git'))",

    -- cdh: cd to current file's directory
    cdh = "cd %:h",

    -- vfind: fuzzy find file in vertical split
    vfind = "vert sfind",

    -- rnu: toggle relative number
    rnu = "set relativenumber!",

    -- inh: toggle inlay hints
    inh = "lua vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled())",
}

-- plain cabbrevs also expand in / searches and mid-command, so only expand
-- when the abbreviation is the whole ":" command line typed so far
for lhs, rhs in pairs(abbrevs) do
    vim.keymap.set("ca", lhs, function()
        if vim.fn.getcmdtype() == ":" and vim.fn.getcmdline() == lhs then
            return rhs
        end
        return lhs
    end, { expr = true })
end
