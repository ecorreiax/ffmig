ZIG ?= $(if $(shell command -v zig 2>/dev/null),zig,nix develop --command zig)
# The integration tests start PostgreSQL, which the nix dev shell provides.
PG_SHELL ?= $(if $(and $(shell command -v postgres 2>/dev/null),$(shell command -v zig 2>/dev/null)),,nix develop --command)
NPM ?= $(if $(shell command -v npm 2>/dev/null),npm,nix develop --command npm)

INSTALL := -p . --prefix-exe-dir .

ARGS ?=

.PHONY: build release run test integration fmt clean docs docs-build

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

# The docs site: a local preview at http://localhost:5173, and the static
# build in docs/.vitepress/dist.
docs: docs/node_modules
	$(NPM) --prefix docs run dev

docs-build: docs/node_modules
	$(NPM) --prefix docs run build

docs/node_modules: docs/package.json docs/package-lock.json
	$(NPM) --prefix docs ci
	@touch $@

clean:
	rm -rf ffmig zig-out .zig-cache migrations ffmig.toml docs/.vitepress/dist docs/.vitepress/cache
