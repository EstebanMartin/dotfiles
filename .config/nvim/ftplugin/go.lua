-- =================================================================
-- Organize Go imports before save
-- =================================================================
-- the group is shared by every Go buffer, so don't clear it ("clear = true"
-- would drop the other buffers' autocmds); only clear this buffer's, so
-- re-running this ftplugin doesn't register it twice
local organize_imports_group = vim.api.nvim_create_augroup(
    "OrganizeImports", { clear = false }
)
vim.api.nvim_clear_autocmds({ group = organize_imports_group, buffer = 0 })

vim.api.nvim_create_autocmd("BufWritePre", {
    group = organize_imports_group,
    buffer = 0,
    desc = "Organize Go imports before save",
    callback = function(args)
        -- this only works if gopls is attached to the buffer
        local client = vim.lsp.get_clients({ bufnr = args.buf, name = "gopls" })[1]
        if not client then return end

        -- ask gopls specifically for the "organize imports" code action
        -- (this covers adding missing imports and removing unused ones)
        local params = vim.lsp.util.make_range_params(0, client.offset_encoding) --[[@as any]]
        params.context = { only = { "source.organizeImports" } }

        -- request the code action and wait (max 1 second) for a reply
        -- before the file gets saved
        local results = vim.lsp.buf_request_sync(
            args.buf, "textDocument/codeAction", params, 1000
        )

        -- apply whatever edits gopls sent back
        for _, res in pairs(results or {}) do
            for _, action in ipairs(res.result or {}) do
                if action.edit then
                    vim.lsp.util.apply_workspace_edit(action.edit, client.offset_encoding)
                end
            end
        end
    end,
})

-- =================================================================
-- <localleader>a: Alternate test file
-- =================================================================
vim.keymap.set("n", "<localleader>a", function()
    -- full path of the file currently open
    local path = vim.api.nvim_buf_get_name(0)
    if path == "" then
        vim.notify("Current buffer has no file name", vim.log.levels.WARN)
        return
    end

    -- figure out the "opposite" filename:
    -- if we're in a _test.go file, strip "_test" to get the source file
    -- otherwise, add "_test" to get the test file
    local is_test_file = path:match("_test%.go$") ~= nil
    ---@type string
    local target_path
    if is_test_file then
        target_path = path:gsub("_test%.go$", ".go")
    else
        target_path = path:gsub("%.go$", "_test.go")
    end

    -- open the other file
    vim.cmd.edit(vim.fn.fnameescape(target_path))
end, { buffer = true, desc = "Alternate test file" })

-- =================================================================
-- <localleader>c: Toggle test coverage
-- =================================================================

-- highlight groups for covered/uncovered lines (linked to existing colors)
vim.api.nvim_set_hl(0, "GoCoverageCovered", { link = "DiffAdd" })
vim.api.nvim_set_hl(0, "GoCoverageUncovered", { link = "DiffDelete" })

-- namespace keeps our highlights separate from other plugins' highlights
local go_coverage_ns = vim.api.nvim_create_namespace("go_coverage")

