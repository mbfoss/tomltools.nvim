local M = {}

---@param context  tomltools.LspBufferContext
---@param params   lsp.CodeActionParams
---@param callback fun(err?: lsp.ResponseError, result?: lsp.Command[]|lsp.CodeAction[])
function M.handler(context, params, callback)
    local actions = {}
    if context.code_action_providers then
        for _, provider in ipairs(context.code_action_providers) do
            vim.list_extend(actions, provider(context, params) or {})
        end
    end
    callback(nil, actions)
end

return M
