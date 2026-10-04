-- Loads customers.json once, caches in the module table (nginx init_by_lua is
-- per-worker, so the load happens once per worker rather than per request).
-- Onboarding = append one line to customers.json + reload. No code change.
local cjson = require("cjson.safe")

local M = {}

-- Default path, used when CUSTOMERS_FILE is not exported into the Lua VM.
local DEFAULT_PATH = "/etc/nginx/customers.json"

local function path_of(path)
    if path and path ~= "" then return path end
    return os.getenv("CUSTOMERS_FILE") or DEFAULT_PATH
end

-- module-level: survives for the life of the worker, one load per worker
local cached = nil

local function parse(path)
    local f = assert(io.open(path, "r"), "customers file not readable: " .. tostring(path))
    local body = f:read("*a")
    f:close()

    local raw = cjson.decode(body)
    local by_host = {}
    for _, c in ipairs(raw.customers or {}) do
        by_host[c.hostname] = {
            origin     = c.origin,
            renderReady = c.renderReady and true or false,
            credit     = c.credit or "",
        }
    end
    return by_host
end

-- Returns a plain table of hostname -> customer. Cached; pass true to force a reload.
function M.load(path, force)
    path = path_of(path)
    if cached == nil or force then
        cached = { path = path, by_host = parse(path) }
    end
    return cached.by_host
end

-- Lookup for the access_by_lua_block in nginx.conf
function M.by_host(host, path)
    return M.load(path)[host]
end

return M