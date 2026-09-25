# AGENTS.md

This file provides guidance to coding agents working with code in this repository.

ffmig is a migration CLI written in Zig (minimum 0.16.0) that links libpq. Migrations are written in a database-neutral `.mig` language, and ffmig turns them into SQL. PostgreSQL is the only dialect so far.

## Using ffmig

`ffmig help` lists the commands and `ffmig <command> --help` gives each one's flags; `README.md` walks through them with their output. What the help text leaves out:

- The usual flow is `init` (writes `ffmig.toml` and `migrations/`), `create`, `new <name>`, edit the file, `check`, `sql <file>`, `migrate`, `status`. `rollback` and `redo` act on the newest applied migrations.
- A migration's version is the timestamp its file name starts with (`20260923140512_create_users.mig`), and versions set the run order. `new` writes the file with an empty `change {}` and the PascalCase name.
- The database URL is `--url`, else `FFMIG_DATABASE_URL`, else `[database] url` in the config, where `${VAR}` expands (`init` writes `${DATABASE_URL}`). The URL scheme picks the database; only `postgres://` exists.
- Applied migrations are rows in `schema_migrations` (version, SHA-256 of the file, apply time), created on first use. Editing an applied file changes nothing in the database: `migrate` warns (with `--strict`, refuses) and `status` flags the file. A schema change after that goes in a new migration.
- `migrate` parses every pending file before running any. Each migration runs in its own transaction together with its tracking row, and a failure stops the batch, keeping what already ran.
- `migrate`, `rollback` and `redo` hold an advisory lock for the whole run, so a second run waits (`--lock-wait`). `--dry-run` and `status` take no lock.
- `check` and `sql` never connect to a database, so they are the way to verify a migration.
- `drop` asks for the database name, needs `--force` when stdin is not a TTY, and refuses a `protect`ed database even with `--force`.
- `[database] schema` in `ffmig.toml` makes every connecting command work in that PostgreSQL schema (it must exist; ffmig never creates it).
- `dump` runs `pg_dump` and writes `schema.sql` (`[dump] path`): the cleaned schema plus an insert of the applied versions. `load` runs that file against a database that records no migrations yet. `[dump] auto = true` dumps after every `migrate`, `rollback` and `redo`.

## Writing a migration

`MIG.md` is the language specification: every operation and its options, column types, references, defaults, reversibility, and the error messages. Read the sections for the operations you use before writing a migration. `examples/` holds one working file per operation.

```mig
migration CreatePosts {
  change {
    create_table :posts {
      references :user, null: false
      string :title, null: false, limit: 200
      boolean :published, null: false, default: false
      timestamps
    }

    add_index :posts, :title
  }
}
```

- A body is either `change { }`, where ffmig derives the undo, or both `up { }` and `down { }`, written by hand.
- Every operation in `change` must be reversible, which means carrying what its undo needs: `drop_table` its `id:` and column block, `remove_column` its type and options, `change_column` and `change_column_default` their `from:`, `remove_index` its column (and `unique: true` if the index was). The table in the Reversibility section of `MIG.md` lists them all. `check` warns about an irreversible operation in `change`.
- `execute "sql"` runs raw SQL, with `"""` for several lines, and is allowed only in `up` / `down`. `dialect: :postgres` marks it as PostgreSQL only.
- Table, column and type names are symbols: `add_column :users, :role, :integer`. Inside a table block the type is a bare word: `string :email`. Positional arguments come before labeled ones, there is no trailing comma, and a line break ends a statement unless a comma continues it.
- `add_index :t, [:a, :b]` indexes several columns; `where: "SQL"` makes it partial, and `algorithm: :concurrently` needs `transaction: false`. Names, default ones included, are at most 63 bytes.
- `create_table` gives a `bigint` primary key `id`, or `id: :uuid`, or none with `id: false`. `references :user` (the name without `_id`) adds the column `user_id`, a foreign key to `users` and an index; its `type:` must match the other table's `id:`.
- `transaction: false` after the migration name (`migration M, transaction: false {`) is for statements PostgreSQL refuses in a transaction, such as a concurrent index or `VACUUM`. A failure then leaves the earlier statements applied.
- `ffmig check --down <file>` prints the parsed migration with its derived down steps, and `ffmig sql [--down] <file>` prints the PostgreSQL.

## Development

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

