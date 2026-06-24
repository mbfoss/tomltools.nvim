-- Minimal pure-Lua JSON codec for the toml-test harness.
--
-- It is deliberately small and only handles what toml-test exchanges (tagged
-- objects, arrays, and string scalars), but it preserves the two distinctions
-- the harness depends on:
--   * empty object `{}` decodes to `std.empty_dict()` (an object), while empty
--     array `[]` decodes to a plain `{}` (a list) — so `std.islist` round-trips;
--   * JSON `null` maps to `std.NULL` (or is dropped when `luanil` is requested).

local std = require("tomltools.std")

local M = {}

-- ───────────────────────────── encode ─────────────────────────────

local ESCAPES = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function encode_string(s)
    local out = s:gsub('[%z\1-\31"\\]', function(c)
        return ESCAPES[c] or string.format("\\u%04x", c:byte())
    end)
    return '"' .. out .. '"'
end

local function encode_value(v, acc)
    if v == std.NULL or v == nil then
        acc[#acc + 1] = "null"
    elseif type(v) == "boolean" then
        acc[#acc + 1] = tostring(v)
    elseif type(v) == "number" then
        if v % 1 == 0 and v == v and v ~= math.huge and v ~= -math.huge then
            acc[#acc + 1] = string.format("%d", v)
        else
            acc[#acc + 1] = string.format("%.17g", v)
        end
    elseif type(v) == "string" then
        acc[#acc + 1] = encode_string(v)
    elseif type(v) == "table" then
        if std.islist(v) then
            acc[#acc + 1] = "["
            for i = 1, #v do
                if i > 1 then acc[#acc + 1] = "," end
                encode_value(v[i], acc)
            end
            acc[#acc + 1] = "]"
        else
            acc[#acc + 1] = "{"
            local first = true
            for k, val in pairs(v) do
                if not first then acc[#acc + 1] = "," end
                first = false
                acc[#acc + 1] = encode_string(tostring(k))
                acc[#acc + 1] = ":"
                encode_value(val, acc)
            end
            acc[#acc + 1] = "}"
        end
    else
        error("json.encode: cannot encode " .. type(v))
    end
end

function M.encode(v)
    local acc = {}
    encode_value(v, acc)
    return table.concat(acc)
end

-- ───────────────────────────── decode ─────────────────────────────

local function decode_error(s, pos, msg)
    error(("json.decode: %s at position %d"):format(msg, pos), 2)
end

local parse_value -- forward decl

local function skip_ws(s, pos)
    local _, e = s:find("^[ \t\r\n]+", pos)
    return e and e + 1 or pos
end

local UNESCAPES = {
    ['"'] = '"', ["\\"] = "\\", ["/"] = "/", ["b"] = "\b",
    ["f"] = "\f", ["n"] = "\n", ["r"] = "\r", ["t"] = "\t",
}

local function parse_string(s, pos)
    -- pos points at the opening quote
    local buf, i = {}, pos + 1
    while i <= #s do
        local c = s:sub(i, i)
        if c == '"' then
            return table.concat(buf), i + 1
        elseif c == "\\" then
            local n = s:sub(i + 1, i + 1)
            if n == "u" then
                local hex = s:sub(i + 2, i + 5)
                local code = tonumber(hex, 16)
                if not code then decode_error(s, i, "bad \\u escape") end
                -- Encode as UTF-8 (sufficient for the BMP; surrogate pairs are
                -- not expected in toml-test fixtures).
                if code < 0x80 then
                    buf[#buf + 1] = string.char(code)
                elseif code < 0x800 then
                    buf[#buf + 1] = string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
                else
                    buf[#buf + 1] = string.char(
                        0xE0 + math.floor(code / 0x1000),
                        0x80 + math.floor(code / 0x40) % 0x40,
                        0x80 + code % 0x40)
                end
                i = i + 6
            else
                buf[#buf + 1] = UNESCAPES[n] or n
                i = i + 2
            end
        else
            buf[#buf + 1] = c
            i = i + 1
        end
    end
    decode_error(s, pos, "unterminated string")
end

local function parse_object(s, pos, opts)
    local obj = std.empty_dict()
    pos = skip_ws(s, pos + 1)
    if s:sub(pos, pos) == "}" then return obj, pos + 1 end
    while true do
        pos = skip_ws(s, pos)
        if s:sub(pos, pos) ~= '"' then decode_error(s, pos, "expected key string") end
        local key
        key, pos = parse_string(s, pos)
        pos = skip_ws(s, pos)
        if s:sub(pos, pos) ~= ":" then decode_error(s, pos, "expected ':'") end
        local val
        val, pos = parse_value(s, skip_ws(s, pos + 1), opts)
        if val == std.NULL and opts.luanil_object then
            -- drop the key entirely
        else
            obj[key] = val
        end
        pos = skip_ws(s, pos)
        local ch = s:sub(pos, pos)
        if ch == "," then
            pos = pos + 1
        elseif ch == "}" then
            return obj, pos + 1
        else
            decode_error(s, pos, "expected ',' or '}'")
        end
    end
end

local function parse_array(s, pos, opts)
    local arr = {}
    pos = skip_ws(s, pos + 1)
    if s:sub(pos, pos) == "]" then return arr, pos + 1 end
    while true do
        local val
        val, pos = parse_value(s, skip_ws(s, pos), opts)
        if val == std.NULL and opts.luanil_array then
            -- drop element
        else
            arr[#arr + 1] = val
        end
        pos = skip_ws(s, pos)
        local ch = s:sub(pos, pos)
        if ch == "," then
            pos = pos + 1
        elseif ch == "]" then
            return arr, pos + 1
        else
            decode_error(s, pos, "expected ',' or ']'")
        end
    end
end

parse_value = function(s, pos, opts)
    local c = s:sub(pos, pos)
    if c == "{" then
        return parse_object(s, pos, opts)
    elseif c == "[" then
        return parse_array(s, pos, opts)
    elseif c == '"' then
        return parse_string(s, pos)
    elseif c == "t" and s:sub(pos, pos + 3) == "true" then
        return true, pos + 4
    elseif c == "f" and s:sub(pos, pos + 4) == "false" then
        return false, pos + 5
    elseif c == "n" and s:sub(pos, pos + 3) == "null" then
        return std.NULL, pos + 4
    else
        local num = s:match("^%-?%d+%.?%d*[eE]?[+%-]?%d*", pos)
        if num and num ~= "" then
            return tonumber(num), pos + #num
        end
        decode_error(s, pos, "unexpected character " .. string.format("%q", c))
    end
end

--- Decode a JSON string. `opts.luanil = { object = bool, array = bool }` drops
--- JSON `null` values from objects/arrays.
---@param s string
---@param opts table?
---@return any
function M.decode(s, opts)
    local luanil = opts and opts.luanil or {}
    local o = { luanil_object = luanil.object, luanil_array = luanil.array }
    local pos = skip_ws(s, 1)
    local value
    value, pos = parse_value(s, pos, o)
    pos = skip_ws(s, pos)
    if pos <= #s then decode_error(s, pos, "trailing data") end
    return value
end

return M
