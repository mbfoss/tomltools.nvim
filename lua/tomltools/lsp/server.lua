-- tomltools LSP server — runs as a headless Neovim subprocess.
-- Launched via: nvim --headless -l <this file>
-- Communicates with the Neovim LSP client over stdin/stdout using JSON-RPC
-- with Content-Length framing (standard LSP transport).

-- ── Module resolution ────────────────────────────────────────────────────────
local _src   = debug.getinfo(1, "S").source:sub(2)
local _lua   = vim.fn.fnamemodify(_src, ":h:h:h")  -- .../lua
package.path = _lua .. "/?.lua;" .. _lua .. "/?/init.lua;" .. package.path

-- ── Imports ──────────────────────────────────────────────────────────────────
local parser      = require("tomltools.toml.parser")
local decoder     = require("tomltools.toml.decoder")
local diagnostics = require("tomltools.lsp.diagnostics")
local completion  = require("tomltools.lsp.completion")
local hover       = require("tomltools.lsp.hover")
local code_action = require("tomltools.lsp.code_action")
local doc_symbol  = require("tomltools.lsp.document_symbol")
local fmt         = require("tomltools.lsp.format")

-- ── Transport ─────────────────────────────────────────────────────────────────
local uv     = vim.uv
local stdin  = uv.new_pipe(false)
local stdout = uv.new_pipe(false)
stdin:open(0)
stdout:open(1)

-- ── Logger ───────────────────────────────────────────────────────────────────
-- Neovim's LSP client captures the server's stderr and routes it through
-- vim.lsp.log. Use vim.lsp.set_log_level("debug") on the client to see these.
local function log(msg)
    io.stderr:write("[tomltools] " .. tostring(msg) .. "\n")
    io.stderr:flush()
end
log("server starting, pid=" .. tostring(uv.os_getpid()))

