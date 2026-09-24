# FFMig

Fast Forward Migrations is a lightweight database migration tool inspired by Active Record. It is built for speed and developer experience, and it gives you full schema management without lock-in.

> **Status:** early development (v0.1.0). PostgreSQL is the only supported database for now. The `.mig` language itself is database-neutral, so other dialects can be added later.

## Installation

```sh
# macOS
brew install ffmig

# Linux
curl -o- https://raw.githubusercontent.com/ecorreiax/ffmig/v0.0.1/install.sh | bash
```

## Usage

### 1. Set up a project

```sh
ffmig init
```

This creates a `migrations/` directory and an `ffmig.toml`:

```toml
[migration]
path = "migrations"
# Fail a migration that waits longer than this for a lock, instead of
# blocking every query queued behind it:
# lock_timeout = "5s"

[database]
url = "${DATABASE_URL}"
```

If the database does not exist yet, create it:

```sh
ffmig create
```

`ffmig drop` removes it again, `schema_migrations` included, so `create` and `migrate` start from an empty database. It shows the server and asks you to type the database name first; in scripts, where there is no terminal to ask on, pass `--force`.

### 2. Write a migration

```sh
ffmig new create_users
# creates migrations/20260923140512_create_users.mig
```

Edit the generated file:

```sh
migration CreateUsers {
  change {
    create_table :users, id: :uuid {
      string :email, null: false
      string :phone, null: false

      string :name, null: false

      timestamps
    }

    add_index :users, :email, unique: true
    add_index :users, :phone, unique: true
  }
}
```

Later migrations evolve the schema with `rename_table`, `change_column`, `change_column_null`, `change_column_default`, `rename_index`, `add_foreign_key` and the rest of the [operations](docs/mig.md#operations). Inside `change`, ffmig derives the rollback; an operation that replaces something takes what it replaces, so the rollback can put it back:

```sh
migration WidenUserAge {
  change {
    change_column :users, :age, :bigint, from: :integer
    change_column_default :users, :role, from: nil, to: "member"
  }
}
```

`rename_table` also renames the indexes and foreign keys that ffmig named after the table, so later migrations can keep using their default names.

For what the language does not model, such as extensions, views, triggers or data backfills, write `up` and `down` blocks and use `execute` with raw SQL, usually in a `"""` multi-line string:

```sh
migration CreateActiveUsers {
  up {
    execute """
      CREATE VIEW active_users AS
      SELECT * FROM users WHERE deleted_at IS NULL
      """
  }
  down {
    execute "DROP VIEW active_users"
  }
}
```

`execute` is not allowed in `change`, since ffmig cannot derive the undo of SQL it does not read. See [Raw SQL](docs/mig.md#raw-sql).

### 3. Apply the migration

```sh
ffmig migrate
```

Each applied migration is recorded in a `schema_migrations` table, with a checksum of its file and the time it ran. `migrate` checks every pending file before it runs anything, so a broken file never leaves a batch half-applied. Each migration runs in its own transaction.

Some statements, such as PostgreSQL's `CREATE INDEX CONCURRENTLY`, cannot run inside a transaction. A migration that needs them runs them with `execute` and starts with `migration AddSlugIndex, transaction: false {`. If one of its statements fails, the ones before it are not undone and the migration stays pending, so keep such migrations small (see [Transactions](docs/mig.md#transactions)).

A migration that waits for a lock, say behind a long query on the table it alters, also blocks every query queued behind it. `lock_timeout` in `[migration]` makes it fail instead, and `statement_timeout` limits how long any one statement may run. Both take a duration such as `"5s"`, `"500ms"`, `"2min"` or `"0"` for no limit. When they are unset, the database server's settings apply.

`ffmig status` lists each migration as `up` or `down`, with the time (UTC) each `up` one ran. An applied migration whose file was edited afterwards shows `(changed)`, and `migrate` warns about it: the edit never runs, so write a new migration instead. `migrate --strict` refuses to run at all while an applied file has changed, which suits CI. A pending migration older than the last applied one, as happens when branches merge, still runs, with a note.

A `schema_migrations` table made by an earlier ffmig gains the checksum and time columns the next time ffmig reads it; its existing rows have neither, so they are never flagged.

`migrate` and `rollback` hold a lock on the database while they run, so several deploys starting at once apply each migration exactly once: the others wait, then find nothing left to do. A run gives up after 60 seconds of waiting; `--lock-wait <seconds>` changes that, and `--lock-wait 0` does not wait at all. `status` never waits.

### Commands

| Command          | Description                                                        |
|------------------|--------------------------------------------------------------------|
| `init`           | Create `ffmig.toml` and the migrations directory (`--path <dir>`)  |
| `create`         | Create the database named by the database url                      |
| `drop`           | Drop that database after confirmation (`--force`)                  |
| `protect`        | Mark the database so that `drop` refuses it                        |
| `unprotect`      | Remove that mark                                                   |
| `new <name>`     | Create a timestamped migration file                                |
| `check [files]`  | Check `.mig` files (`--ast`, `--down`)                             |
| `sql <file>`     | Print the SQL for a migration (`--down` for rollback)              |
| `migrate`        | Apply every pending migration (`--lock-wait <s>`, `--strict`)      |
| `rollback`       | Undo the last migration (`--step <n>` for more, `--lock-wait <s>`) |
| `status`         | List migrations as up or down, and when each ran                   |
| `help [command]` | Show usage, or one command's flags                                 |
| `version`        | Print the version (also `--version`)                               |

`ffmig <command> --help` (or `-h`) prints a command's flags. A flag's value can follow it or an `=`: `--step 2` or `--step=2`.

Every command that reads `ffmig.toml` also takes `--config <path>` to use another file, whose `path` is then relative to that file. Every command that connects takes `--url <url>` to use another database than the config names; so does a non-empty `FFMIG_DATABASE_URL` environment variable, which `--url` beats in turn. Both are taken as given, without `${VAR}` expansion. For `init`, the two set the file it writes and the url it writes into it.

```sh
ffmig status --url postgres://localhost/app_test
FFMIG_DATABASE_URL=postgres://localhost/app_test ffmig migrate
```

### Protecting production

Run `ffmig protect` once against any database you never want dropped. The mark is stored on the database server itself, not in `ffmig.toml`, so a changed `DATABASE_URL` or environment cannot get around it: `drop` refuses a protected database even with `--force`, until someone runs `ffmig unprotect`.

For a guarantee that does not depend on ffmig at all, have your application connect as a role that does not own the database; PostgreSQL then rejects `DROP DATABASE` from it whatever tool sends it.

## Contributing

Contributions are welcome. To get started:

### Requirements

- [nix](https://nixos.org) with flakes enabled
- A PostgreSQL server to run migrations against

## Setup

1. Fork the repository and create a branch from `main`.
2. Enter the dev shell, which provides Zig, libpq and PostgreSQL:

```sh
nix develop
```

3. Make your change, adding or updating tests in `tests/`.
4. Make sure everything passes:

```sh
make fmt           # format the code
make test          # unit tests, no database needed
make integration   # migrate / rollback / status against a real database
```

`make integration` starts a throwaway PostgreSQL server in a temporary directory. It listens only on a Unix socket and is removed afterwards, so it needs no setup.

5. Open a pull request with a clear description of what the change does and why.

## License

[MIT](LICENSE)
