-- `bru run` one request and turn its JSON report into what the response window shows.
local M = {}

local MAX_BYTES = 1024 * 1024

-- response window filetype by content type; JSON bodies (decoded tables) are always json
local FILETYPES = { json = "json", html = "html", xml = "xml", javascript = "javascript", css = "css" }

---@param file string absolute path to the request
---@param root string collection root (cwd for bru)
---@param env string?
---@param vars table<string,string> secrets, passed as --env-var
---@param system fun(cmd: string[], opts: table?): vim.SystemCompleted waits inside the run coroutine
---@return table? result, string? err
function M.run(file, root, env, vars, system)
    if vim.fn.executable("bru") == 0 then return nil, "`bru` not found in PATH" end
    local out = vim.fn.tempname() .. ".json"
    -- a collection-relative path: that is how bru names the request in its report
    local cmd = { "bru", "run", vim.fs.relpath(root, file) or file, "--reporter-json", out }
    if env then vim.list_extend(cmd, { "--env", env }) end
    for k, v in pairs(vars) do vim.list_extend(cmd, { "--env-var", k .. "=" .. v }) end
    local proc = system(cmd, { cwd = root })

    -- bru exits 1 on failed assertions and connection errors but still writes the report
    -- luanil: JSON null must become nil, not the truthy vim.NIL
    local ok, report = pcall(function()
        return vim.json.decode(vim.fn.readblob(out), { luanil = { object = true, array = true } })
    end)
    local r = ok and report[1] and report[1].results and report[1].results[1]
    if not r then
        os.remove(out)
        local msg = vim.trim((proc.stderr or "") .. (proc.stdout or ""))
        return nil, "bru failed:\n" .. (msg ~= "" and msg or "no result")
    end

    local req, res = r.request or {}, r.response or {}
    local ct
    for k, v in pairs(res.headers or {}) do
        if k:lower() == "content-type" then ct = v end
    end
    local lct = (ct or ""):lower()

    local body = ""
    if r.error then
        body = tostring(r.error)
    elseif lct:match("^%s*image/") or lct:match("^%s*audio/") or lct:match("^%s*video/")
        or lct:find("octet-stream", 1, true) or lct:find("pdf", 1, true) then
        body = ("[binary, %s bytes, %s]"):format(tostring(res.size or "?"), ct)
    elseif type(res.data) == "table" then
        -- jq keeps the key order of the response; vim.json.encode would not
        local jq = vim.fn.executable("jq") == 1 and system({ "jq", "--indent", "2", ".[0].results[0].response.data", out })
        body = jq and jq.code == 0 and jq.stdout:gsub("\n$", "") or vim.json.encode(res.data, { indent = "  " })
    elseif res.data ~= nil then
        body = tostring(res.data)
    end
    os.remove(out)

    local ft = type(res.data) == "table" and "json" or "text"
    for key, value in pairs(FILETYPES) do
        if lct:find(key, 1, true) then ft = value end
    end

    local tests = {}
    for _, key in ipairs({ "preRequestTestResults", "testResults", "postResponseTestResults" }) do
        for _, t in ipairs(r[key] or {}) do
            tests[#tests + 1] = { name = t.description, status = t.status, error = t.error }
        end
    end
    for _, a in ipairs(r.assertionResults or {}) do
        tests[#tests + 1] = { name = a.lhsExpr .. " " .. a.rhsExpr, status = a.status, error = a.error }
    end

    local got_response = type(res.status) == "number"
    return {
        method = (req.method or "?"):upper(),
        url = req.url or "",
        req_headers = req.headers or {},
        req_body = req.data,
        status = got_response and res.status or nil,
        status_text = res.statusText,
        time = got_response and res.responseTime or nil,
        size = got_response and res.size or nil,
        error = r.error and tostring(r.error) or nil,
        headers = res.headers or {},
        content_type = ct,
        body = body:sub(1, MAX_BYTES),
        truncated = #body > MAX_BYTES,
        ft = r.error and "text" or ft,
        tests = tests,
    }
end

return M
