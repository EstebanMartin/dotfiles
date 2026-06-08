-- =============================================================================
-- Options
-- =============================================================================

-- use fixjson as the external formatter (invoked by gq)
vim.opt_local.formatprg = "fixjson"

-- =============================================================================
-- Format JSON on save
-- =============================================================================
local json_group = vim.api.nvim_create_augroup("my.json", { clear = true })

vim.api.nvim_create_autocmd("BufWritePre", {
    group    = json_group,
    buffer   = vim.api.nvim_get_current_buf(),
    desc     = "Format JSON before save",
    callback = function()
        local view = vim.fn.winsaveview()        -- save cursor/scroll position
        vim.cmd.normal({ "gggqG", bang = true }) -- format entire buffer via formatprg
        vim.fn.winrestview(view)                 -- restore position after format
    end,
})


-- =============================================================================
-- get_jq_path_under_cursor: build jq-style path from node under cursor
-- =============================================================================
---@return string
local function get_jq_path_under_cursor()
    local buf = vim.api.nvim_get_current_buf()
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    row = row - 1 -- nvim_win_get_cursor is 1-based; treesitter is 0-based

    -- parse the buffer and find the smallest node covering the cursor position
    local parser = vim.treesitter.get_parser(buf, "json")
    if not parser then
        vim.notify("treesitter parser for json not available", vim.log.levels.ERROR)
        return ""
    end

    local tree = parser:parse()[1]
    if not tree then return "" end -- guard against malformed/empty JSON

    local node = tree:root():named_descendant_for_range(row, col, row, col)
    local path = {}

    -- walk up the tree, collecting key names and array indices
    while node do
        local parent = node:parent()

        if node:type() == "pair" then
            -- extract the key string, stripping surrounding quotes
            local key = node:field("key")[1]
            if key then
                local key_text =
                    vim.treesitter.get_node_text(key, buf)
                    :gsub('^"(.-)"$', "%1")
                table.insert(path, 1, "." .. key_text)
            end
        elseif parent and parent:type() == "array" then
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
-- walk_json_paths: collect all paths for the jump picker
-- =============================================================================
---@param buf integer
---@param node any
---@param path string
---@param paths table
local function walk_json_paths(buf, node, path, paths)
    local t = node:type()

    if t == "pair" then
        local key   = node:field("key")[1]
        local value = node:field("value")[1]
        if key and value then
            -- strip quotes from key text to build a clean jq path
            local key_text =
                vim.treesitter.get_node_text(key, buf)
                :gsub('^"(.-)"$', "%1")
            local new_path = path .. "." .. key_text
            local row, col = key:range() -- 0-based; add 1 for nvim cursor API
            table.insert(paths, {
                label = new_path,
                lnum  = row + 1,
                col   = col + 1,
            })
            walk_json_paths(buf, value, new_path, paths)
        end
    elseif t == "object" or t == "document" then
        -- recurse into all children of objects and the root document
        for child in node:iter_children() do
            walk_json_paths(buf, child, path, paths)
        end
    elseif t == "array" then
        -- track index manually since treesitter iterates all tokens (inc. commas)
        local i = 0
        for child in node:iter_children() do
            if child:named() then
                local new_path = path .. ("[%d]"):format(i)
                local row, col = child:range()
                table.insert(paths, {
                    label = new_path,
                    lnum  = row + 1,
                    col   = col + 1,
                })
                walk_json_paths(buf, child, new_path, paths)
                i = i + 1
            end
        end
    end
end

-- =============================================================================
-- Show jq path in winbar
-- =============================================================================
if vim.fn.exists("+winbar") == 1 then
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group    = json_group,
        buffer   = vim.api.nvim_get_current_buf(),
        desc     = "Show jq path in winbar",
        callback = function()
            -- pcall guards against parse errors in malformed JSON
            local ok, path = pcall(get_jq_path_under_cursor)
            vim.opt_local.winbar = ok and path or ""
        end,
    })
end

-- =============================================================================
-- <localleader>c: Copy JSON path
-- =============================================================================
vim.keymap.set("n", "<localleader>c", function()
    local path = get_jq_path_under_cursor()
    if path == "" then
        vim.notify("No path found under cursor", vim.log.levels.WARN)
        return
    end
    vim.fn.setreg("+", path) -- "+" is the system clipboard register
    vim.notify("Copied path: " .. path, vim.log.levels.INFO)
end, { buffer = true, desc = "Copy JSON path" })

-- =============================================================================
-- <localleader>f: Fix loose JSON
-- =============================================================================
vim.keymap.set("n", "<localleader>f", function()
    if vim.fn.executable("fixjson") == 0 then
        vim.notify("fixjson not found", vim.log.levels.ERROR)
        return
    end

    local bufnr  = vim.api.nvim_get_current_buf()
    local view   = vim.fn.winsaveview()
    local input  = table.concat(
        vim.api.nvim_buf_get_lines(bufnr, 0, -1, false --[[@as boolean]]), "\n"
    )
    -- collapse newlines between non-whitespace chars to fix loose JSON that
    -- spans multiple lines illegally (e.g. unquoted line breaks in strings)
    -- note: this could mangle valid JSON with intentional newlines in strings,
    -- but fixjson targets broken JSON where this trade-off is acceptable
    input        = input:gsub("(%S)\n(%S)", "%1%2")

    local result = vim.system(
        { "fixjson" },
        { stdin = input, text = true }
    ):wait()

    if result.code ~= 0 or not result.stdout or result.stdout == "" then
        vim.notify(
            result.stderr ~= "" and result.stderr or "fixjson failed",
            vim.log.levels.ERROR
        )
        return
    end

    -- optionally run through jq for validation + canonical formatting
    if vim.fn.executable("jq") == 1 then
        local validate = vim.system(
            { "jq", "." },
            { stdin = result.stdout, text = true }
        ):wait()
        if validate.code ~= 0 then
            vim.notify(
                validate.stderr ~= "" and validate.stderr or "Invalid JSON",
                vim.log.levels.ERROR
            )
            return
        end
        result.stdout = validate.stdout -- use jq's pretty-printed output
    end

    local lines = vim.split(
        result.stdout, "\n", { plain = true, trimempty = true }
    )
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.fn.winrestview(view) -- restore cursor after replacing buffer content
    vim.notify("JSON fixed", vim.log.levels.INFO)
end, { buffer = true, desc = "Fix loose JSON" })

-- =============================================================================
-- <localleader>j: Jump to JSON path
-- =============================================================================
vim.keymap.set("n", "<localleader>j", function()
    local buf    = vim.api.nvim_get_current_buf()
    local parser = vim.treesitter.get_parser(buf, "json")
    if not parser then
        vim.notify("No JSON parser available", vim.log.levels.WARN)
        return
    end
    local root = parser:parse()[1]:root()
    local paths = {}

    walk_json_paths(buf, root, "", paths)

    if vim.tbl_isempty(paths) then
        vim.notify("No JSON paths found", vim.log.levels.INFO)
        return
    end

    -- show a flat list of all paths; user picks one to jump to
    vim.ui.select(paths, {
        prompt      = "Select JSON path:",
        format_item = function(item) return item.label end,
    }, function(choice)
        if not choice then return end
        vim.api.nvim_win_set_cursor(0, { choice.lnum, choice.col })
        vim.cmd.normal({ "zz", bang = true }) -- center the screen on the line
    end)
end, { buffer = true, desc = "Jump to JSON path" })
