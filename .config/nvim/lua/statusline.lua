-- =================================================================
-- Statusline: shows the current mode, filename, diagnostics,
-- filetype, and cursor position
-- =================================================================

-- build a custom highlight for the mode label by reusing colors
-- that already exist in the current colorscheme; re-derived on every
-- ColorScheme, since this file loads before plugin/ sets the colorscheme
local function set_mode_hl()
    local pms = vim.api.nvim_get_hl(0, { name = "PmenuSel", link = false })
    local vis = vim.api.nvim_get_hl(0, { name = "Visual", link = false })
    vim.api.nvim_set_hl(0, "StlMode", { fg = pms.fg, bg = vis.bg })
end
set_mode_hl()
vim.api.nvim_create_autocmd("ColorScheme", { callback = set_mode_hl })

-- maps Neovim's internal mode codes to readable labels
local modes = {
    n = "NORMAL",
    i = "INSERT",
    v = "VISUAL",
    V = "V-LINE",
    ["\22"] = "V-BLOCK",
    c = "COMMAND",
    t = "TERMINAL",
    R = "REPLACE",
    s = "SELECT",
    S = "S-LINE",
    ["\19"] = "S-BLOCK",
}

-- this function builds the statusline text; it's called every time
-- the statusline needs to redraw (see 'statusline' option at the bottom)
---@return string
function _G._statusline()
    -- look up a friendly name for the current mode, or just show
    -- whatever Neovim reports if it's not in our table
    local mode = modes[vim.fn.mode()] or vim.fn.mode():upper()

    -- build the diagnostics section (error/warning/info/hint counts)
    local diag = ""
    local counts = vim.diagnostic.count(0) or {}
    local labels = { " ", " ", " ", " " } -- one icon per severity
    local hls = { "DiagnosticError", "DiagnosticWarn", "DiagnosticInfo", "DiagnosticHint" }
    for i = 1, 4 do
        if counts[i] and counts[i] > 0 then
            diag = diag .. "%#" .. hls[i] .. "#" .. labels[i] .. counts[i] .. "%* "
        end
    end

    -- %f = filename, %= = split point (left vs right side),
    -- %l:%c = line:column of the cursor
    return "%#StlMode# " .. mode .. " %* %f%=" .. diag .. vim.bo.filetype .. " %l:%c"
end

-- diagnostics can change without moving the cursor (e.g. LSP finishes
-- linting in the background), so redraw the statusline whenever that happens
vim.api.nvim_create_autocmd("DiagnosticChanged", {
    callback = function()
        vim.cmd("redrawstatus!")
    end,
})

-- tell Neovim to use our function to build the statusline
vim.o.statusline = "%!v:lua._statusline()"
