-- =============================================================================
-- get_path_under_cursor: build yq-style path from node under cursor
-- =============================================================================
---@return string
local function get_path_under_cursor()
    local buf = vim.api.nvim_get_current_buf()
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    row = row - 1 -- nvim_win_get_cursor is 1-based; treesitter is 0-based

    -- parse the buffer and find the smallest node covering the cursor position
    local parser = vim.treesitter.get_parser(buf, "yaml")
    if not parser then
        vim.notify("treesitter parser for yaml not available", vim.log.levels.ERROR)
        return ""
    end

    local tree = parser:parse()[1]
    if not tree then return "" end -- guard against malformed/empty YAML

    local node = tree:root():named_descendant_for_range(row, col, row, col)
    local path = {}

    -- walk up the tree, collecting key names and array indices
    while node do
        local node_type = node:type()
        local parent    = node:parent()

        if node_type == "block_mapping_pair" then
            -- extract the key string, stripping surrounding quotes
            local key = node:field("key")[1]
            if key then
                local key_text =
                    vim.treesitter.get_node_text(key, buf)
                    :gsub('^"(.-)"$', "%1")
                table.insert(path, 1, "." .. key_text)
            end
        end

        if parent and parent:type() == "block_sequence" then
            -- count named siblings before this node to get the array index
            local index = 0
            for child in parent:iter_children() do
                if child:named() then
                    if child == node then
                        table.insert(path, 1, ("[%d]"):format(index))
                        break
                    end
                    index = index + 1
                end
            end
        end

        node = parent
    end

    return table.concat(path)
end

-- =============================================================================
-- walk_yaml_paths: collect all paths for the jump picker
-- =============================================================================
---@param buf integer
---@param node any
---@param path string
---@param paths table
local function walk_yaml_paths(buf, node, path, paths)
    local node_type = node:type()

    if node_type == "block_mapping_pair" then
        local key   = node:field("key")[1]
        local value = node:field("value")[1]
        if key and value then
            local key_text = vim.treesitter.get_node_text(key, buf)
            local new_path = path .. "." .. key_text
            local row, col = key:range() -- 0-based; add 1 for nvim cursor API
            table.insert(paths, {
                label = new_path,
                lnum  = row + 1,
                col   = col + 1,
            })
            walk_yaml_paths(buf, value, new_path, paths)
        end
    elseif node_type == "block_mapping"
        or node_type == "block_node"
        or node_type == "document"
        or node_type == "stream" then
        -- recurse into container nodes without adding a path segment
        for child in node:iter_children() do
            walk_yaml_paths(buf, child, path, paths)
        end
    elseif node_type == "block_sequence" then
        -- only block_sequence_item children carry values (skip punctuation)
        local i = 0
        for child in node:iter_children() do
            if child:type() == "block_sequence_item" then
                local value = child:field("value")[1]
                if value then
                    local new_path = path .. ("[%d]"):format(i)
                    local row, col = value:range()
                    table.insert(paths, {
                        label = new_path,
                        lnum  = row + 1,
                        col   = col + 1,
                    })
                    walk_yaml_paths(buf, value, new_path, paths)
                    i = i + 1
                end
            end
        end
    end
end

-- =============================================================================
-- Show yq path in winbar
-- =============================================================================
local yaml_group = vim.api.nvim_create_augroup("my.yaml", { clear = true })

if vim.fn.exists("+winbar") == 1 then
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group    = yaml_group,
        buffer   = vim.api.nvim_get_current_buf(),
        desc     = "Show yq path in winbar",
        callback = function()
            -- pcall guards against parse errors in malformed YAML
            local ok, path = pcall(get_path_under_cursor)
            vim.opt_local.winbar = ok and path or ""
        end,
    })
end

