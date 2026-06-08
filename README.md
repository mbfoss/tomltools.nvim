# tomltools.nvim

A standalone, distributable Neovim plugin that provides a full TOML processing pipeline and a schema-driven LSP server. It is designed to be embedded in other plugins that need TOML editing support — pass in a JSON Schema and get diagnostics, completions, hover, formatting, and document symbols for free.

**Requires Neovim >= 0.10.**

---

## Features

- Hand-written recursive descent TOML parser producing a lossless Concrete Syntax Tree (CST)
- Full TOML 1.0 decode, encode, and format pipeline
- JSON Schema Draft 2020-12 validator (partial — covers the most common keywords)
- Schema-driven LSP server running as a headless Neovim subprocess:
  - Diagnostics (parse errors, decode errors, schema validation)
  - Completions (keys, values, enum suggestions, `[table]` / `[[aot]]` headers)
  - Hover (title, description, type, default)
  - Formatting
  - Document symbols (top-level keys)
  - Code actions (extensible via `code_action_providers`)
- Per-document schema: the schema factory receives `(bufnr, uri)` and can return different schemas per buffer
- Debug dump commands (CST, DecodeTree, raw data) — off by default

---

## Installation

```lua
-- lazy.nvim
{ "mbfoss/tomltools.nvim" }

-- packer
use "mbfoss/tomltools.nvim"

-- vim-plug
Plug "mbfoss/tomltools.nvim"
```

Or place the directory in `pack/*/opt/` and call `packadd tomltools.nvim`.

---

## Quick start

Attach the LSP to every TOML buffer:

```lua
vim.api.nvim_create_autocmd("FileType", {
    pattern = { "toml" },
    callback = function(ev)
        require("tomltools.lsp").start(ev.buf, {
            schema = function(bufnr, uri)
                if uri:match("ci%.toml$") then
                    return require("my_plugin.schemas.ci")
                end
                return require("my_plugin.schemas.default")
            end,
        })
    end,
})
```

Attach or stop manually on a single buffer:

```lua
local lsp = require("tomltools.lsp")
lsp.start(bufnr, { schema = function(buf, uri) return my_schema end })
lsp.stop(bufnr)
```

---

## LSP options

`lsp.start(bufnr, opts)` accepts:

```lua
{
    -- Schema factory: called per buffer, receives (bufnr, uri), returns a JSON Schema table.
    schema = nil,

    -- Extra client-side vim.lsp.commands handlers (registered at startup).
    commands = nil,

    -- Enable debug dump requests. Off by default.
    debug_commands = false,
}
```

---

## Using the TOML pipeline directly

All pipeline modules are public and can be imported without starting the LSP:

```lua
local parser  = require("tomltools.toml.parser")
local decoder = require("tomltools.toml.decoder")
local encoder = require("tomltools.toml.encoder")

-- Parse + decode
local result = decoder.decode('name = "hello"\nvalue = 42\n')
print(result.ok, result.data.name)  -- true  hello

-- Encode
print(encoder.encode({ name = "hello", value = 42 }))

-- Format (round-trips through the CST)
local fmt    = require("tomltools.toml.formatter")
local parsed = parser.parse(text)
print(fmt.format(parsed.cst))
```

---

## Schema

The `schema` option passed to `lsp.start()` is a function `(bufnr, uri) -> table` that returns a [JSON Schema](https://json-schema.org/) table. The plugin implements a partial subset of Draft 2020-12: `type`, `enum`, `const`, string/numeric/array/object keywords, `allOf`, `anyOf`, `oneOf`, `not`, `if/then/else`, `dependentRequired`, `dependentSchemas`.

Schema navigation and conditional resolution happen at runtime against the decoded document data, so `if/then` branches and `oneOf` selections react to the actual values in the file.

---

## Code action providers

Consumers can inject code actions by populating `context.code_action_providers` before the LSP server dispatches `textDocument/codeAction`. Because the server context is built fresh per request, the typical pattern is to pass a provider list via `init_options` and set it in the `BufferContext`:

```lua
-- In a plugin that builds on tomltools:
-- set context.code_action_providers in a custom server wrapper,
-- or extend lsp/code_action.lua to read from initializationOptions.
```

---

## Debug dumps

When `debug_commands = true` is passed to `lsp.start()`, the Lua API exposes:

```lua
local lsp = require("tomltools.lsp")
lsp.dump(bufnr, "cst")          -- opens scratch buffer with CST dump
lsp.dump(bufnr, "decode_tree")  -- DecodeTree dump
lsp.dump(bufnr, "data")         -- decoded Lua table (vim.inspect)
```

---

## Architecture

See [CLAUDE.md](CLAUDE.md) for a detailed technical description of the internals.
