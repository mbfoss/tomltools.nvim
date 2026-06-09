# tomltools.nvim

A Neovim plugin providing a full TOML processing pipeline and a schema-driven LSP server. Designed to be embedded in other plugins — supply a JSON Schema and get diagnostics, completions, hover, formatting, and document symbols.

**Requires Neovim >= 0.10.**

---

## Features

- Hand-written recursive descent TOML parser producing a lossless Concrete Syntax Tree (CST)
- Full TOML 1.1 decode, encode, and format pipeline
- JSON Schema Draft 2020-12 validator (partial subset)
- Schema-driven LSP server running as a headless Neovim subprocess:
  - Diagnostics (parse errors, decode errors, schema validation)
  - Completions (keys, values, enum suggestions, `[table]` / `[[aot]]` headers)
  - Hover (title, description, type, default)
  - Formatting
  - Document symbols (top-level keys)
  - Code actions (extensible — see below)
- Per-document schema: the schema factory receives `(bufnr, uri)` and can return a different schema per file
- Debug dump commands (CST, DecodeTree, raw data) — off by default

---

## Installation

```lua
-- lazy.nvim
{ "mbfoss/tomltools.nvim" }
```

Any other manager works. For manual installation, place the directory under `pack/*/opt/` and call `packadd tomltools.nvim`.

---

## Quick start

Wire the LSP to a filetype autocmd:

```lua
vim.api.nvim_create_autocmd("FileType", {
    pattern = { "toml" },
    callback = function(ev)
        require("tomltools.lsp").start(ev.buf, {
            schema = function(bufnr, uri)
                if uri:match("pyproject%.toml$") then
                    return require("my_plugin.schemas.pyproject")
                end
                return require("my_plugin.schemas.default")
            end,
        })
    end,
})
```

Manual attach / detach:

```lua
local lsp = require("tomltools.lsp")
lsp.start(bufnr, { schema = function(buf, uri) return my_schema end })
lsp.stop(bufnr)
```

---

## LSP options

`lsp.start(bufnr, opts)` accepts:

| Field | Type | Default | Description |
|---|---|---|---|
| `schema` | `fun(buf, uri): table` | `nil` | Schema factory, called once per buffer on attach |
| `commands` | `table` | `nil` | Extra `vim.lsp.commands` handlers registered at startup |
| `debug_commands` | `boolean` | `false` | Enable debug dump requests |

---

## TOML pipeline

All pipeline modules are public and usable without the LSP:

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

`opts.schema` returns a [JSON Schema](https://json-schema.org/) table. Supported keywords: `type`, `enum`, `const`, string/numeric/array/object constraints, `allOf`, `anyOf`, `oneOf`, `not`, `if/then/else`, `dependentRequired`, `dependentSchemas`.

Conditional branches (`if/then`, `oneOf`) are resolved at runtime against the decoded document, so completions and validation react to the actual values in the file.

---

## Code actions

`lsp/code_action.lua` iterates `context.code_action_providers` — a list of functions, each with signature `(context, params) -> lsp.CodeAction[]`. To add actions, populate this list in the server before the handler runs. The typical approach is to extend the server-side context construction in `server.lua` to read providers from `initializationOptions`.

---

## Debug dumps

When `debug_commands = true` is passed to `lsp.start()`:

```lua
local lsp = require("tomltools.lsp")
lsp.dump(bufnr, "cst")          -- opens scratch buffer with CST dump
lsp.dump(bufnr, "decode_tree")  -- DecodeTree dump
lsp.dump(bufnr, "data")         -- decoded Lua table (vim.inspect)
```
