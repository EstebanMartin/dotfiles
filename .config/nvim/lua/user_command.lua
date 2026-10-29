-- =================================================================
-- CopyPath: copy git-relative file path, with optional line range
-- =================================================================
vim.api.nvim_create_user_command("CopyPath",
    function(opts)
        -- full path of the file currently open
        local file = vim.api.nvim_buf_get_name(0)
        if file == "" then
            vim.notify("Buffer has no file", vim.log.levels.WARN)
            return
        end

        -- find the top of the git repo so we can make the path relative to it
        -- (e.g. "lib/foo.go" instead of "/Users/me/code/project/lib/foo.go")
        local root = vim.fs.root(0, ".git")
        local rel_path = root and file:sub(#root + 2) or file

        -- if a range was selected (e.g. in visual mode), append the line
        -- numbers to the path, like "lib/foo.go:10" or "lib/foo.go:10-15"
        -- ("-" rather than ":", which lua/autocmd.lua would read as a column)
        if opts.range > 0 then
            rel_path = rel_path .. ":" .. opts.line1
            if opts.line1 ~= opts.line2 then
                rel_path = rel_path .. "-" .. opts.line2
            end
        end

        -- put the final path on the system clipboard
        vim.fn.setreg("+", rel_path)
        vim.notify("Copied: " .. rel_path)
    end,
    {
        desc = "Copy git-relative file path, with optional line range",
        range = true,
    })

-- =================================================================
-- Format: format buffer via formatprg, fallback to LSP
-- =================================================================
vim.api.nvim_create_user_command("Format", function()
    local buf = vim.api.nvim_get_current_buf()

    -- if a shell formatter is configured (like stylua, fixjson, etc.),
    -- use it via "gq" instead of asking the LSP server to format
    if vim.bo[buf].formatprg ~= "" then
        local view = vim.fn.winsaveview()        -- remember cursor/scroll position
        vim.cmd.normal({ "gggqG", bang = true }) -- format the whole buffer
        vim.fn.winrestview(view)                 -- restore cursor/scroll position
        return
    end

    -- otherwise, fall back to asking the attached LSP server to format
    local clients = vim.lsp.get_clients({
        bufnr = buf,
        method = "textDocument/formatting",
    })
    if #clients > 0 then
        vim.lsp.buf.format({ async = false, bufnr = buf })
    end
end, {
    desc = "Format buffer via formatprg, fallback to LSP",
})

-- ====================================================================
-- GitURL: copy remote URL, optionally specifying a branch
-- ====================================================================

-- builds the "#L10-L15" style suffix that highlights specific lines
-- on the web (each git host uses a slightly different format)
---@param url string
---@param l1 integer start line
---@param l2 integer end line
---@return string anchor
local function url_anchor(url, l1, l2)
    if url:match("gitlab%.com") then
        return "#L" .. l1 .. "-" .. l2
    elseif url:match("bitbucket%.org") then
        return "#lines-" .. l1 .. ":" .. l2
    end
    return l1 == l2 and "#L" .. l1 or "#L" .. l1 .. "-L" .. l2
end

-- small helper that runs a git command and returns its output as a
-- list of lines (or an empty list if the command failed)
-- runs in the current file's directory, not Neovim's cwd, so it queries
-- the repo the file belongs to even after a :cd elsewhere
---@param ... string git subcommand and arguments
---@return string[] lines
local function git_lines(...)
    local dir = vim.fn.expand("%:p:h")
    local cwd = vim.fn.isdirectory(dir) == 1 and dir or nil
    local result = vim.system({ "git", ... }, { cwd = cwd, text = true }):wait()
    if result.code ~= 0 then return {} end
    return vim.split(result.stdout, "\n", { trimempty = true })
end

vim.api.nvim_create_user_command("GitURL", function(opts)
    local file = vim.api.nvim_buf_get_name(0)
    if file == "" then
        vim.notify("Buffer has no file", vim.log.levels.WARN)
        return
    end

    -- prefer "upstream" remote (common in forks), fall back to "origin"
    local remote = git_lines("remote", "get-url", "upstream")[1]
        or git_lines("remote", "get-url", "origin")[1]
    if not remote then
        vim.notify("No git remote found", vim.log.levels.WARN)
        return
    end

    -- find the top of the repo so we can build a path relative to it
    local git_root = vim.fs.root(0, ".git")
    if not git_root then
        vim.notify("Not in a git repository", vim.log.levels.WARN)
        return
    end

    -- use the branch typed by the user, or default to the repo's
    -- main branch (whatever "origin/HEAD" points to)
    local branch = opts.args ~= "" and opts.args
        or (git_lines("rev-parse", "--abbrev-ref", "origin/HEAD")[1] or "origin/main")
        :gsub("^origin/", "")

    -- convert the git remote (which may be an SSH-style URL) into a
    -- normal https:// URL that works in a browser
    local url = remote
        :gsub("^git@([^:]+):", "https://%1/")
        :gsub("%.git$", "")

    -- gitlab uses "/-/blob/" instead of "/blob/" in its file URLs
    local blob = url:match("gitlab%.com") and "/-/blob/" or "/blob/"

    -- if a range was selected, add a line-highlight anchor to the URL
    local anchor = opts.range > 0 and url_anchor(url, opts.line1, opts.line2) or ""

    local full_url = url .. blob .. branch .. "/" .. file:sub(#git_root + 2) .. anchor

    vim.fn.setreg("+", full_url)
    vim.notify("Copied: " .. full_url)
end, {
    desc = "Copy remote URL, optionally specifying a branch",
    nargs = "?",
    range = true,
    -- suggests branch names when typing ":GitURL <Tab>"
    complete = function(arglead)
        local branches = git_lines(
            "for-each-ref", "--format=%(refname:short)", "refs/heads/"
        )
        local current = git_lines("rev-parse", "--abbrev-ref", "HEAD")[1]

        -- if the user already typed something, only show matching branches
        if arglead ~= "" then
            local matches = {}
            for _, b in ipairs(branches) do
                if vim.startswith(b, arglead) then
                    table.insert(matches, b)
                end
            end
            return matches
        end

        -- otherwise, show the current branch first, then the rest
        local ordered = { current }
        for _, b in ipairs(branches) do
            if b ~= current then
                table.insert(ordered, b)
            end
        end
        return ordered
    end,
})

-- =================================================================
-- PackDelete: delete inactive plugins managed by vim.pack
-- =================================================================

-- returns the names of every installed plugin that isn't currently
-- active (loaded), optionally filtered to names starting with "arglead"
---@param arglead string?
---@return string[] names
local function inactive_plugins(arglead)
    local names = {}
    for _, p in ipairs(vim.pack.get()) do
        local name = not p.active and p.spec and p.spec.name
        if name and (not arglead or vim.startswith(name, arglead)) then
            table.insert(names, name)
        end
    end
    return names
end

vim.api.nvim_create_user_command("PackDelete", function(opts)
    if opts.bang then
        -- "PackDelete!" removes every inactive plugin at once
        vim.pack.del(inactive_plugins())
    elseif #opts.fargs > 0 then
        -- "PackDelete name1 name2" removes only the given plugins
        vim.pack.del(opts.fargs)
    else
        vim.notify(
            "Usage: PackDelete <name>... or PackDelete!",
            vim.log.levels.WARN
        )
    end
end, {
    desc = "Delete inactive plugins; ! deletes all at once",
    nargs = "*",
    bang = true,
    -- suggests inactive plugin names when typing ":PackDelete <Tab>"
    complete = function(arglead)
        local names = inactive_plugins(arglead)
        table.sort(names)
        return names
    end,
})

-- =================================================================
-- PackUpdate: update all plugins managed by vim.pack
-- =================================================================
vim.api.nvim_create_user_command(
    "PackUpdate",
    function() vim.pack.update() end,
    { desc = "Update plugins" }
)
