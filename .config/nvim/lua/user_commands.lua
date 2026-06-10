-- ====================================================================
-- CopyPath: copy git-relative file path, with optional line range
-- ====================================================================
vim.api.nvim_create_user_command(
    "CopyPath",
    function(opts)
        local file = vim.api.nvim_buf_get_name(0)
        if file == "" then
            vim.notify("Buffer has no file", vim.log.levels.WARN)
            return
        end

        local git_root = vim.fn.systemlist("git rev-parse --show-toplevel")[1]
        local rel_path = vim.v.shell_error == 0
            and file:sub(#git_root + 2)
            or file

        if opts.range > 0 then
            rel_path = rel_path .. ":" .. opts.line1 .. ":" .. opts.line2
        end

        vim.fn.setreg("+", rel_path)
        vim.notify("Copied: " .. rel_path)
    end,
    {
        desc = "Copy git-relative file path, with optional line range",
        range = true,
    }
)

-- ====================================================================
-- Format: format buffer via LSP, fallback to gq
-- ====================================================================
vim.api.nvim_create_user_command(
    "Format",
    function()
        local clients = vim.lsp.get_clients({
            bufnr = 0,
            method = "textDocument/formatting",
        })
        if #clients > 0 then
            vim.lsp.buf.format({ async = true, bufnr = 0 })
            return
        end
        vim.cmd.normal({ "ggVGgq", bang = true })
    end,
    {
        desc = "Format buffer via LSP, fallback to gq",
    }
)

-- ====================================================================
-- GitURL: copy remote URL, optionally specifying a branch
-- ====================================================================
local function git_lines(...)
    local result = vim.system({ "git", ... }, { text = true }):wait()
    if result.code ~= 0 then return {} end
    return vim.split(result.stdout, "\n", { trimempty = true })
end

local function url_anchor(url, l1, l2)
    if url:match("gitlab%.com") then
        return "#L" .. l1 .. "-" .. l2
    elseif url:match("bitbucket%.org") then
        return "#lines-" .. l1 .. ":" .. l2
    end
    return l1 == l2 and "#L" .. l1 or "#L" .. l1 .. "-L" .. l2
end

vim.api.nvim_create_user_command(
    "GitURL",
    function(opts)
        local file = vim.api.nvim_buf_get_name(0)
        if file == "" then
            vim.notify("Buffer has no file", vim.log.levels.WARN)
            return
        end

        local remote = git_lines("remote", "get-url", "upstream")[1]
            or git_lines("remote", "get-url", "origin")[1]
        if not remote then
            vim.notify("No git remote found", vim.log.levels.WARN)
            return
        end

        local git_root = git_lines("rev-parse", "--show-toplevel")[1]
        if not git_root then
            vim.notify("Not in a git repository", vim.log.levels.WARN)
            return
        end

        local branch = opts.args ~= "" and opts.args
            or (git_lines("rev-parse", "--abbrev-ref", "origin/HEAD")[1] or "origin/main")
            :gsub("^origin/", "")

        local url = remote
            :gsub("^git@([^:]+):", "https://%1/")
            :gsub("%.git$", "")

        local blob = url:match("gitlab%.com") and "/-/blob/" or "/blob/"
        local anchor = opts.range > 0 and url_anchor(url, opts.line1, opts.line2) or ""
        local full_url = url .. blob .. branch .. "/" .. file:sub(#git_root + 2) .. anchor

        vim.fn.setreg("+", full_url)
        vim.notify("Copied: " .. full_url)
    end,
    {
        desc = "Copy remote URL, optionally specifying a branch",
        nargs = "?",
        range = true,
        complete = function(arglead)
            local branches = git_lines(
                "for-each-ref", "--format=%(refname:short)", "refs/heads/"
            )
            local current = git_lines("rev-parse", "--abbrev-ref", "HEAD")[1]

            if arglead == "" then
                local others = vim.iter(branches)
                    :filter(function(b) return b ~= current end)
                    :totable()
                table.insert(others, 1, current)
                return others
            end

            return vim.iter(branches)
                :filter(function(b) return vim.startswith(b, arglead) end)
                :totable()
        end,
    }
)

-- =======================================================================
-- PackDelete: delete inactive plugins managed by vim.pack
-- =======================================================================
local function inactive_plugins(arglead)
    return vim.iter(vim.pack.get())
        :filter(function(p)
            if p.active then return false end
            local name = p.spec and p.spec.name
            if not name then return false end
            if arglead == nil then return true end
            return vim.startswith(name, arglead)
        end)
        :map(function(p) return p.spec.name end)
        :totable()
end

vim.api.nvim_create_user_command(
    "PackDelete",
    function(opts)
        if opts.bang then
            vim.pack.del(inactive_plugins())
        elseif #opts.fargs > 0 then
            vim.pack.del(opts.fargs)
        else
            vim.notify(
                "Usage: PackDelete <name>... or PackDelete!",
                vim.log.levels.WARN
            )
        end
    end,
    {
        desc = "Delete inactive plugins; ! deletes all at once",
        nargs = "*",
        bang = true,
        complete = function(arglead)
            local names = inactive_plugins(arglead)
            table.sort(names)
            return names
        end,
    }
)

-- =======================================================================
-- PackUpdate: update all plugins managed by vim.pack
-- =======================================================================
vim.api.nvim_create_user_command(
    "PackUpdate",
    function() vim.pack.update() end,
    { desc = "Update plugins and Mason tools" }
)

-- ====================================================================
-- ToggleTerm: toggle terminal, optionally run a shell command
-- ====================================================================
local term = { buf = nil, win = nil }

vim.api.nvim_create_user_command("ToggleTerm", function(opts)
    local cmd = opts.args ~= "" and opts.args or nil

    if term.win and vim.api.nvim_win_is_valid(term.win) then
        if not cmd then
            vim.api.nvim_win_close(term.win, true)
            term.win = nil
            return
        end
        vim.api.nvim_set_current_win(term.win)
    else
        local job_id = term.buf
            and vim.api.nvim_buf_is_valid(term.buf)
            and vim.b[term.buf].terminal_job_id
        local alive = job_id and vim.fn.jobwait({ job_id }, 0)[1] == -1

        if not alive then
            term.buf = vim.api.nvim_create_buf(false, true)
        end

        term.win = vim.api.nvim_open_win(term.buf, true, {
            split = "below",
            height = 15,
            win = -1,
        })

        if not alive then
            vim.fn.jobstart(vim.o.shell, { term = true })
        end
    end

    vim.cmd("startinsert")
    if not cmd then return end
    vim.schedule(function()
        vim.api.nvim_feedkeys(cmd .. "\n", "t", false)
    end)
end, {
    desc = "toggle terminal, optionally run a shell command",
    nargs = "*",
    complete = "shellcmd",
})

vim.keymap.set("n", "<C-Space>", "<cmd>ToggleTerm<CR>", { desc = "Toggle terminal", silent = true })
vim.keymap.set("t", "<C-Space>", "<C-\\><C-n><cmd>ToggleTerm<CR>", { desc = "Toggle terminal", silent = true })
