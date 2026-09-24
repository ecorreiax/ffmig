# AGENTS.md

This file provides guidance to coding agents working with code in this repository.

ffmig is a migration CLI written in Zig (minimum 0.16.0) that links libpq. Migrations are written in a database-neutral `.mig` language, and ffmig turns them into SQL. PostgreSQL is the only dialect so far.

## Commands

The toolchain (Zig, libpq, pkg-config, PostgreSQL) comes from the nix flake: run `nix develop`, or let direnv load `.envrc`. The Makefile falls back to `nix develop --command` when `zig` is not on PATH.

```sh
make build          # builds ./ffmig in the repo root (not zig-out/)
make run ARGS="check --ast migrations/foo.mig"
make test           # unit + golden tests, no database needed
make integration    # starts a throwaway PostgreSQL on a Unix socket, runs tests/integration
make fmt            # zig fmt build.zig src tests
make clean          # also deletes ./migrations and ./ffmig.toml made by trying the CLI
```

`build.zig` has no test-filter option, so `make test` always runs the whole suite. `zig build integration` alone fails with `NoTestServer`: it needs `FFMIG_TEST_PGHOST`, which `scripts/integration.sh` sets.

## Architecture

`src/root.zig` is the library module (`ffmig`), and `src/main.zig` is a thin wrapper around it. Tests import the same module, so anything tested must be reachable from `src/root.zig`.

Pipeline for one migration:

1. **`src/mig/`** is the `.mig` front end: `lexer` → `parser` produces a generic call tree (`syntax.zig`), then `lower` checks it and builds the typed `ast.Migration`. `lower.zig` is the only module that reads `syntax`, and it holds every semantic check (operations, options, types, defaults, references). `reverse.zig` derives the `down` operations for `change` migrations (AST → AST). `print.zig` renders the AST for `check --ast` and the golden tests. `mig.parseMigration` does parse and lower in one call.
2. **`src/sql/`** generates SQL from `ast.Operation`s. `sql/root.zig` holds the shape of each statement, shared by all dialects. Each dialect file (`sql/postgres.zig`) holds only its spellings: types, quoting, primary keys, literals, named defaults. It also writes the `schema_migrations` tracking statements and the database-level statements for create, drop and protect. `Statements` adds an `add_index` after each reference column that asks for an index.
3. **`src/db/`** is the connection layer: `Db` is a vtable interface (`exec`, `query`, `server`, `close`), and `db/postgres.zig` is the libpq driver. The URL scheme picks both the driver and the dialect (`dialectFor`).
4. **`src/commands/`** holds one file per command, each exposing `run(env, args, out, err) u8`, registered in `commands/root.zig` (the `Command` enum and the `run` switch) and in the usage text in `src/cli.zig`. `commands/migrations.zig` holds what the database commands share: loading `ffmig.toml` and the migration files, connecting, taking the migration lock (a PostgreSQL advisory lock that `migrate` and `rollback` hold for the whole run), reading recorded versions, and running one migration together with its tracking row. `commands/database.zig` does the same for create, drop, protect and unprotect, which connect to the maintenance database (`db.admin`).

Commands never touch process globals. The IO, cwd, allocator, environment and stdin all come in through `commands.Env`, and output goes to the writers passed in, so tests run commands against a temporary directory. `stdin` is null when it is not a TTY, and commands that need confirmation (`drop`) then refuse unless given `--force`.

Adding a dialect means a new `sql.Dialect` value, a `sql/<dialect>.zig`, a driver in `db/`, and a scheme in `dialectFor`. The exhaustive `switch` statements then point to what is still missing. Callers ask `sql.capabilities(dialect)` for facts about the database rather than testing for a dialect.

## The `.mig` language spec

`docs/mig.md` is the specification. The lexer, parser and lowering implement what it says, and a disagreement between the doc and the code is a bug in one of them. Language changes go in both places.

## Tests

- `tests/root.zig` imports every test file and runs `refAllDecls` over the public modules. A new test file must be added there.
- Golden tests are read at runtime from the project root:
  - `tests/mig/<case>.mig` pairs with `<case>.ast` (the expected `print` output) or `<case>.err` (the expected `line:col: message`). `doc_*` cases mirror examples in `docs/mig.md`, and `err_*` cases cover rejected input.
  - `tests/sql/<case>.mig` pairs with `<case>.<dialect>.sql`, which holds `-- up` and `-- down` sections. Every `.mig` is checked against every dialect in `sql.Dialect`.
  - When a golden file is missing, the test prints the actual output, which can be pasted in after checking it.
- `tests/integration/root.zig` runs commands through the CLI router against a real server, with a fresh database per test (the name passed to `Fixture.init` must be unique).