vim.keymap.set("n", "<localleader>c", function()
    local bufnr = vim.api.nvim_get_current_buf()

    -- if highlights already exist, this call clears them instead (toggle)
    if #vim.api.nvim_buf_get_extmarks(bufnr, go_coverage_ns, 0, -1, {}) > 0 then
        vim.api.nvim_buf_clear_namespace(bufnr, go_coverage_ns, 0, -1)
        vim.notify("Go coverage highlights cleared")
        return
    end

    -- get the full path of the current file
    local filepath = vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr))
    if filepath == "" then
        vim.notify("Current buffer has no file name", vim.log.levels.WARN)
        return
    end

    local dir = vim.fs.dirname(filepath)             -- folder containing this file
    local mod_root = vim.fs.root(0, "go.mod") or dir -- project root (where go.mod lives)

    -- read the module name from go.mod (first line looks like "module some/name")
    -- we need this because go test reports files using the module path,
    -- not the real filesystem path, e.g. "github.com/user/repo/pkg/foo.go"
    local mod_name = ""
    local mod_file = io.open(mod_root .. "/go.mod", "r")
    if mod_file then
        mod_name = mod_file:read("l"):match("^module%s+(%S+)") or ""
        mod_file:close()
    end

    -- go test will write its coverage results into this temp file
    local coverage_path = vim.fn.tempname() .. ".cov"

    -- native progress message: ◐ in the statusline while it runs, updated
    -- in place via progress.id when it finishes
    local progress = { kind = "progress", source = "go", title = "go test", status = "running" }
    progress.id = vim.api.nvim_echo({ { "Running with coverage..." } }, false, progress)

    -- run "go test" in the background so the editor doesn't freeze
    vim.system(
        { "go", "test", ("-coverprofile=%s"):format(coverage_path) },
        { cwd = dir, text = true },
        function(result)
            -- this callback runs in the background, so we schedule the
            -- rest to run safely on Neovim's main loop
            vim.schedule(function()
                progress.status = result.code == 0 and "success" or "failed"
                vim.api.nvim_echo({ { "Finished" } }, false, progress)

                -- go test itself failed (compile error, failing test, etc.)
                if result.code ~= 0 then
                    vim.notify(
                        "go test failed:\n" .. (result.stderr ~= "" and result.stderr or result.stdout),
                        vim.log.levels.ERROR
                    )
                    return
                end
                if vim.fn.filereadable(coverage_path) == 0 then
                    vim.notify("Coverage profile was not created", vim.log.levels.ERROR)
                    return
                end
                -- user may have closed the buffer while the test was running
                if not vim.api.nvim_buf_is_valid(bufnr) then
                    vim.fn.delete(coverage_path)
                    return
                end

                local has_data = false -- did we find any coverage info for this file?
                ---@type integer? line number to jump to at the end
                local first_uncovered_line = nil

                -- the coverage file has one line per code range, formatted like:
                -- file:startLine.startCol,endLine.endCol numStatements timesExecuted
                for line in io.lines(coverage_path) do
                    local file, sl, sc, el, ec, _, count = line:match(
                        "^([^:]+):(%d+)%.(%d+),(%d+)%.(%d+)%s+(%d+)%s+(%d+)$"
                    )
                    if file then
                        -- convert the module-style path back into a real filesystem path
                        local rel = mod_name ~= ""
                            and file:gsub("^" .. vim.pesc(mod_name) .. "/", "")
                            or file
                        local abs_file = vim.fs.normalize(vim.fs.joinpath(mod_root, rel))

                        -- only care about ranges belonging to the file we're viewing
                        if abs_file == filepath then
                            has_data = true
                            local is_covered = tonumber(count) > 0 -- ran at least once?

                            -- draw a highlight over this range of code
                            vim.api.nvim_buf_set_extmark(
                                bufnr, go_coverage_ns, tonumber(sl) - 1, tonumber(sc) - 1, {
                                    end_line = tonumber(el) - 1,
                                    end_col  = tonumber(ec) - 1,
                                    hl_group = is_covered and "GoCoverageCovered" or "GoCoverageUncovered",
                                    hl_mode  = "combine", -- blend with existing syntax colors
                                    priority = 200,       -- above treesitter, below diagnostics
                                }
                            )

                            -- remember the earliest uncovered line so we can jump to it
                            if not is_covered
                                and (not first_uncovered_line or tonumber(sl) < first_uncovered_line)
                            then
                                first_uncovered_line = tonumber(sl)
                            end
                        end
                    end
                end

                if not has_data then
                    vim.fn.delete(coverage_path)
                    vim.notify("No coverage data for current file", vim.log.levels.INFO)
                    return
                end

                -- jump the cursor to the first line that wasn't covered
                if first_uncovered_line then
                    vim.api.nvim_win_set_cursor(0, { first_uncovered_line, 0 })
                end

                -- ask Go for the overall coverage percentage of the whole
                -- package, in the background like go test itself
                vim.system(
                    { "go", "tool", "cover", "-func=" .. coverage_path },
                    { text = true },
                    function(cover_result)
                        vim.schedule(function()
                            vim.fn.delete(coverage_path) -- temp file no longer needed
                            local total_pct = (cover_result.stdout or ""):match("total:%s*%S+%s+([%d%.]+)%%")
                            vim.notify(
                                ("Go coverage: %s%% total"):format(total_pct or "?"),
                                vim.log.levels.INFO
                            )
                        end)
                    end
                )
            end)
        end
    )
end, { buffer = true, desc = "Toggle test coverage" })

-- =================================================================
-- Split direction helper (shared by <localleader>r and <localleader>d)
-- =================================================================
-- Whether a new split off `win` should stack "below" or sit to the "right",
-- based on available space rather than always defaulting to one direction.
--
-- Compares cells, not pixels, but a terminal cell is roughly twice as tall as
-- it is wide, so raw column/line counts would call almost every window
-- "wide". Scaling height by 2 approximates the on-screen aspect instead: a
-- window that reads as taller than it is wide gets stacked below; one that
-- reads as wider than tall gets a side-by-side split.
---@param win integer
---@return "below"|"right"
local function split_direction(win)
    local width = vim.api.nvim_win_get_width(win)
    local height = vim.api.nvim_win_get_height(win) * 2
    return height > width and "below" or "right"
end

