local parser    = require("tomltools.toml.parser")
local decoder   = require("tomltools.toml.decoder")
local validator = require("tomltools.toml.validator")

local M = {}

---@class tomltools.Error
---@field range   integer[]?  { r1, c1, r2, c2 } 0-indexed; nil when location is unknown
---@field message string

---@class tomltools.ParseResult
---@field data   table?
---@field errors tomltools.Error[]
---@field ok     boolean

--- Parse, decode, and optionally validate a TOML string.
--- All error types (parse, decode, schema) are normalised to { range, message }.
---@param text   string
---@param schema table?  JSON Schema; validation is skipped when nil
---@return tomltools.ParseResult
function M.parse(text, schema)
    ---@type tomltools.Error[]
    local errors = {}

    local parsed = parser.parse(text)
    for _, e in ipairs(parsed.errors or {}) do
        errors[#errors + 1] = { range = e.range, message = e.message }
    end
    if not parsed.cst then
        return { ok = false, errors = errors }
    end

    local decoded = decoder.decode(parsed.cst)
    for _, e in ipairs(decoded.errors or {}) do
        errors[#errors + 1] = { range = e.range, message = e.message }
    end
    if not decoded.data then
        return { ok = false, errors = errors }
    end

    if schema then
        local valid, v_errors = validator.validate(schema, decoded.data, decoded.decode_tree)
        if not valid then
            for _, e in ipairs(v_errors) do
                local range = e.node_id and decoded.decode_tree
                    and decoded.decode_tree:range_of_id(e.node_id) or nil
                errors[#errors + 1] = { range = range, message = e.err_msg }
            end
        end
    end

    return {
        ok     = #errors == 0,
        data   = decoded.data,
        errors = errors,
    }
end

return M
