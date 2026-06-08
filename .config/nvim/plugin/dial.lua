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

            -- Logical & comparison
            augend.constant.alias.bool,
            augend.constant.new({
                elements = { "and", "or" },
                word = true,
                cyclic = true,
            }),
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

            -- Versions
            augend.semver.alias.semver,
        },
    })

    -- Lua-specific augends
    dial.augends:on_filetype({
        lua = vim.list_extend(
            { augend.constant.new({
                elements = { "==", "~=" },
                word = false,
                cyclic = true,
            }) },
            dial.augends:get("default")
        ),
    })
end)

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
