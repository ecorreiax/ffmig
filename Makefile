ZIG ?= $(if $(shell command -v zig 2>/dev/null),zig,nix develop --command zig)
# The integration tests start PostgreSQL, which the nix dev shell provides.
PG_SHELL ?= $(if $(and $(shell command -v postgres 2>/dev/null),$(shell command -v zig 2>/dev/null)),,nix develop --command)

INSTALL := -p . --prefix-exe-dir .

ARGS ?=

.PHONY: build release run test integration fmt clean

build:
	$(ZIG) build $(INSTALL)

release:
	$(ZIG) build $(INSTALL) -Doptimize=ReleaseSafe

run:
	$(ZIG) build $(INSTALL) run -- $(ARGS)

test:
	$(ZIG) build test --summary all

integration:
	$(PG_SHELL) scripts/integration.sh

fmt:
	$(ZIG) fmt build.zig src tests

clean:
	rm -rf ffmig zig-out .zig-cache migrations ffmig.toml
