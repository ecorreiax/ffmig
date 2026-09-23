ZIG ?= $(if $(shell command -v zig 2>/dev/null),zig,nix develop --command zig)

INSTALL := -p . --prefix-exe-dir .

ARGS ?=

.PHONY: build release run test fmt clean

build:
	$(ZIG) build $(INSTALL)

release:
	$(ZIG) build $(INSTALL) -Doptimize=ReleaseSafe

run:
	$(ZIG) build $(INSTALL) run -- $(ARGS)

test:
	$(ZIG) build test --summary all

fmt:
	$(ZIG) fmt build.zig src tests

clean:
	rm -rf ffmig zig-out .zig-cache
