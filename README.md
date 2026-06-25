# tomltools

A dependency-free, **pure-Lua** TOML processing library: a lossless parser, a
decoder to Lua tables, an encoder back to TOML, a formatter, and a JSON Schema
(Draft 2020-12) validator with source ranges.

No C extensions, no external dependencies. Runs on **Lua 5.1+ and
LuaJIT**. Verified against the official [toml-test](https://github.com/toml-lang/toml-test)
suite (TOML 1.1).

---

## Features

- Hand-written recursive-descent TOML parser producing a lossless Concrete
  Syntax Tree (CST)
- Full TOML 1.1 decode, encode, and format pipeline
- JSON Schema Draft 2020-12 validator (partial subset) reporting errors with
  source ranges
- Structural path lookup at a `(row, col)` position — useful for editor tooling
  built on top of the library

---

## Installation

### LuaRocks

```sh
luarocks install --server=https://luarocks.org/dev tomltools
# or, from a checkout:
luarocks make
```

### Manual

Copy the `lua/` directory onto your `package.path`:

```lua
package.path = "/path/to/tomltools/lua/?.lua;/path/to/tomltools/lua/?/init.lua;" .. package.path
```

---

## Quick start

```lua
local toml = require("tomltools")

-- Parse + decode (and optionally validate against a JSON Schema)
local data, errors = toml.decode([[
title = "demo"

[server]
host = "localhost"
port = 8080
]])

print(data.title)       --> demo
print(data.server.port) --> 8080

-- Errors are normalised to { range = { r1, c1, r2, c2 }, message = "..." }
for _, e in ipairs(result.errors) do
    print(e.message)
end
```

### Validating against a schema

```lua
local schema = {
    type = "object",
    properties = {
        title  = { type = "string" },
        server = {
            type       = "object",
            properties = { port = { type = "integer", minimum = 1, maximum = 65535 } },
            required   = { "port" },
        },
    },
    required = { "title" },
}

local data, errors = toml.decode(text, schema)
-- errors now also includes schema violations, each with a source range
```

### Encoding

```lua
-- Whole document: returns a TOML string
toml.encode({ name = "hello", value = 42, server = { host = "localhost", port = 8080 } })

-- A single snippet as lines, for inserting into an existing document:
toml.encode_entry({ host = "localhost", port = 8080 }, { style = "table", key = "server" })
toml.encode_entry({ name = "build" }, { style = "aot", key = "task" })
```

### Formatting

```lua
local formatted, errors = toml.format(text)  -- normalised TOML, or nil + errors
```

### Top-level API (`require("tomltools")`)

| Function | Returns | Description |
|---|---|---|
| `parse(text, schema?)` | `{ ok, data, errors }` | Parse, decode, and optionally validate. Errors carry source ranges. |
| `decode(text)` | `data?, errors?` | Decode TOML to a Lua table. |
| `encode(value)` | `string` | Encode a Lua table to a complete TOML document. |
| `encode_entry(t, opts?)` | `string[]` | Encode a single snippet as lines. `opts.style` is `"inline"` (default), `"table"`, or `"aot"`. |
| `format(text)` | `string?, errors?` | Reformat a TOML document (preserves comments). |
| `validate(data, schema)` | `ok, errors` | Validate an already-decoded value against a JSON Schema. |
| `find_path(text, row, col)` | `PathNode[]?` | Structural TOML path at a 0-indexed position. |

---

## Lower-level modules

Every pipeline stage is a standalone module:

```lua
local parser    = require("tomltools.parser")     -- text  -> CST
local decoder   = require("tomltools.decoder")    -- CST   -> Lua table (+ DecodeTree)
local encoder   = require("tomltools.encoder")    -- table -> TOML text
local formatter = require("tomltools.formatter")  -- CST   -> formatted TOML
local validator = require("tomltools.validator")  -- (schema, data) -> ok, errors
```

```lua
-- Parse to a CST, then format it (round-trips through the CST)
local parsed = parser.parse(text)
print(formatter.format(parsed.cst))

-- Decode directly
local decoded = decoder.decode(text)
print(decoded.ok, decoded.data)
```

Empty TOML tables decode to objects, not arrays. Internally this is tracked with
`require("tomltools.std").empty_dict()` / `std.islist()` — small pure-Lua
helpers that distinguish an empty object from an empty array.

---

## Testing

Unit tests use [busted](https://lunarmodules.github.io/busted/); the conformance
suite uses [toml-test](https://github.com/toml-lang/toml-test).

```sh
make unit_test   # busted unit suite (spec/), pure Lua
make toml_test   # official toml-test conformance suite (TOML 1.1)
make test        # both
```

The toml-test harness (`tests/run_decoder.lua`, `tests/run_encoder.lua`) runs
under LuaJIT by default for Lua 5.1 numeric semantics; override with
`make toml_test LUA=lua5.1`.

---

## License

MIT
