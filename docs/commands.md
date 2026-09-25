# Commands

```
ffmig <command> [flags]
```

`ffmig help <command>`, `ffmig <command> --help` and `ffmig <command> -h`
print a command's flags. A flag's value can follow it or an `=`:
`--step 2` and `--step=2` are the same.

Every command exits with status 0 when it succeeds and 1 when it fails,
after printing why on standard error.

## Shared flags

| Flag              | Taken by                         | Meaning |
|-------------------|----------------------------------|---------|
| `--config <path>` | every command that reads the config | Use this config file instead of `ffmig.toml`. Its `path` is relative to the file. |
| `--url <url>`     | every command that connects      | Use this database instead of the one `FFMIG_DATABASE_URL` or the config names. |
| `-h`, `--help`    | every command                    | Print the command's usage and flags. |

A command that connects picks its database URL from the first of these
that is set:

1. `--url`
2. the `FFMIG_DATABASE_URL` environment variable, when it is not empty
3. `url` in the config's `[database]` section, with each `${VAR}` replaced
   by that environment variable

The first two are used as given, without `${VAR}` expansion. The URL's
scheme picks the database: `postgres://` or `postgresql://`.

```sh
ffmig status --url postgres://localhost/app_test
FFMIG_DATABASE_URL=postgres://localhost/app_test ffmig migrate
```

## Project

### init

```
ffmig init [--path <dir>] [--url <url>] [--config <path>]
```

Creates `ffmig.toml` and the migrations directory.

| Flag              | Meaning |
|-------------------|---------|
| `--path <dir>`    | Migrations directory, relative to the config (default: `migrations`) |
| `--url <url>`     | Database URL to write into the config (default: `${DATABASE_URL}`) |
| `--config <path>` | Config file to create (default: `ffmig.toml`) |

```sh
$ ffmig init
Created ffmig.toml
Created migrations/
```

### new

```
ffmig new [--config <path>] <name>
```

Creates `<timestamp>_<name>.mig` in the migrations directory, with an
empty `change` block. The timestamp is the current UTC time, and it is
the migration's version. The migration is named after the file, in
PascalCase.

```sh
$ ffmig new create_users
Created migrations/20260923140512_create_users.mig
```

```mig
migration CreateUsers {
  change {
  }
}
```

### check

```
ffmig check [--ast] [--down] [--config <path>] [file...]
```

Checks `.mig` files, by default every one in the migrations directory,
and reports the first error in each. It needs no database.

| Flag     | Meaning |
|----------|---------|
| `--ast`  | Print each parsed migration |
| `--down` | Print it as up and down, deriving down for a `change` migration |

```sh
$ ffmig check
ok migrations/20260923140512_create_users.mig
bad.mig:3:5: unknown operation 'add_idx'
    add_idx :users, :email
    ^~~~~~~
```

`check` also warns about an operation in `change` that cannot be
reversed, since `rollback` would fail on it.

### sql

```
ffmig sql [--down] <file>
```

Prints the PostgreSQL for a migration's up plan. It reads neither the
config nor a database.

| Flag     | Meaning |
|----------|---------|
| `--down` | Print the down plan instead |

```sh
$ ffmig sql --down migrations/20260923140512_create_users.mig
DROP INDEX "index_users_on_email";
DROP TABLE "users";
```

## Migrations

### migrate

```
ffmig migrate [flags]
```

Applies every pending migration, oldest first. It checks every pending
file before it runs anything, then runs each migration in its own
transaction together with its row in `schema_migrations`.

| Flag              | Meaning |
|-------------------|---------|
| `--to <version>`  | Stop after the migration with this version |
| `--dry-run`       | Print the SQL that would run, and run nothing |
| `--fake`          | Record the migrations as applied without running them, to adopt a database that already has them |
| `--lock-wait <s>` | Wait up to `s` seconds for another `migrate` or `rollback` to finish (default: 60; 0: do not wait) |
| `--strict`        | Refuse to run if an applied file has changed since it ran |

```sh
$ ffmig migrate
Migrated migrations/20260923120000_create_teams.mig
Migrated migrations/20260923140512_create_users.mig

$ ffmig migrate
Nothing to migrate
```

A pending migration older than the newest applied one, as happens when
branches merge, still runs, with a note. See [How it
works](how-it-works.md) for the lock, dry runs and changed files.

### rollback

```
ffmig rollback [flags]
```

Undoes the last applied migration: runs its down plan and deletes its
row, in one transaction.

| Flag              | Meaning |
|-------------------|---------|
| `--step <n>`      | Undo the last `n` instead |
| `--to <version>`  | Undo every migration newer than this one, which stays applied |
| `--dry-run`       | Print the SQL that would run, and run nothing |
| `--lock-wait <s>` | As for `migrate` |

```sh
$ ffmig rollback
Rolled back migrations/20260924091500_add_role_to_users.mig
```

`rollback` parses every file it will undo and derives its down plan
before it runs anything, so an irreversible migration stops it before it
starts.

### redo

```
ffmig redo [--step <n>] [--lock-wait <s>]
```

Undoes the last applied migration and applies it again: the usual loop
while writing one. The lock is held across both halves.

| Flag              | Meaning |
|-------------------|---------|
| `--step <n>`      | Redo the last `n` instead |
| `--lock-wait <s>` | As for `migrate` |

```sh
$ ffmig redo
Rolled back migrations/20260923140512_create_users.mig
Migrated migrations/20260923140512_create_users.mig
```

### status

```
ffmig status
```

Lists every migration as `up` or `down`, with when each `up` one ran
(in UTC). An applied migration whose file was edited afterwards shows
`(changed)`, and one whose file is gone shows `(no file)`. `status` never
waits for the migration lock.

```sh
$ ffmig status
up    2026-09-25 01:56:24 UTC  migrations/20260923120000_create_teams.mig (changed)
up    2026-09-25 01:56:24 UTC  migrations/20260923140512_create_users.mig
down                           migrations/20260924091500_add_role_to_users.mig
```

## Databases

These commands connect to the server's maintenance database to act on
the database the URL names.

### create

```
ffmig create
```

Creates the database, unless it exists.

```sh
$ ffmig create
Created database app_dev
```

### drop

```
ffmig drop [--force]
```

Drops the database, `schema_migrations` included, after showing the
server and asking you to type the database's name. A
[protected](#protect) database is refused.

| Flag      | Meaning |
|-----------|---------|
| `--force` | Do not ask. Needed where there is no terminal to ask on, such as in scripts |

### protect

```
ffmig protect
```

Marks the database so that `drop` refuses it, even with `--force`, until
`ffmig unprotect`. The mark is stored on the database server, not in
`ffmig.toml`, so a different config or URL cannot get around it.

```sh
$ ffmig protect
Protected database app_dev

$ ffmig drop --force
ffmig: database app_dev is protected; run 'ffmig unprotect' first to drop it
```

### unprotect

```
ffmig unprotect
```

Removes the mark that `protect` sets, so `drop` works again.

## Other

### help

```
ffmig help [command]
```

Lists the commands, or prints one command's usage and flags. So do
`ffmig --help` and `ffmig <command> --help`.

### version

```
ffmig version
```

Prints the version. So does `ffmig --version`.

```sh
$ ffmig --version
ffmig 0.1.0
```
