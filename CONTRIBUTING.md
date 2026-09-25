# Contributing to FFMig

Contributions are welcome: bug reports, fixes, new operations and new database dialects alike. This page explains how to get the project running locally and what a pull request needs.

## What you need

- [nix](https://nixos.org/download) with [flakes enabled](https://nixos.wiki/wiki/Flakes#Enable_flakes_temporarily)
- Optionally, [direnv](https://direnv.net) with [nix-direnv](https://github.com/nix-community/nix-direnv), to enter the dev shell automatically

That is all. The nix dev shell provides the rest at pinned versions: Zig (0.16 or later), libpq, pkg-config, PostgreSQL for the integration tests, and ZLS for your editor.

You can work without nix if you install Zig 0.16+, libpq, pkg-config and PostgreSQL yourself, but the dev shell is the setup the project is tested with.

## Set up

```sh
git clone https://github.com/ecorreiax/ffmig
cd ffmig
nix develop
```

`nix develop` opens a shell with the toolchain on `PATH`. With direnv, run `direnv allow` once instead, and the shell loads whenever you `cd` into the repository (from `.envrc`).

The Makefile falls back to `nix develop --command` when `zig` is not on `PATH`, so `make` targets also work from outside the shell.

## Build and run

```sh
make build                                   # builds ./ffmig in the repo root
make run ARGS="check --ast examples/add_index.mig"
./ffmig --help
```

`make release` builds with `-Doptimize=ReleaseSafe`. To try the database commands, point FFMig at any PostgreSQL server you can reach:

```sh
./ffmig init
export DATABASE_URL=postgres://localhost/ffmig_dev
./ffmig create
./ffmig new create_users
./ffmig migrate
```

`make clean` deletes the build output, and also the `migrations/` and `ffmig.toml` that trying the CLI in the repository creates.

## Test

```sh
make fmt           # format the code with zig fmt
make test          # unit and golden tests, no database needed
make integration   # integration tests against a real PostgreSQL
```

`make integration` starts a throwaway PostgreSQL server on a Unix socket in a temporary directory (`scripts/integration.sh`), runs `tests/integration`, and stops the server afterwards. Nothing needs to be running beforehand, and it never touches another server.

The tests live in `tests/`:

- `tests/mig/` holds golden tests for the `.mig` front end: each `<case>.mig` pairs with `<case>.ast` (the expected parse) or `<case>.err` (the expected error).
- `tests/sql/` holds golden tests for the generated SQL: each `<case>.mig` pairs with `<case>.<dialect>.sql`, with `-- up` and `-- down` sections.
- When a golden file is missing, the test prints the actual output, which you can paste in after checking it.
- `examples/` holds one `.mig` per operation or feature, and every one must parse, be reversible and write SQL.
- A new test file must be imported from `tests/root.zig`.

## Where things are

`AGENTS.md` describes the architecture in detail. In short:

- `src/mig/` is the `.mig` front end: lexer, parser, and lowering to a typed AST, which holds every semantic check.
- `src/sql/` turns the AST into SQL; each dialect file holds only its spellings.
- `src/db/` is the connection layer, with the libpq driver.
- `src/commands/` holds one file per CLI command.
- `MIG.md` is the language specification. The code implements what it says, so a language change goes in both.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Make your change, adding or updating tests in `tests/`, and an example in `examples/` for a new operation.
3. Update the docs the change affects: `MIG.md` for the language, and `README.md` for a command's flags or output or for `ffmig.toml`.
4. Make sure `make fmt`, `make test` and `make integration` all pass.
5. Open a pull request with a clear description of what the change does and why.

Found a bug but have no fix? Open an issue with the migration file, the command you ran, and what it printed.
