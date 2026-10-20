vim.schedule(function()
    vim.pack.add({
        { src = "https://github.com/monaqa/dial.nvim" },
    })

    local dial = require("dial.config")
    local augend = require("dial.augend")

    dial.augends:register_group({
        default = {
            -- Numbers
            augend.integer.alias.decimal_int,

            -- Dates
            augend.date.alias["%Y/%m/%d"],
            augend.date.alias["%Y-%m-%d"],

            -- Time
            augend.date.alias["%H:%M:%S"],
            augend.date.alias["%H:%M"],

            -- Weekdays
            augend.constant.new({
                elements = {
                    "Monday", "Tuesday", "Wednesday",
                    "Thursday", "Friday", "Saturday", "Sunday" },
                word = true,
                cyclic = true,
            }),

            -- Months
            augend.constant.new({
                elements = {
                    "January", "February", "March",
                    "April", "May", "June", "July",
                    "August", "September", "October",
                    "November", "December",
                },
                word = true,
                cyclic = true,
            }),
            augend.constant.new({
                elements = {
                    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" },
                word = true,
                cyclic = true,
            }),

            -- Logical (words only; symbolic operators live in the "operators"
            -- group below, so <C-a> before `x > 5` increments 5, not flips >)
            augend.constant.alias.bool,
            augend.constant.new({
                elements = { "and", "or" },
                word = true,
                cyclic = true,
            }),

            -- Versions
            augend.semver.alias.semver,
        },
    })

    -- Operators: only via g<C-a>/g<C-x>, so they never shadow a number
    -- later on the line
    dial.augends:register_group({
        operators = {
            augend.constant.new({
                elements = { "&&", "||" },
                word = false,
                cyclic = true,
            }),
            augend.constant.new({
                elements = { "==", "!=" },
                word = false,
                cyclic = true,
            }),
            augend.constant.new({
                elements = { "<", ">" },
                word = false,
                cyclic = true,
            }),
            augend.constant.new({
                elements = { "<=", ">=" },
                word = false,
                cyclic = true,
            }),
            augend.constant.new({
                elements = { "===", "!==" },
                word = false,
                cyclic = true,
            }),
        },
    })

    -- Lua spells "not equal" ~=, so it gets its own operators group
    local operators_lua = vim.list_extend(
        { augend.constant.new({
            elements = { "==", "~=" },
            word = false,
            cyclic = true,
        }) },
        dial.augends:get("operators")
    )
    dial.augends:register_group({ operators_lua = operators_lua })
end)

---@return string dial group for the current buffer's operators
local function operators_group()
    return vim.bo.filetype == "lua" and "operators_lua" or "operators"
end

-->> <C-a>: Dial increment {{{
vim.keymap.set("n", "<C-a>",
    function()
        require("dial.map").manipulate("increment", "normal")
    end,
    { desc = "Dial increment" }
)

vim.keymap.set("x", "<C-a>",
    function()
        require("dial.map").manipulate("increment", "visual")
    end,
    { desc = "Dial increment (visual)" }
)

-->> <C-x>: Dial decrement {{{
vim.keymap.set("n", "<C-x>",
    function()
        require("dial.map").manipulate("decrement", "normal")
    end,
    { desc = "Dial decrement" }
)

vim.keymap.set("x", "<C-x>",
    function()
        require("dial.map").manipulate("decrement", "visual")
    end,
    { desc = "Dial decrement (visual)" }
)

-->> g<C-a> / g<C-x>: Dial operators (==/!=, </>, &&/||, ...) {{{
vim.keymap.set("n", "g<C-a>",
    function()
        require("dial.map").manipulate("increment", "normal", operators_group())
    end,
    { desc = "Dial operator forward" }
)

vim.keymap.set("n", "g<C-x>",
    function()
        require("dial.map").manipulate("decrement", "normal", operators_group())
    end,
    { desc = "Dial operator backward" }
)
