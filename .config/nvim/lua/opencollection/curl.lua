-- curl commands for :OcCurl.
local M = {}

-- headers added by bru's HTTP client, not by the request definition
local SKIP = { host = true, connection = true, ["content-length"] = true, ["accept-encoding"] = true, ["user-agent"] = true }

-- Content-Type implied by the body type (static curls only)
local CONTENT_TYPE = {
    json = "application/json",
    xml = "application/xml",
    text = "text/plain",
    sparql = "application/sparql-query",
    graphql = "application/json",
    ["form-urlencoded"] = "application/x-www-form-urlencoded",
}

---The request exactly as the last run sent it.
---@param r table run result
---@return string
function M.from_result(r)
    local parts = { "curl", "-X", r.method, vim.fn.shellescape(r.url) }
    local names = vim.tbl_keys(r.req_headers)
    table.sort(names)
    for _, k in ipairs(names) do
        local v = r.req_headers[k]
        if not SKIP[k:lower()] then
            for _, item in ipairs(type(v) == "table" and v or { v }) do
                vim.list_extend(parts, { "-H", vim.fn.shellescape(k .. ": " .. tostring(item)) })
            end
        end
    end
    local body = type(r.req_body) == "table" and vim.json.encode(r.req_body) or r.req_body
    if body ~= nil and body ~= "" then vim.list_extend(parts, { "--data-raw", vim.fn.shellescape(tostring(body)) }) end
    return table.concat(parts, " ")
end

---A basic curl from the statically built request: method, URL and body only.
---@param req table request.build() result
---@return string
function M.from_request(req)
    local parts = { "curl", "-X", req.method, vim.fn.shellescape(req.url) }
    if req.body and req.body ~= "" then
        if CONTENT_TYPE[req.mode] then vim.list_extend(parts, { "-H", vim.fn.shellescape("Content-Type: " .. CONTENT_TYPE[req.mode]) }) end
        vim.list_extend(parts, { "--data-raw", vim.fn.shellescape(req.body) })
    end
    return table.concat(parts, " ")
end

return M
