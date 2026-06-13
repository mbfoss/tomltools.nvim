-- tomltools/lsp/builtin_actions.lua
-- Built-in code action providers. Assigned to every buffer context in server.lua.
-- Each provider matches the signature: fun(ctx, params) -> lsp.CodeAction[]

local M = {}

local schema_nav = require("tomltools.toml.schema_nav")
local s_util     = require("tomltools.toml.schema_util")
local Cst        = require("tomltools.toml.Cst")

local K = Cst.Kind

-- ── Helpers ───────────────────────────────────────────────────────────────────

---@param sl   integer  0-indexed start line
---@param sc   integer  0-indexed start char (inclusive)
---@param el   integer  0-indexed end line
---@param ec   integer  0-indexed end char (exclusive)
---@param text string
---@return lsp.TextEdit
local function text_edit(sl, sc, el, ec, text)
    return {
        range   = { start = { line = sl, character = sc }, ["end"] = { line = el, character = ec } },
        newText = text,
    }
end

---@param title string
---@param kind  string
---@param uri   string
---@param edits lsp.TextEdit[]
---@return lsp.CodeAction
local function make_action(title, kind, uri, edits)
    return { title = title, kind = kind, edit = { changes = { [uri] = edits } } }
end

-- Extract the source text for a CST range {r1,c1,r2,c2} from the document lines.
-- All coordinates are 0-indexed; c2 is exclusive.
---@param lines string[]
---@param r1    integer
---@param c1    integer
---@param r2    integer
---@param c2    integer
---@return string
local function range_text(lines, r1, c1, r2, c2)
    if r1 == r2 then
        return (lines[r1 + 1] or ""):sub(c1 + 1, c2)
    end
    local parts = { (lines[r1 + 1] or ""):sub(c1 + 1) }
    for r = r1 + 2, r2 do
        parts[#parts + 1] = lines[r] or ""
    end
    parts[#parts + 1] = (lines[r2 + 1] or ""):sub(1, c2)
    return table.concat(parts, "\n")
end

---@param key string
---@return string
local function quote_key(key)
    if key:match("^[A-Za-z0-9_%-]+$") then return key end
    return '"' .. key:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

-- Returns the CST scope node and DecodeTree id for the section containing (row,col),
-- falling back to document root when the cursor is not inside any section.
---@param cst tomltools.toml.Cst
---@param dt  tomltools.toml.DecodeTree
---@param row integer
---@param col integer
---@return integer?  scope_id   nil at document root
---@return integer   dt_id
local function enclosing_scope(cst, dt, row, col)
    local tok_id   = cst:token_at(row, col)
    local scope_id = cst:ancestor_of_kind(tok_id, K.TableSection, K.AotSection)
    local dt_id    = (scope_id and cst:get_tag(scope_id)) or dt:root_id()
    return scope_id, dt_id
end

-- Returns the KVP node id containing the cursor, or nil. Stops at InlineTable
-- boundaries so that cursor positions inside nested inline tables resolve to
-- the inner KVP rather than escaping to the outer one.
---@param cst   tomltools.toml.Cst
---@param tok_id integer
---@return integer?
local function kvp_at(cst, tok_id)
    local anc = cst:ancestor_of_kind(tok_id, K.KeyValuePair, K.InlineTable)
    if anc and cst:kind(anc) == K.KeyValuePair then return anc end
    if cst:kind(tok_id) == K.KeyValuePair then return tok_id end
    return nil
end

-- ── Action 1: fill missing required keys ─────────────────────────────────────

--- Offers to insert all required keys that are absent from the enclosing section.
--- Uses schema defaults as placeholder values; falls back to `""` for untyped keys.
---@param ctx    tomltools.LspBufferContext
---@param params lsp.CodeActionParams
---@return lsp.CodeAction[]
function M.fill_required_keys(ctx, params)
    if not (ctx.cst and ctx.decode_tree and ctx.schema and ctx.lines) then return {} end

    local cst    = ctx.cst
    local dt     = ctx.decode_tree
    local schema = ctx.schema
    local data   = ctx.data
    local row    = params.range.start.line
    local col    = params.range.start.character

    local scope_id, dt_id = enclosing_scope(cst, dt, row, col)

    local sch = schema_nav.schema_at(schema, data, dt, dt_id)
        or schema_nav.flatten(schema, data)
    if not sch or not sch.required or #sch.required == 0 then return {} end

    -- Collect required keys absent from the decode tree for this scope.
    local missing = {}
    for _, req_key in ipairs(sch.required) do
        if not dt:get_child_id(dt_id, req_key) then
            missing[#missing + 1] = req_key
        end
    end
    if #missing == 0 then return {} end

    -- Build `key = value` lines, using schema defaults where available.
    local new_lines = {}
    for _, key in ipairs(missing) do
        local prop_sch = sch.properties and sch.properties[key]
        local default  = prop_sch and s_util.get_default_toml(prop_sch)
        local value    = (default and default ~= "") and default or '""'
        new_lines[#new_lines + 1] = key .. " = " .. value
    end

    -- Insert after the last line of the enclosing section (or end of document).
    local ins_row, ins_col
    if scope_id then
        local r  = cst:range(scope_id)
        ins_row  = r[3]
        ins_col  = r[4]
    else
        ins_row = #ctx.lines - 1
        ins_col = #(ctx.lines[#ctx.lines] or "")
    end

    local n     = #missing
    local label = "Fill " .. n .. " missing required key" .. (n > 1 and "s" or "")
    return {
        make_action(label, "quickfix", params.textDocument.uri, {
            text_edit(ins_row, ins_col, ins_row, ins_col, "\n" .. table.concat(new_lines, "\n")),
        })
    }
end

-- ── Action 2: expand inline table to block section ───────────────────────────

--- Converts `foo = { a = 1, b = 2 }` to a `[section.foo]` block below the
--- current section. The original KVP line is deleted; the new section is
--- appended after the enclosing section's last line. Preserves original
--- key/value source text for each inner KVP.
---@param ctx    tomltools.LspBufferContext
---@param params lsp.CodeActionParams
---@return lsp.CodeAction[]
function M.expand_inline_table(ctx, params)
    if not (ctx.cst and ctx.lines) then return {} end

    local cst = ctx.cst
    local row = params.range.start.line
    local col = params.range.start.character

    local tok_id = cst:token_at(row, col)
    local kvp_id = kvp_at(cst, tok_id)
    if not kvp_id then return {} end

    -- Only act when the KVP's value is an inline table.
    local val_id = cst:get_value(kvp_id)
    if not val_id or cst:kind(val_id) ~= K.InlineTable then return {} end

    -- Build the new section header: enclosing section keys + this KVP's keys.
    local section_id = cst:ancestor_of_kind(kvp_id, K.TableSection, K.AotSection)
    local header_id  = section_id
        and cst:first_child_of_kind(section_id, K.TableHeader, K.AotHeader)

    local path_parts = {}
    if header_id then
        for _, kd in ipairs(cst:get_keys(header_id)) do
            path_parts[#path_parts + 1] = quote_key(kd.value)
        end
    end
    for _, kd in ipairs(cst:get_keys(kvp_id)) do
        path_parts[#path_parts + 1] = quote_key(kd.value)
    end
    local header = "[" .. table.concat(path_parts, ".") .. "]"

    -- Extract each inner KVP's source text, trimmed of surrounding whitespace.
    local kvp_lines = {}
    for _, child_d in cst:iter_semantic(val_id) do
        if child_d.kind == K.KeyValuePair then
            local r    = child_d.range
            local text = range_text(ctx.lines, r[1], r[2], r[3], r[4])
            kvp_lines[#kvp_lines + 1] = text:match("^%s*(.-)%s*$")
        end
    end

    local new_section = #kvp_lines > 0
        and (header .. "\n" .. table.concat(kvp_lines, "\n"))
        or header

    local kvp_r = cst:range(kvp_id)

    -- Determine the insertion point: end of the enclosing section (or EOF).
    local ins_row, ins_col
    if section_id then
        local r  = cst:range(section_id)
        ins_row  = r[3]
        ins_col  = r[4]
    else
        ins_row = #ctx.lines - 1
        ins_col = #(ctx.lines[#ctx.lines] or "")
    end

    local uri     = params.textDocument.uri
    local title   = "Expand inline table to [section]"
    local act_kind = "refactor.extract"

    if ins_row > kvp_r[3] then
        -- Normal case: KVP is not the last content in the section.
        -- Two non-overlapping edits applied bottom-to-top by the client.
        local ins_edit = text_edit(ins_row, ins_col, ins_row, ins_col, "\n\n" .. new_section)
        local del_edit = text_edit(kvp_r[1], 0, kvp_r[3] + 1, 0, "")
        return { make_action(title, act_kind, uri, { ins_edit, del_edit }) }
    else
        -- KVP is the last line of the section; the two positions overlap.
        -- Use a single edit that replaces the KVP with a blank separator + new section.
        local combined = text_edit(kvp_r[1], 0, kvp_r[3], ins_col, "\n" .. new_section)
        return { make_action(title, act_kind, uri, { combined }) }
    end
end

-- ── Action 3: set value to schema default ────────────────────────────────────

--- When the cursor is on a decoded KVP whose schema has a `default`, offers to
--- replace the current value with that default.
---@param ctx    tomltools.LspBufferContext
---@param params lsp.CodeActionParams
---@return lsp.CodeAction[]
function M.insert_default_value(ctx, params)
    if not (ctx.cst and ctx.decode_tree and ctx.schema) then return {} end

    local cst    = ctx.cst
    local dt     = ctx.decode_tree
    local schema = ctx.schema
    local data   = ctx.data
    local row    = params.range.start.line
    local col    = params.range.start.character

    local tok_id = cst:token_at(row, col)
    local kvp_id = kvp_at(cst, tok_id)
    if not kvp_id then return {} end

    -- Only act on KVPs that are already decoded (have a schema path).
    local dt_id = cst:get_tag(kvp_id)
    if not dt_id then return {} end

    local sch = schema_nav.schema_at(schema, data, dt, dt_id)
    if not sch or sch.default == nil then return {} end

    local default_text = s_util.get_default_toml(sch)
    if default_text == "" then return {} end

    -- Replace the existing value token's range with the encoded default.
    local _, val_d = cst:get_value(kvp_id)
    if not val_d then return {} end
    local vr = val_d.range

    return {
        make_action(
            "Set to default: " .. default_text,
            "quickfix",
            params.textDocument.uri,
            { text_edit(vr[1], vr[2], vr[3], vr[4], default_text) }
        )
    }
end

-- ── Provider list ─────────────────────────────────────────────────────────────

--- All built-in providers as a ready-to-assign list for context.code_action_providers.
---@type (fun(ctx: tomltools.LspBufferContext, params: table): lsp.CodeAction[]?)[]
M.providers = {
    M.fill_required_keys,
    M.expand_inline_table,
    M.insert_default_value,
}

return M
