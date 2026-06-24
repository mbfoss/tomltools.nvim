-- tests/run_encoder.lua
-- Run with: luajit tests/run_encoder.lua   (or any Lua 5.1+ interpreter)
-- Reads toml-test tagged JSON from stdin, writes TOML to stdout.
-- Exits non-zero on error.

-- Resolve module paths relative to this script so it works from any cwd.
local here = (arg[0] or "tests/run_encoder.lua"):match("^(.*[/\\])") or "./"
package.path = here .. "?.lua;"
    .. here .. "../lua/?.lua;"
    .. here .. "../lua/?/init.lua;"
    .. package.path

local encoder = require("tomltools.encoder")
local std     = require("tomltools.std")
local json    = require("json")

local datetime_types = {
    ["datetime"]       = true,
    ["datetime-local"] = true,
    ["date-local"]     = true,
    ["time-local"]     = true,
}

-- Convert a toml-test tagged JSON value into a plain Lua value the encoder understands.
-- Scalars come in as {type=..., value=...}; tables/arrays are plain Lua structures.
local function untag(v)
    if type(v) ~= "table" then return v end

    -- Tagged scalar: {type = "...", value = "..."}
    local typ = v.type
    local val = v.value
    if type(typ) == "string" and val ~= nil then
        if typ == "string" then
            return tostring(val)
        elseif typ == "integer" then
            return math.floor(tonumber(val) or 0)
        elseif typ == "float" then
            local s = tostring(val)
            if s == "nan"  then return encoder.raw("nan") end
            if s == "inf"  then return encoder.raw("inf") end
            if s == "-inf" then return encoder.raw("-inf") end
            local n = tonumber(s)
            local formatted = string.format("%.17g", n)
            if not formatted:find("[%.eE]") then formatted = formatted .. ".0" end
            return encoder.raw(formatted)
        elseif typ == "bool" then
            return val == "true" or val == true
        elseif datetime_types[typ] then
            -- Emit verbatim — no quotes
            return encoder.raw(tostring(val))
        end
    end

    if std.islist(v) then
        local arr = {}
        for i = 1, #v do arr[i] = untag(v[i]) end
        return arr
    end

    local tbl = std.empty_dict()
    for k, child in pairs(v) do
        tbl[k] = untag(child)
    end
    return tbl
end

local raw = io.read("*a")
local ok, tagged = pcall(json.decode, raw, { luanil = { object = true, array = true } })
if not ok then
    io.stderr:write("run_encoder: JSON parse error: " .. tostring(tagged) .. "\n")
    os.exit(1)
end

local data = untag(tagged)

local toml_ok, result = pcall(encoder.encode, data)
if not toml_ok then
    io.stderr:write("run_encoder: encode error: " .. tostring(result) .. "\n")
    os.exit(1)
end

io.write(result)