1. **`src/mig/`** is the `.mig` front end: `lexer` → `parser` produces a generic call tree (`syntax.zig`); the lexer finds a `"""` string's end, and the parser strips its indentation, then `lower` checks it and builds the typed `ast.Migration`. `lower.zig` is the only module that reads `syntax`, and it holds every semantic check (operations, options, types, defaults, references). `reverse.zig` derives the `down` operations for `change` migrations (AST → AST). `print.zig` renders the AST for `check --ast` and the golden tests. `mig.parseMigration` does parse and lower in one call.
2. **`src/sql/`** generates SQL from `ast.Operation`s. `sql/root.zig` holds the shape of each statement, shared by all dialects. Each dialect file (`sql/postgres.zig`) holds only its spellings: types, quoting, primary keys, literals, named defaults. It also writes the `DO` block that follows a `rename_table` to rename the indexes, foreign keys, primary key and sequence named after the table (found in the catalog at run time), the `schema_migrations` tracking statements, and the database-level statements for create, drop and protect. `rename_table` and `change_column_null` with `default:` write several statements as one, which run together. `Statements` adds an `add_index` after each reference column that asks for an index. An `execute` is written as is; `sql.unsupported` reports one whose `dialect:` names another database, and `migrations.Project.parse` and `ffmig sql` check it before anything runs.
3. **`src/db/`** is the connection layer: `Db` is a vtable interface (`exec`, `query`, `server`, `close`; `query` returns every column, null for SQL `NULL`), and `db/postgres.zig` is the libpq driver. The URL scheme picks both the driver and the dialect (`dialectFor`). `db/pg_dump.zig` builds `pg_dump`'s arguments (the password goes in `PGPASSWORD`, never on the command line) and cleans its output for `ffmig dump`.
4. **`src/commands/`** holds one file per command, each exposing `run(env, args, out, err) u8` and a `usage` text that lists its flags, registered in `commands/root.zig` (the `Command` enum, the `run` and `usage` switches, and `Globals.of`) and in the usage text in `src/cli.zig`. Commands read their arguments with `commands/flags.zig` (`--name`, `--name value` or `--name=value`) and reject unknown flags with their usage. `cli.run` handles `help`, `version` and every `-h` / `--help` itself, and reads `--config` and `--url` into `Env` for the commands `Globals.of` names, so commands never see them. The version comes from `build.zig.zon` through the `build_options` module. `commands/migrations.zig` holds what the database commands share: loading the config (`ffmig.toml` or `--config`) and the migration files, picking the database URL (`resolveUrl`) and connecting, setting the `[migration]` timeouts, taking the migration lock (a PostgreSQL advisory lock that `migrate`, `rollback` and `redo` hold for the whole run; `--dry-run` takes none), reading the tracking table (upgrading one made by an older ffmig) and comparing file checksums with it, and running one migration together with its tracking row, in a transaction unless the migration has `transaction: false` (`apply`), or printing the same statements for `--dry-run` (`show`; both build them with `statements`). `redo` reuses `rollback.prepare`, which parses the files and derives their down plans before anything runs. `commands/database.zig` does the same for create, drop, protect and unprotect, which connect to the maintenance database (`db.admin`). `Project.connect` connects and switches to the `[database] schema`. `commands/dump.zig` runs `pg_dump` through `Env.run_program` and writes the dump file, which `commands/load.zig` runs; `dump.after` dumps after `migrate`, `rollback` and `redo` when `[dump] auto` is set.

Commands never touch process globals. The IO, cwd, allocator, environment, stdin and the way to run another program (`run_program`) all come in through `commands.Env`, and output goes to the writers passed in, so tests run commands against a temporary directory. `stdin` is null when it is not a TTY, and commands that need confirmation (`drop`) then refuse unless given `--force`.

Adding a dialect means a new `sql.Dialect` value (and the same in `ast.Dialect`, which `execute`'s `dialect:` names), a `sql/<dialect>.zig`, a driver in `db/`, and a scheme in `dialectFor`. The exhaustive `switch` statements then point to what is still missing. Callers ask `sql.capabilities(dialect)` for facts about the database rather than testing for a dialect.

## The `.mig` language spec

`MIG.md` is the specification. The lexer, parser and lowering implement what it says, and a disagreement between the doc and the code is a bug in one of them. Language changes go in both places.

## User docs

`README.md` is the user documentation: getting started, every command, and `ffmig.toml`. A change to a command's flags or output, or to the config, goes there. `CONTRIBUTING.md` covers the dev setup and the pull request checklist; keep it in step with the Makefile and the flake.

## Tests

- `tests/root.zig` imports every test file and runs `refAllDecls` over the public modules. A new test file must be added there.
- Golden tests are read at runtime from the project root:
  - `tests/mig/<case>.mig` pairs with `<case>.ast` (the expected `print` output) or `<case>.err` (the expected `line:col: message`). `doc_*` cases mirror examples in `MIG.md`, and `err_*` cases cover rejected input.
  - `tests/sql/<case>.mig` pairs with `<case>.<dialect>.sql`, which holds `-- up` and `-- down` sections. Every `.mig` is checked against every dialect in `sql.Dialect`.
  - When a golden file is missing, the test prints the actual output, which can be pasted in after checking it.
- `tests/docs.zig` checks that every ` ```mig ` block in `MIG.md` holding a whole migration parses.
- `examples/` holds one `.mig` per operation or feature. `tests/examples.zig` checks that each parses, is reversible, and writes SQL, so a language change that breaks an example fails `make test`.
- `tests/integration/root.zig` runs commands through the CLI router against a real server, with a fresh database per test (the name passed to `Fixture.init` must be unique).
