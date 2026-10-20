-- =============================================================================
-- _G._yaml_path: build jq-style path from node under cursor (on-demand,
-- fast regardless of file size since it only walks up from the cursor)
-- =============================================================================
---@return string path jq-style path to the node under the cursor, "" if none
function _G._yaml_path()
    local buf = vim.api.nvim_get_current_buf()
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    row = row - 1 -- nvim_win_get_cursor is 1-based; treesitter is 0-based

    local parser = vim.treesitter.get_parser(buf, "yaml")
    if not parser then return "" end

    local tree = parser:parse()[1]
    if not tree then return "" end -- malformed/empty YAML has no tree

    -- find the smallest node in the syntax tree that covers the cursor
    local node = tree:root():named_descendant_for_range(row, col, row, col)

    -- walk up from the cursor's node to the root, building the path
    -- one piece at a time (we build it backwards, so each new piece
    -- gets inserted at the front)
    local path = {}
    while node do
        local parent = node:parent()

        if node:type() == "block_mapping_pair" then
            -- this node is a "key: value" entry; grab the key's text
            local key_node = node:field("key")[1]
            if key_node then
                local key_text = vim.treesitter.get_node_text(key_node, buf)
                    :gsub('^["\']?(.-)["\']?$', "%1") -- strip optional quotes
                table.insert(path, 1, "." .. key_text)
            end
        elseif node:type() == "block_sequence_item" then
            -- this node is an item in a YAML list ("- foo"); count how
            -- many sibling items come before it to get its index
            local index = 0
            if parent then
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
        end

        node = parent
    end

    return table.concat(path)
end

-- =============================================================================
-- Winbar: show the current yaml path as the cursor moves
-- =============================================================================
vim.wo.winbar = "%{%v:lua._yaml_path()%}"

-- =============================================================================
-- gO: build all YAML paths on-demand, pick one, and jump to it
-- =============================================================================
vim.keymap.set("n", "gO",
    function()
        local buf = vim.api.nvim_get_current_buf()
        local parser = vim.treesitter.get_parser(buf, "yaml")
        if not parser then
            vim.notify("treesitter parser for yaml not available", vim.log.levels.ERROR)
            return
        end

        local tree = parser:parse()[1]
        if not tree then
            vim.notify("Failed to parse buffer", vim.log.levels.ERROR)
            return
        end

        -- walk the whole tree once, right now, to collect every path
        local paths = {}

        -- recursively visits every node, building up the path as it goes;
        -- each time it finds a mapping key or a sequence item, it records
        -- that path together with the line it starts on
        ---@param node TSNode
        ---@param path string jq-style path accumulated so far
        local function walk(node, path)
            local seq_index = 0 -- tracks position for sequence items

            for child in node:iter_children() do
                if not child:named() then goto continue end -- skip punctuation nodes

                local child_path = path

                if child:type() == "block_mapping_pair" then
                    -- this child is a "key: value" entry; add ".key" to the path
                    local key_node = child:field("key")[1]
                    if key_node then
                        local key_text = vim.treesitter.get_node_text(key_node, buf)
                            :gsub('^["\']?(.-)["\']?$', "%1") -- strip optional quotes
                        child_path = path .. "." .. key_text
                    end
                    local start_row = child:range()
                    table.insert(paths, { label = child_path, lnum = start_row + 1, col = 0 })
                elseif child:type() == "block_sequence_item" then
                    -- this child is an item in a YAML list; add "[index]" to the path
                    child_path = path .. ("[%d]"):format(seq_index)
                    local start_row = child:range()
                    table.insert(paths, { label = child_path, lnum = start_row + 1, col = 0 })
                    seq_index = seq_index + 1
                end

                -- recurse into this child, carrying its path forward
                walk(child, child_path)
                ::continue::
            end
        end
        walk(tree:root(), "")

        if #paths == 0 then
            vim.notify("No YAML paths found", vim.log.levels.WARN)
            return
        end

        -- sort by line number so the picker reads top-to-bottom, matching
        -- the file's actual structure
        table.sort(paths, function(a, b) return a.lnum < b.lnum end)

        -- show a flat list of all paths; user picks one to jump to
        vim.ui.select(paths, {
            prompt      = "Select YAML path:",
            format_item = function(item) return item.label end,
        }, function(choice)
            if not choice then return end
            vim.api.nvim_win_set_cursor(0, { choice.lnum, choice.col })
            vim.cmd.normal({ "zz", bang = true }) -- center the screen on the line
        end)
    end,
    { buffer = true, desc = "Jump to YAML path" }
)

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
