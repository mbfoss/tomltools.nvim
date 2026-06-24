-- tests/run_decoder.lua
-- Run with: luajit tests/run_decoder.lua   (or any Lua 5.1+ interpreter)
-- Reads TOML from stdin, writes toml-test tagged JSON to stdout.
-- Exits non-zero on invalid TOML.

-- Resolve module paths relative to this script so it works from any cwd.
local here = (arg[0] or "tests/run_decoder.lua"):match("^(.*[/\\])") or "./"
package.path = here .. "?.lua;"
    .. here .. "../lua/?.lua;"
    .. here .. "../lua/?/init.lua;"
    .. package.path

local helper = require("toml_test_helper")

local toml = io.read("*a")
local json, err = helper.parse_to_tagged_json(toml)

if err then
    io.stderr:write(err .. "\n")
    os.exit(1)
end

io.write(json .. "\n")
