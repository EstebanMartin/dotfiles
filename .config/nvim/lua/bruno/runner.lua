-- Wraps `bru run`: spawn async, read the JSON result file, normalize it.
local M = {}

local MAX_BYTES = 1024 * 1024

---@param path string
---@return table?
local function read_result(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    -- luanil: JSON null must become nil, not the truthy vim.NIL
    local ok, d = pcall(vim.json.decode, s, { luanil = { object = true, array = true } })
    if not ok or type(d) ~= "table" then return nil end
    local it = d[1]
    return it and it.results and it.results[1] or nil
end

---@param ct string?
---@param data any
---@return string
local function filetype_for(ct, data)
    ct = (ct or ""):lower()
    if ct:find("json", 1, true) or type(data) == "table" then return "json" end
    if ct:find("html", 1, true) then return "html" end
    if ct:find("xml", 1, true) then return "xml" end
    if ct:find("javascript", 1, true) then return "javascript" end
    if ct:find("css", 1, true) then return "css" end
    return "text"
end

local function header(headers, name)
    for k, v in pairs(headers or {}) do
        if k:lower() == name then return v end
    end
end

---@param r table raw bru result entry
---@param pretty string? jq-pretty-printed body (keeps key order; without jq, keys come out unordered)
local function normalize(r, pretty)
    local res = r.response or {}
    local ct = header(res.headers, "content-type")
    local ok = type(res.status) == "number"
    local body
    local lct = (ct or ""):lower()
    local binary = lct:match("^%s*image/") or lct:match("^%s*audio/") or lct:match("^%s*video/")
        or lct:match("octet%-stream") or lct:match("pdf")
    if r.error then
        body = tostring(r.error)
    elseif binary then
        body = ("[binary, %s bytes, %s]"):format(tostring(res.size or "?"), ct)
    elseif type(res.data) == "table" then
        body = pretty or vim.json.encode(res.data, { indent = "  " })
    elseif res.data ~= nil then
        body = tostring(res.data)
    else
        body = ""
    end
    local truncated = #body > MAX_BYTES
    if truncated then body = body:sub(1, MAX_BYTES) end

    local tests = {}
    for _, key in ipairs({ "preRequestTestResults", "testResults", "postResponseTestResults" }) do
        for _, t in ipairs(r[key] or {}) do
            tests[#tests + 1] = { name = t.description, status = t.status, error = t.error }
        end
    end
    for _, a in ipairs(r.assertionResults or {}) do
        tests[#tests + 1] = {
            name = ("%s %s"):format(a.lhsExpr, a.rhsExpr), status = a.status, error = a.error,
        }
    end

    return {
        name = r.name,
        method = r.request and r.request.method or "?",
        url = r.request and r.request.url or "",
        req_headers = r.request and r.request.headers or {},
        req_body = r.request and r.request.data,
        status = ok and res.status or nil,
        status_text = res.statusText,
        time = ok and res.responseTime or nil,
        size = ok and res.size or nil,
        error = r.error and tostring(r.error) or nil,
        headers = res.headers or {},
        content_type = ct,
        body = body,
        truncated = truncated,
        ft = r.error and "text" or filetype_for(ct, res.data),
        tests = tests,
    }
end

---@param file string absolute path to the .bru file
---@param root string collection root (cwd for bru)
---@param env string?
---@param vars table<string,string>? extra env vars (secrets), passed as --env-var
---@param cb fun(result: table?, err: string?)
---@return vim.SystemObj?
function M.run(file, root, env, vars, cb)
    if vim.fn.executable("bru") == 0 then
        return cb(nil, "`bru` not found in PATH")
    end
    local out = vim.fn.tempname() .. ".json"
    local cmd = { "bru", "run", file, "-o", out }
    if env then vim.list_extend(cmd, { "--env", env }) end
    for k, v in pairs(vars or {}) do vim.list_extend(cmd, { "--env-var", k .. "=" .. v }) end

    return vim.system(cmd, { cwd = root, text = true }, function(proc)
        -- callback runs in a fast-event context
        vim.schedule(function()
            -- bru exits 1 on failed assertions / connection errors but still
            -- writes the file: render whenever a result exists.
            local r = read_result(out)
            if not r then
                os.remove(out)
                local msg = vim.trim((proc.stderr or "") .. (proc.stdout or ""))
                return cb(nil, msg ~= "" and msg or "bru produced no result")
            end
            if not (r.response and type(r.response.data) == "table" and vim.fn.executable("jq") == 1) then
                os.remove(out)
                return cb(normalize(r))
            end
            -- pretty-print in the background: large bodies would block the editor
            vim.system({ "jq", "--indent", "2", ".[0].results[0].response.data", out }, { text = true }, function(j)
                vim.schedule(function()
                    os.remove(out)
                    cb(normalize(r, j.code == 0 and (j.stdout:gsub("\n$", "")) or nil))
                end)
            end)
        end)
    end)
end

return M
