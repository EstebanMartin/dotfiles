-- =============================================================================
-- _G._json_path: build jq-style path from node under cursor (on-demand,
-- fast regardless of file size since it only walks up from the cursor)
-- =============================================================================
---@param node TSNode? defaults to the node under the cursor
---@return string path jq-style path to the node, "" if none
function _G._json_path(node)
    local buf = vim.api.nvim_get_current_buf()
    local parser = vim.treesitter.get_parser(buf, "json")
    -- get_node only reads parsed trees, so parse first
    if not parser or not parser:parse()[1] then return "" end -- malformed/empty JSON has no tree
    node = node or vim.treesitter.get_node({ lang = "json" })

    -- walk up to the root, inserting each piece at the front
    local path = {}
    while node do
        local parent = node:parent()
        if node:type() == "pair" then
            local key = node:field("key")[1]
            if key then
                local text = vim.treesitter.get_node_text(key, buf):gsub('^"(.-)"$', "%1")
                table.insert(path, 1, "." .. text)
            end
        elseif parent and parent:type() == "array" then
            -- index = number of named siblings before it
            local index, sibling = 0, node:prev_named_sibling()
            while sibling do
                index, sibling = index + 1, sibling:prev_named_sibling()
            end
            table.insert(path, 1, ("[%d]"):format(index))
        end
        node = parent
    end

    return table.concat(path)
end

-- =============================================================================
-- Winbar: show the current jq path as the cursor moves
-- =============================================================================
vim.wo.winbar = "%{%v:lua._json_path()%}"

-- =============================================================================
-- gO: list every JSON path, pick one, and jump to it
-- =============================================================================
vim.keymap.set("n", "gO", function()
    local root = vim.treesitter.get_parser(0, "json"):parse()[1]:root()
    local query = vim.treesitter.query.parse("json", "[(pair) @n (array (_) @n)]")
    local paths = {}
    for _, node in query:iter_captures(root, 0) do
        paths[#paths + 1] = { label = _json_path(node), lnum = node:range() + 1 }
    end
    vim.ui.select(paths, {
        prompt      = "Select JSON path:",
        format_item = function(item) return item.label end,
    }, function(choice)
        if not choice then return end
        vim.api.nvim_win_set_cursor(0, { choice.lnum, 0 })
        vim.cmd.normal({ "zz", bang = true })
    end)
end, { buffer = true, desc = "Jump to JSON path" })

-- =============================================================================
-- <localleader>y: copy the jq path under the cursor to the clipboard
-- =============================================================================
vim.keymap.set("n", "<localleader>y",
    function()
        local path = _json_path()
        if path == "" then
            vim.notify("No JSON path at cursor", vim.log.levels.WARN)
            return
        end
        vim.fn.setreg("+", path)
        vim.notify("Copied: " .. path)
    end,
    { buffer = true, desc = "Copy JSON path" }
)


-- =============================================================================
-- <localleader>=: Fix loose JSON
-- =============================================================================
vim.keymap.set("n", "<localleader>=",
    function()
        -- fixjson does the actual repair work; bail out if it's missing
        if vim.fn.executable("fixjson") == 0 then
            vim.notify("fixjson not found", vim.log.levels.ERROR)
            return
        end

        local bufnr = vim.api.nvim_get_current_buf()
        local view = vim.fn.winsaveview() -- remember cursor/scroll position
        local input = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")

        -- terminals often hard-wrap copied JSON mid-token; join lines back
        -- together to undo that before fixjson runs
        input = input:gsub("(%S)\n(%S)", "%1%2")

        -- run fixjson on the buffer's text via stdin
        local result = vim.system({ "fixjson" }, { stdin = input, text = true }):wait()
        if result.code ~= 0 or result.stdout == "" then
            vim.notify(result.stderr ~= "" and result.stderr or "fixjson failed", vim.log.levels.ERROR)
            return
        end

        -- replace the buffer's content with the fixed JSON
        local lines = vim.split(result.stdout, "\n", { plain = true, trimempty = true })
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.fn.winrestview(view) -- restore cursor/scroll position
        vim.notify("JSON fixed", vim.log.levels.INFO)
    end,
    { buffer = true, desc = "Fix loose JSON" }
)
