# FFMig

Fast Forward Migrations is a lightweight database migration tool inspired by Active Record. It is built for speed and developer experience, and it gives you full schema management without lock-in.

Migrations are written in [.mig](MIG.md), a small database-neutral language with its own lexer, parser and tokenizer, and FFMig turns them into SQL. 

> **Status:** early development (v0.1.0). PostgreSQL is the only supported database for now. The `.mig` language itself is database-neutral, so other dialects can be added later.

## Getting started

### Install

**macOS** (Homebrew):

```sh
brew install ffmig
```

**Linux:**

```sh
sudo curl -fsSL -o /usr/local/bin/ffmig https://github.com/ecorreiax/ffmig/releases/latest/download/ffmig-linux-amd64
sudo chmod +x /usr/local/bin/ffmig
```

**Windows** (Scoop):

```sh
scoop install ffmig
```

**Docker:**

```sh
docker run --rm -it --network=host ghcr.io/ecorreiax/ffmig --help
```

Check it runs:

```sh
$ ffmig --version
ffmig 0.1.0
```

### Set up a project

In the root directory of your application, create **ffmig.toml** and the **migrations** directory by running the `init` command:

```sh
$ ffmig init
Created ffmig.toml
Created migrations/
```

Next you need to export the database URL in your shell.

```sh
$ export DATABASE_URL=postgres://localhost/app_dev
```

With everything in place, you can create the database if it does not exist yet:

```sh
$ ffmig create
Created database app_dev
```

### Write a migration

```sh
$ ffmig new create_users
Created migrations/20260923140512_create_users.mig
```

The file name starts with a timestamp, which is the migration's version and sets the order migrations run in. Fill in the generated file:

```mig
migration CreateUsers {
  change {
    create_table :users, id: :uuid {
      string :email, null: false
      string :name, null: false

      timestamps
    }

    add_index :users, :email, unique: true
  }
}
```

### Check the migration

```sh
$ ffmig check
ok migrations/20260923140512_create_users.mig
```

### Apply the migration

```sh
$ ffmig migrate
Migrated migrations/20260923140512_create_users.mig

$ ffmig status
up    2026-09-23 14:07:02 UTC  migrations/20260923140512_create_users.mig
```

Each migration runs in its own transaction, together with its row in the `schema_migrations` table, which FFMig creates on first use.

## Commands

```
ffmig <command> [flags]
```

This section lists all the commands and their description. For usage and flags of a specific command, run `ffmig <command> --help`.

```
init            # Create ffmig.toml and the empty migrations directory
create          # Create the database named by the database url
drop            # Drop that database and schema_migrations
protect         # Prevent the database from being dropped
unprotect       # Remove the drop protection
new             # Create a migration file
check           # Check the migration files
sql             # Print the SQL translation for a migration
migrate         # Apply every pending migration
rollback        # Undo the last applied migration
redo            # Undo the last applied migration and apply it again
status          # List migrations as up or down, with when each ran
help            # Show this message, or a command's flags
version         # Print the version
```

### Command Line Options

#### Migrate
- `--to <version>`: Stop after this migration
- `--dry-run`: Print the SQL that would run, with its `BEGIN`, `COMMIT` and tracking statement, and run nothing
- `--fake`: Record the migrations as applied without running them, to adopt a database that already has them
- `--strict`: Refuse to run if an applied file has changed since it ran; suits CI
- `--lock-wait <s>`: Wait up to `s` seconds for another run to finish (default: 60; 0: do not wait)

#### Rollback
- `--to <version>`: Undo every migration newer than this
- `--step <n>`: Act on the last `n` migrations instead of one
- `--dry-run`: Print the SQL that would run, with its `BEGIN`, `COMMIT` and tracking statement, and run nothing
- `--lock-wait <s>`: Wait up to `s` seconds for another run to finish (default: 60; 0: do not wait)

#### Redo
- `--step <n>`: Act on the last `n` migrations instead of one
- `--lock-wait <s>`: Wait up to `s` seconds for another run to finish (default: 60; 0: do not wait)

A migration that needs statements which cannot run in a transaction, such as `CREATE INDEX CONCURRENTLY`, declares `transaction: false`; its statements then run one at a time. See [MIG.md](MIG.md).

## Configuration

FFMig reads `ffmig.toml` from the current directory, or the file that `--config` names. `ffmig init` writes one:

```toml
[migration]
path = "migrations"

[database]
url = "${DATABASE_URL}"
```

- `path` is the migrations directory, relative to the config file.
- `url` is the database URL. `${VAR}` is replaced by the environment variable `VAR`. `--url` or a non-empty `FFMIG_DATABASE_URL` takes precedence over it.

`[migration]` also takes two optional timeouts:

```toml
[migration]
path = "migrations"
lock_timeout = "5s"         # Fail a statement that waits longer than this for a lock
statement_timeout = "30s"   # Fail a statement that runs longer than this
```

The timeouts take a whole number followed by `ms`, `s`, `min` or `h`, such as `"500ms"`, `"5s"` or `"2min"`, or `"0"` for no limit. When one is unset, the server's own setting applies. They apply to `migrate`, `rollback` and `redo`.

Setting `lock_timeout` is worth it in production: a migration stuck behind a long query's lock otherwise makes every query after it wait too. With a timeout, the migration fails, is undone, and stays pending to run again later.

## Contributing

Contributions are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) provides all the information on how to set up the development environment, run the tests and open a pull request.

## License

[MIT](LICENSE)