---@param obj table
local function write_msg(obj)
    local json = vim.json.encode(obj)
    stdout:write(("Content-Length: %d\r\n\r\n%s"):format(#json, json))
end

-- ── Server state ─────────────────────────────────────────────────────────────
---@type table<string, tomltools.LspBufferContext>
local documents    = {}   -- uri → context
---@type table<string, table>
local schemas      = {}   -- uri → decoded schema table
---@type table<integer, fun(err: any, result: any)>
local pending_reqs = {}   -- outgoing req id → callback
local _req_id      = 0    -- outgoing request counter
local debug_commands = false

-- ── Capabilities ─────────────────────────────────────────────────────────────
local INITIALIZE_RESULT = {
    capabilities = {
        textDocumentSync                = { openClose = true, change = 2 },
        positionEncoding                = "utf-8",
        hoverProvider                   = true,
        completionProvider              = { triggerCharacters = { ".", "[", '"', "=", " " } },
        codeActionProvider              = { codeActionKinds = { "quickfix", "refactor.extract" } },
        documentFormattingProvider      = true,
        documentRangeFormattingProvider = true,
        documentSymbolProvider          = true,
    },
    serverInfo = { name = "tomltools-toml", version = "0.1.0" },
}

-- ── Document helpers ──────────────────────────────────────────────────────────

local DIAG_DEBOUNCE_MS = 200

---@type table<string, string>
local doc_text   = {}
---@type table<string, any>
local diag_timer = {}

---@param uri  string
---@param text string
---@return tomltools.LspBufferContext
local function parse_document(uri, text)
    local lines  = vim.split(text, "\n", { plain = true })
    local parsed = parser.parse(text)
    local ctx    = {
        bufnr         = nil,
        schema        = schemas[uri] or {},
        text          = text,
        lines         = lines,
        cst           = parsed.cst,
        parse_errors  = parsed.errors,
        data          = nil,
        decode_errors = {},
        decode_tree   = nil,
        parse_results = nil,
    }
    if parsed.cst then
        local decoded     = decoder.decode(parsed.cst)
        ctx.data          = decoded.data
        ctx.decode_errors = decoded.errors
        ctx.decode_tree   = decoded.decode_tree
    end
    documents[uri] = ctx
    return ctx
end

---@param uri string
local function publish_diagnostics(uri)
    local ctx = documents[uri]
    if not ctx then return end
    local diags = diagnostics.build(nil, ctx)
    write_msg({
        jsonrpc = "2.0",
        method  = "textDocument/publishDiagnostics",
        params  = { uri = uri, diagnostics = diags },
    })
end

---@param uri string
local function schedule_diagnostics(uri)
    local t = diag_timer[uri]
    if t then
        t:stop()
    else
        t = uv.new_timer()
        diag_timer[uri] = t
    end
    t:start(DIAG_DEBOUNCE_MS, 0, function()
        t:stop(); t:close(); diag_timer[uri] = nil
        local text = doc_text[uri]
        if text then
            parse_document(uri, text)
            publish_diagnostics(uri)
        end
    end)
end

---@param uri string
local function ensure_parsed(uri)
    local t = diag_timer[uri]
    if not t then return end
    t:stop(); t:close(); diag_timer[uri] = nil
    local text = doc_text[uri]
    if text then
        parse_document(uri, text)
        publish_diagnostics(uri)
    end
end

-- ── Outgoing server→client request ───────────────────────────────────────────

---@param method string
---@param params table
---@param cb     fun(err: any, result: any)
local function send_request(method, params, cb)
    _req_id = _req_id + 1
    pending_reqs[_req_id] = cb
    write_msg({ jsonrpc = "2.0", id = _req_id, method = method, params = params })
end

-- ── Incremental text application ─────────────────────────────────────────────

---@param text   string
---@param change table  { range: {start, end}, text: string }
---@return string
local function apply_incremental(text, change)
    if not change.range then return change.text end
    local r     = change.range
    local lines = vim.split(text, "\n", { plain = true })

    local before = {}
    for i = 1, r.start.line do before[#before + 1] = lines[i] end
    before[#before + 1] = (lines[r.start.line + 1] or ""):sub(1, r.start.character)

    local after = { (lines[r["end"].line + 1] or ""):sub(r["end"].character + 1) }
    for i = r["end"].line + 2, #lines do after[#after + 1] = lines[i] end

    return table.concat(before, "\n") .. change.text .. table.concat(after, "\n")
end

-- ── Request / notification dispatch ──────────────────────────────────────────

---@param id     integer|string|nil
---@param result any
local function respond(id, result)
    if id == nil then return end
    write_msg({ jsonrpc = "2.0", id = id, result = result })
end

---@param id      integer|string|nil
---@param code    integer
---@param message string
local function respond_err(id, code, message)
    if id == nil then return end
    write_msg({ jsonrpc = "2.0", id = id, error = { code = code, message = message } })
end

-- ── Debug dump helpers (only compiled when debug_commands = true) ─────────────

local dump_cst, dump_decode_tree, dump_data

dump_cst = function(ctx)
    if not ctx or not ctx.cst then return "(no CST)" end
    local lines = {}
    ctx.cst._tree:walk_tree(function(id, d, depth)
        local indent = string.rep("  ", depth)
        local kind   = d.kind ~= nil and tostring(d.kind) or "?"
        local text   = d.text ~= nil and (" text=" .. vim.inspect(d.text:sub(1, 60))) or ""
        local value  = d.value ~= nil and (" value=" .. vim.inspect(d.value)) or ""
        local rng    = d.range and (" range=[" .. table.concat(d.range, ",") .. "]") or ""
        lines[#lines + 1] = indent .. "[" .. id .. "] " .. kind .. text .. value .. rng
        return true
    end)
    return table.concat(lines, "\n")
end

dump_decode_tree = function(ctx)
    if not ctx or not ctx.decode_tree then return "(no decode tree)" end
    local dt    = ctx.decode_tree
    local lines = {}
    dt._tree:walk_tree(function(id, d, depth)
        local indent  = string.rep("  ", depth)
        local key     = d.key ~= nil and (" key=" .. vim.inspect(d.key)) or ""
        local ranges  = ""
        if d.ranges and #d.ranges > 0 then
            local rs = {}
            for _, r in ipairs(d.ranges) do rs[#rs + 1] = "[" .. table.concat(r, ",") .. "]" end
            ranges = " ranges={" .. table.concat(rs, ",") .. "}"
        end
        lines[#lines + 1] = indent .. "[" .. id .. "]" .. key .. ranges
        return true
    end)
    return table.concat(lines, "\n")
end

dump_data = function(ctx)
    if not ctx or ctx.data == nil then return "(no data)" end
    return vim.inspect(ctx.data)
end

-- ── Main dispatcher ───────────────────────────────────────────────────────────

---@param msg table
local function dispatch(msg)
    -- Route responses to server-initiated requests (no .method field on responses).
    if msg.id and not msg.method then
        local cb = pending_reqs[msg.id]
        if cb then pending_reqs[msg.id] = nil; cb(msg.error, msg.result) end
        return
    end

    local method = msg.method
    local id     = msg.id
    local params = msg.params or {}
    log("dispatch method=" .. tostring(method) .. " id=" .. tostring(id))

    -- ── Lifecycle ────────────────────────────────────────────────────────────
    if method == "initialize" then
        local opts = params.initializationOptions or {}
        if opts.debug_commands then
            debug_commands = true
            log("debug commands enabled")
        end
        respond(id, INITIALIZE_RESULT)
        log("initialize done")
        return
    end

    if method == "initialized" then return end

    if method == "shutdown" then
        respond(id, vim.NIL)
        return
    end

    if method == "exit" then
        uv.stop()
        return
    end

    -- ── Text synchronisation ─────────────────────────────────────────────────
    if method == "textDocument/didOpen" then
        local uri  = params.textDocument.uri
        local text = params.textDocument.text
        log("didOpen " .. tostring(uri))
        doc_text[uri] = text
        -- Fetch the schema for this document from the client before parsing.
        send_request("tomltools/getSchema", { uri = uri }, function(err, result)
            local s = {}
            if not err and result and result.schema then
                local ok, decoded = pcall(vim.json.decode, result.schema)
                if ok then s = decoded end
            end
            schemas[uri] = s
            parse_document(uri, text)
            publish_diagnostics(uri)
        end)
        return
    end

    if method == "textDocument/didChange" then
        local uri     = params.textDocument.uri
        local text    = doc_text[uri] or ""
        local changes = params.contentChanges
        if changes then
            for _, change in ipairs(changes) do
                text = apply_incremental(text, change)
            end
        end
        doc_text[uri] = text
        schedule_diagnostics(uri)
        return
    end

    if method == "textDocument/didClose" then
        local uri = params.textDocument.uri
        local t   = diag_timer[uri]
        if t then t:stop(); t:close(); diag_timer[uri] = nil end
        doc_text[uri]  = nil
        documents[uri] = nil
        schemas[uri]   = nil
        return
    end

    -- ── Debug dump requests (requires debug_commands = true) ─────────────────
    if debug_commands then
        if method == "tomltools/dumpCst"
            or method == "tomltools/dumpDecodeTree"
            or method == "tomltools/dumpData" then
            local uri = params.textDocument and params.textDocument.uri
            if not uri then
                respond_err(id, -32602, "missing textDocument.uri")
                return
            end
            ensure_parsed(uri)
            local ctx = documents[uri]
            local text
            if method == "tomltools/dumpCst" then
                text = dump_cst(ctx)
            elseif method == "tomltools/dumpDecodeTree" then
                text = dump_decode_tree(ctx)
            else
                text = dump_data(ctx)
            end
            respond(id, { text = text })
            return
        end
    end

    -- ── Feature requests ─────────────────────────────────────────────────────
    local uri = params.textDocument and params.textDocument.uri
    if not uri then
        respond_err(id, -32602, "missing textDocument.uri")
        return
    end

    local ctx = documents[uri]
    if not ctx then
        respond(id, vim.NIL)
        return
    end

    local function cb(err, res)
        if err then
            log("handler error: " .. tostring(err.message or err))
            respond_err(id, err.code or -32603, err.message or "internal error")
        else
            respond(id, res ~= nil and res or vim.NIL)
        end
    end

    if method == "textDocument/completion" then
        ensure_parsed(uri)
        ctx = documents[uri] or ctx
        local ok, err = pcall(completion.handler, ctx, params, cb)
        if not ok then log("completion pcall error: " .. tostring(err)) end
        return
    end

    if method == "textDocument/hover" then
        ensure_parsed(uri)
        hover.handler(ctx, params, cb)
        return
    end

    if method == "textDocument/codeAction" then
        ensure_parsed(uri)
        code_action.handler(ctx, params, cb)
        return
    end

    if method == "textDocument/formatting"
        or method == "textDocument/rangeFormatting" then
        ensure_parsed(uri)
        fmt.handler(ctx, params, cb)
        return
    end

    if method == "textDocument/documentSymbol" then
        ensure_parsed(uri)
        doc_symbol.handler(ctx, params, cb)
        return
    end

    if method == "workspace/executeCommand" then
        respond(id, vim.NIL)
        return
    end

    if id ~= nil then
        respond_err(id, -32601, "method not found: " .. tostring(method))
    end
end

-- ── stdin reader ─────────────────────────────────────────────────────────────
local _buf = ""

stdin:read_start(function(err, data)
    if err or not data then
        log("stdin closed, stopping")
        uv.stop()
        return
    end
    _buf = _buf .. data
    while true do
        local hdr_end = _buf:find("\r\n\r\n", 1, true)
        if not hdr_end then break end
        local hdr = _buf:sub(1, hdr_end - 1)
        local len = tonumber(hdr:match("Content%-Length:%s*(%d+)"))
        if not len then
            _buf = _buf:sub(hdr_end + 4)
        else
            local body_start = hdr_end + 4
            local body_end   = body_start + len - 1
            if #_buf < body_end then break end
            local body = _buf:sub(body_start, body_end)
            _buf = _buf:sub(body_end + 1)
            local ok, msg = pcall(vim.json.decode, body)
            if ok and type(msg) == "table" then
                dispatch(msg)
            else
                log("json decode error: " .. tostring(msg))
            end
        end
    end
end)

uv.run()
