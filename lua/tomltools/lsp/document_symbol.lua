local M = {}

---@param r integer[]  {r1, c1, r2, c2} 0-indexed
---@return lsp.Range
local function _to_lsp_range(r)
    return {
        start   = { line = r[1], character = r[2] },
        ["end"] = { line = r[3], character = r[4] },
    }
end

---@param context  tomltools.LspBufferContext
---@param _params  lsp.DocumentSymbolParams
---@param callback fun(err?: lsp.ResponseError, result?: lsp.DocumentSymbol[])
function M.handler(context, _params, callback)
    local dt = context.decode_tree
    if not dt then
        callback(nil, {})
        return
    end

    ---@type lsp.DocumentSymbol[]
    local symbols = {}

    for child_id, data in dt._tree:iter_children(dt:root_id()) do
        local range = dt:range_of_id(child_id)
        if range then
            symbols[#symbols + 1] = {
                name           = data.key,
                kind           = vim.lsp.protocol.SymbolKind.Object,
                range          = _to_lsp_range(range),
                selectionRange = _to_lsp_range(range),
            }
        end
    end

    callback(nil, symbols)
end

return M
