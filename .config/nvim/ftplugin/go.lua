-- =============================================================================
-- Highlights: coverage highlight groups
-- =============================================================================
-- link to built-in groups so colors adapt automatically to any colorscheme
vim.api.nvim_set_hl(0, "GoCoverageCovered", { link = "DiffAdd" })
vim.api.nvim_set_hl(0, "GoCoverageUncovered", { link = "DiagnosticError" })

-- =============================================================================
-- Organize imports on save
-- =============================================================================
vim.api.nvim_create_autocmd("BufWritePre", {
    group = vim.api.nvim_create_augroup("my.go", { clear = true }),
    buffer = vim.api.nvim_get_current_buf(),
    desc = "Organize Go imports before save",
    callback = function(args)
        local client = vim.lsp.get_clients({ bufnr = args.buf, name = "gopls" })[1]
        if not client then return end

        local params = vim.lsp.util.make_range_params(0, client.offset_encoding) --[[@as any]]
        local diags = vim.tbl_map(function(d)
            return {
                range = {
                    start = { line = d.lnum, character = d.col },
                    ["end"] = { line = d.end_lnum or d.lnum, character = d.end_col or d.col + 1 },
                },
                severity = d.severity,
                message = d.message,
            }
        end, vim.diagnostic.get(args.buf))
        params.context = { diagnostics = diags, only = { "source.organizeImports" } }

        local results = vim.lsp.buf_request_sync(
            args.buf,
            "textDocument/codeAction",
            params,
            1000
        )

        for client_id, res in pairs(results or {}) do
            local c = vim.lsp.get_client_by_id(client_id)
            for _, action in ipairs(res.result or {}) do
                if c and action.edit then
                    vim.lsp.util.apply_workspace_edit(action.edit, c.offset_encoding)
                end
                if c and action.command then
                    c:exec_cmd(action.command, { bufnr = args.buf })
                end
            end
        end
    end,
})

-- =============================================================================
-- <localleader>a: Alternate test file
-- =============================================================================
vim.keymap.set("n", "<localleader>a", function()
    local path = vim.api.nvim_buf_get_name(0)
    if path == "" then
        vim.notify("Current buffer has no file name", vim.log.levels.WARN)
        return
    end
    -- toggle between foo.go <-> foo_test.go based on current filename
    vim.cmd.edit(vim.fn.fnameescape(
        path:match("_test%.go$")
        and path:gsub("_test%.go$", ".go")
        or path:gsub("%.go$", "_test.go")
    ))
end, { buffer = true, desc = "Alternate test file" })

-- =============================================================================
-- <localleader>c: Toggle test coverage
-- =============================================================================
-- namespace isolates our extmarks so clearing them won't affect other plugins
local go_coverage_ns = vim.api.nvim_create_namespace("go_coverage")