-- =================================================================
-- <localleader>d: Debug
-- =================================================================
-- The service and the DAP session are kept in lockstep so neither can
-- outlive the other and dangle in the background:
--   service exits (crash, ^C, buffer wiped) while dlv is attached
--                                        -> tear down the DAP session
--   DAP session ends (:DapTerminate, or the "disconnect" a stopped
--   "attach" session sends, which by itself leaves the debuggee running)
--                                        -> kill the service
--
-- "kill the service" means the actual binary's pid, not vim.fn.jobstop() on
-- the job: jobstop only signals the job's direct child, which is the shell
-- running `make debug` (or `go build && ./binary`) — verified that a `make`
-- recipe survives that signal and keeps the binary running as an orphan.
-- Killing the binary's own pid (already in hand from the polling below) is
-- what actually reaches it; the wrapping shell/make then sees its child die
-- and exits on its own, which fires the job's on_exit same as if it had
-- died naturally.
vim.keymap.set("n", "<localleader>d",
    function()
        local git_root = vim.fs.root(0, ".git")
        local root = git_root or vim.fn.expand("%:p:h")
        local binary = vim.fn.fnamemodify(root, ":t") -- repo dir name = binary name

        -- check if Makefile has a `debug:` target before falling back to raw build
        local makefile = root .. "/Makefile"
        local has_make_debug = git_root ~= nil
            and vim.fn.filereadable(makefile) == 1
            and vim.iter(vim.fn.readfile(makefile)):any(function(l) return l:match("^debug:") ~= nil end)

        local escaped_root = vim.fn.shellescape(root)
        local make_cmd     = "cd %s && make debug"
        -- -N disables optimizations, -l disables inlining: required for dlv to work
        local build_cmd    =
        "cd %s && go build -gcflags='all=-N -l' -o ./%s && ./%s"
        local cmd          = has_make_debug
            and make_cmd:format(escaped_root)
            or build_cmd:format(escaped_root, binary, binary)

        -- attached: true once dlv has actually attached, so a service that
        --   dies before that (e.g. build failure) doesn't try to tear down
        --   a DAP session that was never started
        -- stopping: guards the two teardown paths below from looping into
        --   each other (job exit -> stop dap -> disconnect -> stop service -> ...)
        -- service_pid: the binary's own pid, set once the polling below finds
        --   it; see the note above on why this is what gets killed
        local attached     = false
        local stopping     = false
        local service_pid ---@type integer?
        local timer -- the PID-polling timer below, closed once it fires or is superseded
        local job_id ---@type integer

        local function stop_dap()
            if stopping then return end
            stopping = true
            if timer then
                timer:stop(); timer:close(); timer = nil
            end
            if attached then
                local ok, dap = pcall(require, "dap")
                if ok and dap.session() then dap.terminate() end
            end
        end

        local function stop_service()
            if stopping then return end
            stopping = true
            if service_pid then
                vim.uv.kill(service_pid, "sigterm")
            else
                -- dlv never attached (still building); best effort on the job itself
                vim.fn.jobstop(job_id)
            end
        end

        -- run the build+service in a terminal split, same as <localleader>r
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_open_win(buf, true, { split = split_direction(0), win = 0 })
        job_id = vim.fn.jobstart(cmd, { term = true, on_exit = stop_dap })
        if job_id <= 0 then
            vim.notify("Debug: failed to start service", vim.log.levels.ERROR)
            return
        end

        -- poll every 500ms for the process PID; attach DAP once it appears
        -- cap at 240 attempts (2min): a cold `-N -l` build recompiles every
        -- dependency and easily takes longer than a warm one. A build that
        -- fails ends the job, whose on_exit (stop_dap) stops this timer early
        timer = assert(vim.uv.new_timer())
        local attempts = 0
        timer:start(500, 500, vim.schedule_wrap(function()
            attempts = attempts + 1
            if attempts > 240 then
                timer:stop(); timer:close(); timer = nil
                vim.notify("Debug: process not found after 2min", vim.log.levels.WARN)
                return
            end
            -- pgrep -x matches the full process name exactly
            local pgrep = vim.system(
                { "pgrep", "-x", binary },
                { text = true }
            ):wait()
            local pid = tonumber(pgrep.stdout)
            if not pid then return end -- not up yet, try again next tick

            timer:stop(); timer:close(); timer = nil

            local ok, dap = pcall(require, "dap")
            if not ok then
                vim.notify("Debug: nvim-dap is not installed", vim.log.levels.WARN)
                return
            end

            attached = true
            service_pid = pid
            -- an "attach" session's disconnect leaves the debuggee running by
            -- default, so stopping the debugger has to kill the service itself
            dap.listeners.after.event_terminated["go_debug_start"] = stop_service
            dap.listeners.after.disconnect["go_debug_start"] = stop_service

            -- "attach" mode connects to a running process vs "launch" starts one
            dap.run({
                type      = "go",
                request   = "attach",
                name      = "Attach to " .. binary,
                mode      = "local",
                processId = pid,
            })
        end))
    end,
    { buffer = true, desc = "Debug start" }
)

