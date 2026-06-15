local diagnostics = require("tomltools.lsp.diagnostics")

local M = {}

M.SERVER_NAME    = "tomltools-toml"
M.SERVER_VERSION = "0.1.0"

local _this_file    = debug.getinfo(1, "S").source:sub(2)
local SERVER_SCRIPT = vim.fn.fnamemodify(_this_file, ":h") .. "/server.lua"

---@type table<integer, {client_id: integer, debug_commands: boolean}>
local attached = {}

-- ── Public API ────────────────────────────────────────────────────────────────

---@class tomltools.LspStartOpts
---@field schema         (fun(buf: integer, uri: string): table)?
---@field commands       table?   caller-supplied vim.lsp.commands handlers
---@field debug_commands boolean? enable debug dump LSP requests
---@field debug_lua      boolean? attach the LuaPanda debugger to the server process (default: false)
---@field debug_lua_host string?  LuaPanda host (default: "127.0.0.1")
---@field debug_lua_port integer? LuaPanda port (default: 8818)

---@param buf  integer
---@param opts tomltools.LspStartOpts?
---@return integer? client_id
function M.start(buf, opts)
    opts = opts or {}
    if attached[buf] then M.stop(buf) end

    local schema         = opts.schema
    local debug_commands = opts.debug_commands or false

    -- Register any caller-supplied client-side LSP command handlers.
    if opts.commands then
        for name, handler in pairs(opts.commands) do
            vim.lsp.commands[name] = handler
        end
    end

    local config = {
        name         = M.SERVER_NAME,
        cmd          = { vim.v.progpath, "--headless", "--noplugin", "-n", "-u", "NONE", "-l", SERVER_SCRIPT },
        init_options = {
            debug_commands = debug_commands,
            debug_lua      = opts.debug_lua or false,
            debug_lua_host = opts.debug_lua_host,
            debug_lua_port = opts.debug_lua_port,
        },
        root_dir     = vim.fn.getcwd(),

        -- Push the schema to the server as soon as it attaches to a buffer.
        on_attach = function(client, bufnr)
            local uri = vim.uri_from_bufnr(bufnr)
            local s   = schema and schema(bufnr, uri) or nil
            client:notify("tomltools/setSchema", {
                uri    = uri,
                schema = vim.json.encode(s or {}),
            })
        end,
    }

    local client_id = vim.lsp.start(config, { bufnr = buf })

    if client_id then
        attached[buf] = { client_id = client_id, debug_commands = debug_commands }
    end

    return client_id
end

---@param buf integer
function M.stop(buf)
    local entry = attached[buf]
    if not entry then return end

    vim.diagnostic.reset(diagnostics.namespace, buf)
    vim.lsp.buf_detach_client(buf, entry.client_id)
    attached[buf] = nil

    -- Stop the server process only when no buffers remain attached.
    local client = vim.lsp.get_client_by_id(entry.client_id)
    if client and next(client.attached_buffers) == nil then
        client:stop(true)
    end
end

-- ── Debug dump API ────────────────────────────────────────────────────────────
-- Only works when opts.debug_commands = true was passed to M.start().

local _dump_methods = {
    cst          = "tomltools/dumpCst",
    decode_tree  = "tomltools/dumpDecodeTree",
    data         = "tomltools/dumpData",
}

---@param buf  integer
---@param what "cst"|"decode_tree"|"data"
function M.dump(buf, what)
    local entry = attached[buf]
    if not entry then
        vim.notify("[tomltools] no LSP client attached to buffer " .. tostring(buf), vim.log.levels.WARN)
        return
    end
    if not entry.debug_commands then
        vim.notify("[tomltools] debug_commands not enabled for this buffer", vim.log.levels.WARN)
        return
    end

    local method = _dump_methods[what]
    if not method then
        vim.notify("[tomltools] unknown dump target: " .. tostring(what), vim.log.levels.ERROR)
        return
    end

    local uri    = vim.uri_from_bufnr(buf)
    local params = { textDocument = { uri = uri } }

    local client = vim.lsp.get_client_by_id(entry.client_id)
    if not client then
        vim.notify("[tomltools] LSP client not found", vim.log.levels.ERROR)
        return
    end
    client:request(method --[[@as any]], params, function(err, result)
        if err then
            vim.notify("[tomltools] dump error: " .. tostring(err.message), vim.log.levels.ERROR)
            return
        end
        local text = (result and result.text) or "(empty)"

        local scratch = vim.api.nvim_create_buf(false, true)
        vim.bo[scratch].buftype   = "nofile"
        vim.bo[scratch].bufhidden = "wipe"
        vim.api.nvim_buf_set_name(scratch, "[tomltools:" .. what .. "]")
        vim.api.nvim_buf_set_lines(scratch, 0, -1, false, vim.split(text, "\n", { plain = true }))
        vim.cmd("split")
        vim.api.nvim_win_set_buf(0, scratch)
    end, buf)
end

return M
