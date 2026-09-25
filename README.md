# FFMig

Fast Forward Migrations is a lightweight database migration tool inspired by Active Record. It is built for speed and developer experience, and it gives you full schema management without lock-in.

Migrations are written in [.mig](MIG.md), a small database-neutral language with its own lexer, parser and tokenizer, and FFMig turns them into SQL. 

> **Status:** early development (v0.1.0). PostgreSQL is the only supported database for now. The `.mig` language itself is database-neutral, so other dialects can be added later.

## Getting started

### Install

**macOS** (Homebrew):

```sh
brew tap ecorreiax/tap
brew install ffmig
```

**Linux** (`ffmig-linux-amd64`, or `ffmig-linux-arm64` on ARM). FFMig uses libpq, PostgreSQL's client library, which the first line installs:

```sh
sudo apt-get install -y libpq5    # Debian, Ubuntu; on Fedora and RHEL: sudo dnf install -y libpq
sudo curl -fsSL -o /usr/local/bin/ffmig https://github.com/ecorreiax/ffmig/releases/latest/download/ffmig-linux-amd64
sudo chmod +x /usr/local/bin/ffmig
```

**Windows** (Scoop):

```sh
scoop bucket add ecorreiax https://github.com/ecorreiax/scoop-bucket
scoop install ffmig
```

**Docker:**

```sh
docker run --rm -it --network=host ghcr.io/ecorreiax/ffmig --help
```

To run it on a project, mount the project directory: `docker run --rm --network=host -v "$PWD:/app" -e DATABASE_URL ghcr.io/ecorreiax/ffmig migrate`.

Check it runs:

```sh
$ ffmig --version
ffmig 0.1.0
```

FFMig works with PostgreSQL 13 or later, and connects with TLS whenever the database URL asks for it (`?sslmode=require`), as managed databases do. If it fails to start with `libpq.so.5: cannot open shared object file` or `Library not loaded: libpq.5.dylib`, libpq is missing: install it as above, or with `brew install libpq` on macOS.

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
dump            # Write the database schema to schema.sql
load            # Create the schema from schema.sql in an empty database
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

#### Load
- `--force`: Load even if the database already records applied migrations

A migration that needs statements which cannot run in a transaction, such as `add_index ..., algorithm: :concurrently`, declares `transaction: false`; its statements then run one at a time. See [MIG.md](MIG.md).

### Schema dump

`ffmig dump` writes the database's schema to `schema.sql`, as `pg_dump --schema-only` prints it, followed by the migrations it has applied. Committing it makes each pull request show what a migration really changed:

```sh
$ ffmig dump
Dumped the schema to schema.sql
```

`ffmig load` creates that schema in an empty database, with its migrations recorded as applied, which is faster than replaying every migration for a new development or test database:

```sh
$ ffmig create
Created database app_test
$ ffmig load
Loaded the schema from schema.sql
```

FFMig removes from the file what changes from one run or one `pg_dump` version to the next (its version numbers, settings and random keys), so dumping the same schema twice gives the same file. `dump` runs `pg_dump`, which comes with the PostgreSQL client tools (not with FFMig, nor in its Docker image) and must be the same major version as the server or newer.

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

To keep the tables in a PostgreSQL schema other than the default one, name it in `[database]`:

```toml
[database]
url = "${DATABASE_URL}"
schema = "billing"
```

Every command that connects then works in that schema only: migrations create their tables there, and `schema_migrations` lives there too. The `.mig` files stay the same. FFMig does not create the schema; create it once with `CREATE SCHEMA billing`. `dump` then dumps only that schema.

`[dump]` configures `dump` and `load`, and is optional:

```toml
[dump]
path = "db/schema.sql"    # Where dump writes and load reads (default: schema.sql)
pg_dump = "/opt/homebrew/opt/postgresql@17/bin/pg_dump"   # The pg_dump to run (default: pg_dump on PATH)
auto = true               # Dump after every migrate, rollback and redo
```

`path` is relative to the config file. With `auto = true`, a `migrate`, `rollback` or `redo` that changes the database writes the file too, so it never falls behind the migrations.

## Contributing

Contributions are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) provides all the information on how to set up the development environment, run the tests and open a pull request.

## License

[MIT](LICENSE)
