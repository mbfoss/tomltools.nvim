# tomltools — pure-Lua TOML library.
#
#   make unit_test   run the busted unit suite (spec/)
#   make toml_test   run the official toml-test conformance suite
#   make test        both
#
# Overridable: LUA (interpreter for the toml-test harness; default luajit, for
# Lua 5.1 numeric semantics), BUSTED, TOML_TEST.

LUA       ?= luajit
BUSTED    ?= busted
TOML_TEST ?= toml-test
TESTS_DIR := tests

.PHONY: all
all: test

.PHONY: test
test: unit_test toml_test

.PHONY: unit_test
unit_test:
	@$(BUSTED)

.PHONY: toml_test
toml_test:
	@cd $(TESTS_DIR) && $(TOML_TEST) \
		test \
		--toml=1.1.0 \
		--color=never \
		--timeout=3s \
		--decoder="$(LUA) run_decoder.lua" \
		--encoder="$(LUA) run_encoder.lua" \
		--skip valid/integer/long \
		--skip valid/integer/float64-max \
		--skip encoder/integer/long
