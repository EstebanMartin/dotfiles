-- =============================================================================
-- _G._yaml_path: build jq-style path from node under cursor (on-demand,
-- fast regardless of file size since it only walks up from the cursor)
-- =============================================================================
---@param node TSNode? defaults to the node under the cursor
---@return string path jq-style path to the node, "" if none
function _G._yaml_path(node)
    local buf = vim.api.nvim_get_current_buf()
    local parser = vim.treesitter.get_parser(buf, "yaml")
    -- get_node only reads parsed trees, so parse first
    if not parser or not parser:parse()[1] then return "" end -- malformed/empty YAML has no tree
    node = node or vim.treesitter.get_node({ lang = "yaml" })

    -- walk up to the root, inserting each piece at the front
    local path = {}
    while node do
        local parent = node:parent()
        if node:type() == "block_mapping_pair" then
            local key = node:field("key")[1]
            if key then
                local text = vim.treesitter.get_node_text(key, buf):gsub('^["\']?(.-)["\']?$', "%1")
                table.insert(path, 1, "." .. text)
            end
        elseif node:type() == "block_sequence_item" then
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
-- Winbar: show the current yaml path as the cursor moves
-- =============================================================================
-- Setting it evaluates the expression immediately, which parses the whole
-- buffer; defer so that doesn't block startup on large files.
local win, win_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
vim.schedule(function()
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == win_buf then
        vim.wo[win].winbar = "%{%v:lua._yaml_path()%}"
    end
end)

-- =============================================================================
-- gO: list every YAML path, pick one, and jump to it
-- =============================================================================
vim.keymap.set("n", "gO", function()
    local root = vim.treesitter.get_parser(0, "yaml"):parse()[1]:root()
    local query = vim.treesitter.query.parse("yaml", "[(block_mapping_pair) @n (block_sequence_item) @n]")
    local paths = {}
    for _, node in query:iter_captures(root, 0) do
        paths[#paths + 1] = { label = _yaml_path(node), lnum = node:range() + 1 }
    end
    vim.ui.select(paths, {
        prompt      = "Select YAML path:",
        format_item = function(item) return item.label end,
    }, function(choice)
        if not choice then return end
        vim.api.nvim_win_set_cursor(0, { choice.lnum, 0 })
        vim.cmd.normal({ "zz", bang = true })
    end)
end, { buffer = true, desc = "Jump to YAML path" })

-- =============================================================================
-- <localleader>y: copy the yaml path under the cursor to the clipboard
-- =============================================================================
vim.keymap.set("n", "<localleader>y",
    function()
        local path = _yaml_path()
        if path == "" then
            vim.notify("No YAML path at cursor", vim.log.levels.WARN)
            return
        end
        vim.fn.setreg("+", path)
        vim.notify("Copied: " .. path)
    end,
    { buffer = true, desc = "Copy YAML path" }
)