-- =================================================================
-- <localleader>i: Import package
-- =================================================================
vim.keymap.set("n", "<localleader>i", function()
    local bufnr = vim.api.nvim_get_current_buf()

    -- this feature only works through gopls, so make sure it's attached
    local client = vim.lsp.get_clients({ bufnr = bufnr, name = "gopls" })[1]
    if not client then
        vim.notify("gopls is not attached", vim.log.levels.WARN)
        return
    end

    -- gopls identifies files by URI (a file:// path), not by buffer number
    local uri = vim.uri_from_bufnr(bufnr)

    -- ask gopls for every package it knows about that we could import
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

        -- the package list can come back under a "Packages" key,
        -- or as the result itself depending on the gopls version
        local packages = result and (result.Packages or result)
        if not packages or vim.tbl_isempty(packages) then
            vim.notify("No packages returned by gopls", vim.log.levels.INFO)
            return
        end

        -- show a picker so the user can choose which package to import
        vim.ui.select(packages, {
            prompt = "Select a Go package to import:",
        }, function(selection)
            if not selection then return end -- user cancelled the picker

            -- ask gopls to add the import; it also runs goimports
            -- internally to place it correctly and format the import block
            client:exec_cmd({
                title     = "Add import",
                command   = "gopls.add_import",
                arguments = { { URI = uri, ImportPath = selection } },
            }, { bufnr = bufnr })
        end)
    end)
end, { buffer = true, desc = "Import package" })

-- =================================================================
-- <localleader>r: Run
-- =================================================================
vim.keymap.set("n", "<localleader>r", function()
    -- find the project root (top of the git repo), fall back to the
    -- current file's directory if there's no git repo
    local git_root = vim.fs.root(0, ".git")
    local root = git_root or vim.fn.expand("%:p:h")

    -- prefer "make run" if a Makefile with a "run:" target exists,
    -- otherwise fall back to plain "go run ."
    local has_make_run = git_root
        and vim.fn.filereadable(root .. "/Makefile") == 1
        and vim.iter(vim.fn.readfile(root .. "/Makefile")):any(function(l) return l:match("^run:") ~= nil end)

    local cmd = ("cd %s && %s"):format(
        vim.fn.shellescape(root),
        has_make_run and "make run" or "go run ."
    )

    -- open a terminal in a split, direction depending on available space,
    -- and run the command in it
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_open_win(buf, true, { split = split_direction(0), win = 0 })
    vim.fn.jobstart(cmd, { term = true })
end, { buffer = true, desc = "Run" })

-- =================================================================
-- <localleader>t: Go test
-- =================================================================
vim.keymap.set("n", "<localleader>t",
    function()
        -- native progress message: ◐ in the statusline while the tests
        -- run, updated in place via progress.id with the result
        local progress = { kind = "progress", source = "go", title = "go test", status = "running" }
        progress.id = vim.api.nvim_echo({ { "Running..." } }, false, progress)

        -- run "go test" for the package containing the current file,
        -- without blocking the editor; cwd is the file's own directory,
        -- so it works wherever Neovim's cwd happens to be
        vim.system(
            { "go", "test", "." },
            { cwd = vim.fn.expand("%:p:h"), text = true },
            function(result)
                -- this callback runs in the background, so we schedule
                -- the rest to run safely on Neovim's main loop
                vim.schedule(function()
                    -- exit code 0 means every test passed
                    local passed = result.code == 0
                    progress.status = passed and "success" or "failed"
                    vim.api.nvim_echo({ { passed and "All tests passed" or "Tests failed" } }, false, progress)
                    if passed then return end

                    -- something failed: show the test output so we can
                    -- see what went wrong (go test mixes stdout/stderr)
                    local output = result.stdout ~= "" and result.stdout or result.stderr
                    if not output then return end

                    -- open the output in a real terminal buffer below,
                    -- which keeps the test runner's colors intact
                    local buf = vim.api.nvim_create_buf(false, true)
                    vim.api.nvim_open_win(buf, true, {
                        split = "below", win = 0,
                    })
                    local chan = vim.api.nvim_open_term(buf, {})
                    -- terminals expect \r\n line endings to render correctly
                    vim.fn.chansend(chan, (output:gsub("\n", "\r\n")))
                end)
            end)
    end,
    { buffer = true, desc = "Go test" }
)
