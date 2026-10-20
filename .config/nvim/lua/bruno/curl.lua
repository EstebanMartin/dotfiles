-- Build a curl command from a normalized result.
local M = {}

-- headers added by bru's HTTP client, not by the request definition
local SKIP = { host = true, connection = true, ["content-length"] = true, ["accept-encoding"] = true, ["user-agent"] = true }

---@param r table
---@return string
function M.build(r)
    local parts = { "curl", "-X", r.method, vim.fn.shellescape(r.url) }
    local names = vim.tbl_keys(r.req_headers)
    table.sort(names)
    for _, k in ipairs(names) do
        local v = r.req_headers[k]
        if v ~= nil and not SKIP[k:lower()] then
            for _, item in ipairs(type(v) == "table" and v or { v }) do
                parts[#parts + 1] = "-H"
                parts[#parts + 1] = vim.fn.shellescape(("%s: %s"):format(k, tostring(item)))
            end
        end
    end
    local body = r.req_body
    if type(body) == "table" then body = vim.json.encode(body) end
    if body ~= nil and body ~= "" then
        parts[#parts + 1] = "--data-raw"
        parts[#parts + 1] = vim.fn.shellescape(tostring(body))
    end
    return table.concat(parts, " ")
end

-- Content-Type implied by the .bru body mode (static curls only)
local CONTENT_TYPE = {
    json = "application/json",
    xml = "application/xml",
    text = "text/plain",
    sparql = "application/sparql-query",
    formUrlEncoded = "application/x-www-form-urlencoded",
}

---Basic curl from the statically resolved request: method, URL and body only.
---@param method string
---@param url string
---@param body string?
---@param mode string? .bru body mode
---@return string
function M.build_static(method, url, body, mode)
    local parts = { "curl", "-X", method, vim.fn.shellescape(url) }
    if body ~= nil and body ~= "" then
        local ct = CONTENT_TYPE[mode or ""]
        if ct then
            parts[#parts + 1] = "-H"
            parts[#parts + 1] = vim.fn.shellescape("Content-Type: " .. ct)
        end
        parts[#parts + 1] = "--data-raw"
        parts[#parts + 1] = vim.fn.shellescape(body)
    end
    return table.concat(parts, " ")
end

return M