vim.keymap.set("n", "<localleader>c", function()
    local bufnr = vim.api.nvim_get_current_buf()

    -- second call clears highlights (toggle behavior)
    local existing = vim.api.nvim_buf_get_extmarks(
        bufnr, go_coverage_ns, 0, -1, {}
    )
    if #existing > 0 then
        vim.api.nvim_buf_clear_namespace(bufnr, go_coverage_ns, 0, -1)
        vim.notify("Go coverage highlights cleared")
        return
    end

    local filepath = vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr))
    if filepath == "" then
        vim.notify("Current buffer has no file name", vim.log.levels.WARN)
        return
    end

    local dir = vim.fs.dirname(filepath)

    -- coverage profiles use module import paths, not filesystem paths
    -- e.g. "github.com/user/repo/pkg/foo.go" instead of "/home/user/..."
    -- we need mod_root + mod_name to convert them back to absolute paths
    local mod_root = vim.fs.root(0, "go.mod") or dir
    local mod_name = ""
    local mod_file = io.open(mod_root .. "/go.mod", "r")
    if mod_file then
        -- first line of go.mod is always "module <name>"
        mod_name = mod_file:read("l"):match("^module%s+(%S+)") or ""
        mod_file:close()
    end

    -- run tests and capture coverage profile in a temp file
    local coverage_path = vim.fn.tempname() .. ".cov"
    local result = vim.system(
        { "go", "test", ("-coverprofile=%s"):format(coverage_path) },
        { cwd = dir, text = true }
    ):wait()

    if result.code ~= 0 then
        -- prefer stderr, fall back to stdout (go test mixes them)
        local msg = result.stderr ~= "" and result.stderr or result.stdout
        vim.notify("go test failed:\n" .. msg, vim.log.levels.ERROR)
        return
    end

    if vim.fn.filereadable(coverage_path) == 0 then
        vim.notify("Coverage profile was not created", vim.log.levels.ERROR)
        return
    end

    -- coverage profile format (one range per line):
    -- file:startLine.startCol,endLine.endCol numStmts count
    -- count == 0 means the block was never executed
    local covered, uncovered = 0, 0
    for line in io.lines(coverage_path) do
        local file, sl, sc, el, ec, _, count =
            line:match(
                "^([^:]+):(%d+)%.(%d+),(%d+)%.(%d+)%s+(%d+)%s+(%d+)$"
            )
        if file then
            -- strip module prefix to get relative path, resolve to absolute
            local rel = mod_name ~= ""
                and file:gsub("^" .. vim.pesc(mod_name) .. "/", "")
                or file
            local abs_file = vim.fs.normalize(
                vim.fs.joinpath(mod_root, rel)
            )
            -- skip ranges that belong to other files in the package
            if abs_file == filepath then
                sl    = tonumber(sl)
                sc    = tonumber(sc)
                el    = tonumber(el)
                ec    = tonumber(ec)
                count = tonumber(count)
                local hl_group
                if count == 0 then
                    hl_group = "GoCoverageUncovered"
                    uncovered = uncovered + 1
                else
                    hl_group = "GoCoverageCovered"
                    covered = covered + 1
                end
                -- extmarks survive buffer reloads and shift with edits
                vim.api.nvim_buf_set_extmark(
                    bufnr, go_coverage_ns, sl - 1, sc - 1, {
                        end_line = el - 1,
                        end_col  = ec - 1,
                        hl_group = hl_group,
                        hl_mode  = "combine", -- blend with syntax highlights
                        priority = 200,       -- above treesitter (100), below diagnostics (300)
                    }
                )
            end
        end
    end

    vim.fn.delete(coverage_path) -- clean up temp file

    if covered == 0 and uncovered == 0 then
        vim.notify("No coverage data for current file", vim.log.levels.INFO)
        return
    end

    vim.notify(
        ("Go coverage highlighted: %s (%d covered, %d uncovered)"):format(
            vim.fn.fnamemodify(filepath, ":t"), covered, uncovered
        )
    )
end, { buffer = true, desc = "Toggle test coverage" })

-- =============================================================================
-- <localleader>ds: Debug start
-- =============================================================================
local function start_debug()
    local git_root = vim.fs.root(0, ".git")
    local root = git_root or vim.fn.expand("%:p:h")
    local binary = vim.fn.fnamemodify(root, ":t") -- repo dir name = binary name

    -- check if Makefile has a `debug:` target before falling back to raw build
    local makefile = root .. "/Makefile"
    local has_make_debug = false
    if git_root and vim.fn.filereadable(makefile) == 1 then
        local grep = vim.system(
            { "grep", "-q", "^debug:", makefile },
            { text = true }
        ):wait()
        has_make_debug = grep.code == 0
    end

    local escaped_root = vim.fn.shellescape(root)
    local make_cmd     = "cd %s && make debug"
    -- -N disables optimizations, -l disables inlining: required for dlv to work
    local build_cmd    =
    "cd %s && go build -gcflags='all=-N -l' -o ./%s && ./%s"
    local cmd          = has_make_debug
        and make_cmd:format(escaped_root)
        or build_cmd:format(escaped_root, binary, binary)

    vim.cmd("ToggleTerm " .. cmd) -- start the process in the terminal

    -- poll every 500ms for the process PID; attach DAP once it appears
    -- cap at 20 attempts (10s) to avoid polling forever if process fails
    local timer = vim.uv.new_timer()
    if not timer then return end

    local attempts = 0
    timer:start(500, 500, vim.schedule_wrap(function()
        attempts = attempts + 1
        if attempts > 20 then
            timer:stop(); timer:close()
            vim.notify("Debug: process not found after 10s", vim.log.levels.WARN)
            return
        end
        -- pgrep -x matches the full process name exactly
        local pgrep = vim.system(
            { "pgrep", "-x", binary },
            { text = true }
        ):wait()
        local pid = tonumber(pgrep.stdout)
        if not pid then return end -- not up yet, try again next tick

        timer:stop(); timer:close()
        -- "attach" mode connects to a running process vs "launch" starts one
        require("dap").run({
            type      = "go",
            request   = "attach",
            name      = "Attach to " .. binary,
            mode      = "local",
            processId = pid,
        })
    end))
