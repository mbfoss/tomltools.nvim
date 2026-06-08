local M = {}

---@class tomltools.SetupOpts
---@field filetypes      string[]?                                         default: {"toml"}
---@field schema         (table|fun(buf: integer, uri: string): table)?   schema or factory
---@field commands       table?                                            caller-supplied vim.lsp.commands handlers
---@field debug_commands boolean?                                          enable debug dump requests (off by default)

---@param opts tomltools.SetupOpts?
function M.setup(opts)
    opts = opts or {}
    local filetypes = opts.filetypes or { "toml" }

    vim.api.nvim_create_autocmd("FileType", {
        pattern  = filetypes,
        group    = vim.api.nvim_create_augroup("tomltools", { clear = true }),
        callback = function(ev)
            require("tomltools.lsp").start(ev.buf, {
                schema         = opts.schema,
                commands       = opts.commands,
                debug_commands = opts.debug_commands,
            })
        end,
    })
end

return M
