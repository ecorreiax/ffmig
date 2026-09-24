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

### 3. Apply the migration

```sh
ffmig migrate
```

Applied versions are recorded in a `schema_migrations` table. `migrate` checks every pending file before it runs anything, so a broken file never leaves a batch half-applied. Each migration runs in its own transaction.

Some statements, such as PostgreSQL's `CREATE INDEX CONCURRENTLY`, cannot run inside a transaction. A migration that needs them starts with `migration AddSlugIndex, transaction: false {`. If one of its statements fails, the ones before it are not undone and the migration stays pending, so keep such migrations small (see [Transactions](docs/mig.md#transactions)).

A migration that waits for a lock, say behind a long query on the table it alters, also blocks every query queued behind it. `lock_timeout` in `[migration]` makes it fail instead, and `statement_timeout` limits how long any one statement may run. Both take a duration such as `"5s"`, `"500ms"`, `"2min"` or `"0"` for no limit. When they are unset, the database server's settings apply.

`migrate` and `rollback` hold a lock on the database while they run, so several deploys starting at once apply each migration exactly once: the others wait, then find nothing left to do. A run gives up after 60 seconds of waiting; `--lock-wait <seconds>` changes that, and `--lock-wait 0` does not wait at all. `status` never waits.

### Commands

| Command          | Description                                            |
|------------------|--------------------------------------------------------|
| `init`           | Create `ffmig.toml` and the migrations directory       |
| `create`         | Create the database named by the database url          |
| `drop`           | Drop that database after confirmation (`--force`)      |
| `protect`        | Mark the database so that `drop` refuses it            |
| `unprotect`      | Remove that mark                                       |
| `new <name>`     | Create a timestamped migration file                    |
| `check [files]`  | Check `.mig` files (`--ast`, `--down`)                 |
| `sql <file>`     | Print the SQL for a migration (`--down` for rollback)  |
| `migrate`        | Apply every pending migration (`--lock-wait <s>`)      |
| `rollback`       | Undo the last migration (`--step <n>` for more)        |
| `status`         | List migrations as up or down                          |
| `help`           | Show usage                                             |

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