end

vim.keymap.set("n", "<localleader>ds",
    start_debug,
    { buffer = true, desc = "Debug start" }
)

-- =============================================================================
-- <localleader>i: Import package
-- =============================================================================
vim.keymap.set("n", "<localleader>i", function()
    local bufnr = vim.api.nvim_get_current_buf()
    -- gopls must be attached; other LSP servers don't support these commands
    local client = vim.lsp.get_clients({ bufnr = bufnr, name = "gopls" })[1]
    if not client then
        vim.notify("gopls is not attached", vim.log.levels.WARN)
        return
    end
    local uri = vim.uri_from_bufnr(bufnr)
    -- gopls.list_known_packages returns all packages visible to the module
    client:exec_cmd({
        title     = "List known packages",
        command   = "gopls.list_known_packages",
        arguments = { { URI = uri } },
    }, { bufnr = bufnr }, function(err, result)
        if err then
            vim.notify(
                ("Failed to get packages: %s"):format(err.message or err),
                vim.log.levels.ERROR
            )
            return
        end
        local packages = result and (result.Packages or result)
        if not packages or vim.tbl_isempty(packages) then
            vim.notify("No packages returned by gopls", vim.log.levels.INFO)
            return
        end
        -- let the user pick from the list using the configured vim.ui.select
        vim.ui.select(packages, {
            prompt = "Select a Go package to import:",
        }, function(selection)
            if not selection then return end
            -- gopls.add_import adds the import and runs goimports internally
            client:exec_cmd({
                title     = "Add import",
                command   = "gopls.add_import",
                arguments = { { URI = uri, ImportPath = selection } },
            }, { bufnr = bufnr })
        end)
    end)
end, { buffer = true, desc = "Import package" })

-- =============================================================================
-- <localleader>r: Run
-- =============================================================================
vim.keymap.set("n", "<localleader>r", function()
    local git_root = vim.fs.root(0, ".git")
    local root = git_root or vim.fn.expand("%:p:h")

    -- check if Makefile has a `run:` target before falling back to go run
    local makefile = root .. "/Makefile"
    local has_make_run = false
    if git_root and vim.fn.filereadable(makefile) == 1 then
        local grep = vim.system(
            { "grep", "-q", "^run:", makefile },
            { text = true }
        ):wait()
        has_make_run = grep.code == 0
    end

    local cmd = has_make_run
        and ("cd %s && make run"):format(vim.fn.shellescape(root))
        or ("cd %s && go run ."):format(vim.fn.shellescape(root))

    vim.cmd("ToggleTerm " .. cmd)
end, { buffer = true, desc = "Run" })

-- =============================================================================
-- <localleader>t: Go test
-- =============================================================================
vim.keymap.set("n", "<localleader>t", function()
    -- run tests for the package in the current file's directory
    local buf_dir = vim.fn.shellescape(vim.fn.expand("%:p:h"))
    vim.cmd(("ToggleTerm go test %s"):format(buf_dir))
end, { buffer = true, desc = "Go test" })
