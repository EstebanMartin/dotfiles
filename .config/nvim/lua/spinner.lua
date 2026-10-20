-- lua/spinner.lua
local M = {}

-- braille-dot animation frames, cycled one per tick
local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- Low-level: drives the frame animation on a timer, calling on_frame(frame)
-- each tick. popup() and winbar() below build on this; on_frame decides how
-- to render a frame.
---@param on_frame fun(frame: string)
---@return { stop: fun() }
local function animate(on_frame)
    -- ticks every 80ms, advancing the animation one frame at a time
    local timer = assert(vim.uv.new_timer())
    local i = 0
    timer:start(0, 80, vim.schedule_wrap(function()
        i = (i % #spinner_frames) + 1
        on_frame(spinner_frames[i])
    end))
    return {
        stop = function()
            timer:stop()
            timer:close()
        end,
    }
end

-- Floating spinner in the bottom-right corner, showing `msg` next to the
-- animated frame. Use for one-off background tasks with no better place
-- to show progress.
---@param msg string
---@return { stop: fun() }
function M.popup(msg)
    -- scratch buffer to hold the spinner's text
    local buf = vim.api.nvim_create_buf(false, true)
    local width = #msg + 3

    -- floating window positioned in the bottom-right corner
    local win = vim.api.nvim_open_win(buf, false, {
        relative = "editor",
        width = width,
        height = 1,
        row = vim.o.lines - 3,
        col = vim.o.columns - width - 2,
        style = "minimal",
        border = "none",
        focusable = false, -- don't let the cursor land in it
    })

    local anim = animate(function(frame)
        -- buffer may have been closed already; bail out if so
        if not vim.api.nvim_buf_is_valid(buf) then return end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { frame .. " " .. msg })
    end)

    return {
        stop = function()
            anim.stop()
            if vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_close(win, true)
            end
        end,
    }
end

-- Winbar-embeddable spinner: animates in the background and calls
-- redrawstatus so a %{} expression can pick up the current frame via
-- :frame(). Caller is responsible for putting :frame() into their own
-- winbar string and for the buffer/filetype checks that decide when to
-- show it at all — this only owns the animation.
---@return { frame: fun(): string, stop: fun() }
function M.winbar()
    -- holds whatever frame the timer last set; :frame() just reads it
    local current = spinner_frames[1]

    -- redrawstatus is refused while the cmdline is active, hence the pcall
    local function redraw()
        pcall(vim.cmd.redrawstatus, { bang = true })
    end

    local anim = animate(function(frame)
        current = frame
        redraw() -- force the winbar to re-evaluate with the new frame
    end)

    return {
        frame = function() return current end,
        stop = anim.stop,
    }
end

return M
