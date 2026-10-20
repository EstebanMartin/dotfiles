-- =================================================================
-- Statusline: shows the current mode, filename, running tasks,
-- diagnostics, filetype, and cursor position
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

-- braille-dot animation for running tasks, advanced by the timer below
local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local frame = 1
local timer = assert(vim.uv.new_timer())

-- this function builds the statusline text; it's called every time
-- the statusline needs to redraw (see 'statusline' option at the bottom)
---@return string
function _G._statusline()
    -- look up a friendly name for the current mode, or just show
    -- whatever Neovim reports if it's not in our table
    local mode = modes[vim.fn.mode()] or vim.fn.mode():upper()

    -- animated frame while any progress message is running (go test, bru, vim.pack, ...)
    local busy = vim.ui.progress_status() ~= "" and frames[frame] .. " " or ""

    -- error/warning/info/hint counts, e.g. "E:1 W:2", using the sign text
    -- from vim.diagnostic.config(); Neovim redraws the statusline itself
    -- when diagnostics change
    local diag = vim.diagnostic.status()
    if diag ~= "" then diag = diag .. " " end

    -- %f = filename, %= = split point (left vs right side),
    -- %l:%c = line:column of the cursor
    return "%#StlMode# " .. mode .. " %* %f%=" .. busy .. diag .. vim.bo.filetype .. " %l:%c"
end

-- Progress fires when a task starts or finishes: animate only while
-- something is running. Scheduled so vim.ui's own Progress handler has
-- updated its state first. redrawstatus is refused while the cmdline is
-- active, hence the pcalls.
vim.api.nvim_create_autocmd("Progress", {
    callback = vim.schedule_wrap(function()
        if vim.ui.progress_status() == "" then
            timer:stop()
            pcall(vim.cmd.redrawstatus, { bang = true }) -- clear the last frame
        elseif not timer:is_active() then
            timer:start(0, 80, vim.schedule_wrap(function()
                frame = frame % #frames + 1
                pcall(vim.cmd.redrawstatus, { bang = true })
            end))
        end
    end),
})

-- tell Neovim to use our function to build the statusline
vim.o.statusline = "%!v:lua._statusline()"
