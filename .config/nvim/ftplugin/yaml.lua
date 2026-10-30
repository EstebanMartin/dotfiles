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
-- Ghost text: show the yaml path at the end of the cursor line
-- =============================================================================
-- One group per buffer, cleared on each run, so re-running this ftplugin
-- (:e) replaces the autocmd instead of stacking another.
local ns = vim.api.nvim_create_namespace("yaml_path")
vim.api.nvim_create_autocmd("CursorMoved", {
    group = vim.api.nvim_create_augroup("yaml_path_" .. vim.api.nvim_get_current_buf(), { clear = true }),
    buffer = 0,
    callback = function()
        vim.api.nvim_buf_clear_namespace(0, ns, 0, -1)
        local path = _yaml_path()
        if path ~= "" then
            vim.api.nvim_buf_set_extmark(0, ns, vim.fn.line(".") - 1, 0, { virt_text = { { path, "Comment" } } })
        end
    end,
})

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