-- =============================================================================
-- <localleader>c: Copy YAML path
-- =============================================================================
vim.keymap.set("n", "<localleader>c", function()
    local path = get_path_under_cursor()
    if path == "" then
        vim.notify("No path found under cursor", vim.log.levels.WARN)
        return
    end
    vim.fn.setreg("+", path) -- "+" is the system clipboard register
    vim.notify("Copied path: " .. path, vim.log.levels.INFO)
end, { buffer = true, desc = "Copy YAML path" })

-- =============================================================================
-- <localleader>f: Filter with yq
-- =============================================================================
vim.keymap.set("n", "<localleader>f", function()
    if vim.fn.executable("yq") == 0 then
        vim.notify("yq not found in PATH", vim.log.levels.ERROR)
        return
    end

    vim.ui.input({ prompt = "yq filter: " }, function(filter)
        if not filter or filter == "" then return end

        local yaml_input = table.concat(
            vim.api.nvim_buf_get_lines(0, 0, -1, false --[[@as boolean]]), "\n"
        )

        -- run yq asynchronously; --indent 2 sets output indentation
        vim.system(
            { "yq", "--indent", "2", filter },
            { stdin = yaml_input, text = true },
            function(obj)
                vim.schedule(function()
                    if obj.code ~= 0 then
                        vim.notify(
                            obj.stderr ~= "" and obj.stderr or "yq failed",
                            vim.log.levels.ERROR
                        )
                        return
                    end

                    if not obj.stdout or obj.stdout == "" then
                        vim.notify("yq returned no output", vim.log.levels.INFO)
                        return
                    end

                    local lines = vim.split(
                        obj.stdout, "\n", { plain = true, trimempty = true }
                    )

                    -- open result in a centered floating window
                    local out_buf = vim.api.nvim_create_buf(false, true)
                    vim.api.nvim_buf_set_lines(out_buf, 0, -1, false, lines)
                    vim.bo[out_buf].filetype   = "yaml"
                    vim.bo[out_buf].modifiable = false
                    vim.bo[out_buf].bufhidden  = "wipe" -- auto-delete when closed

                    local width                = math.floor(vim.o.columns * 0.7)
                    local height               = math.floor(vim.o.lines * 0.6)
                    local row                  = math.floor((vim.o.lines - height) / 2)
                    local col                  = math.floor((vim.o.columns - width) / 2)

                    vim.api.nvim_open_win(out_buf, true, {
                        relative  = "editor",
                        style     = "minimal",
                        border    = "rounded",
                        title     = " yq output ",
                        title_pos = "center",
                        row       = row,
                        col       = col,
                        width     = width,
                        height    = height,
                    })

                    -- q closes the floating window
                    vim.keymap.set("n", "q", "<cmd>close<cr>", {
                        buffer = out_buf,
                        silent = true,
                        desc   = "Close yq output",
                    })
                end)
            end
        )
    end)
end, { buffer = true, desc = "Filter with yq" })

-- =============================================================================
-- <localleader>j: Jump to YAML path
-- =============================================================================
vim.keymap.set("n", "<localleader>j", function()
    local buf = vim.api.nvim_get_current_buf()

    -- guard against malformed YAML crashing the picker
    local tree = vim.treesitter.get_parser(buf, "yaml"):parse()[1]
    if not tree then
        vim.notify("Could not parse YAML", vim.log.levels.WARN)
        return
    end

    ---@type { label: string, lnum: integer, col: integer }[]
    local paths = {}
    walk_yaml_paths(buf, tree:root(), "", paths)

    if vim.tbl_isempty(paths) then
        vim.notify("No YAML paths found", vim.log.levels.INFO)
        return
    end

    -- show a flat list of all paths; user picks one to jump to
    vim.ui.select(paths, {
        prompt      = "Select YAML path:",
        format_item = function(item) return item.label end,
    }, function(choice)
        if not choice then return end
        vim.api.nvim_win_set_cursor(0, { choice.lnum, choice.col })
        vim.cmd.normal({ "zz", bang = true }) -- center the screen on the line
    end)
end, { buffer = true, desc = "Jump to YAML path" })
