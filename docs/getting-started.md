# Getting started

This page takes you from nothing to a migrated database and back. It
assumes a PostgreSQL server you can connect to.

## Install

Prebuilt packages will come with the first release. Until then, build
FFMig from source, either with nix:

```sh
git clone https://github.com/ecorreiax/ffmig
cd ffmig
nix build            # the binary is result/bin/ffmig
```

or with [Zig](https://ziglang.org) 0.16 or later and libpq installed:

```sh
zig build -Doptimize=ReleaseSafe   # the binary is zig-out/bin/ffmig
```

Put the binary on your `PATH` and check it runs:

```sh
$ ffmig --version
ffmig 0.1.0
```

## Set up a project

In your application's repository:

```sh
$ ffmig init
Created ffmig.toml
Created migrations/
```

`ffmig.toml` says where the migrations live and which database to use:

```toml
[migration]
path = "migrations"
# Fail a migration that waits longer than this for a lock, instead of
# blocking every query queued behind it:
# lock_timeout = "5s"

[database]
url = "${DATABASE_URL}"
```

`${DATABASE_URL}` is read from the environment, so the same file works on
every machine. Set it to your development database:

```sh
export DATABASE_URL=postgres://localhost/app_dev
```

If that database does not exist yet, create it:

```sh
$ ffmig create
Created database app_dev
```

[Configuration](configuration.md) lists every setting, and the other ways
to pick a database.

## Write a migration

```sh
$ ffmig new create_users
Created migrations/20260923140512_create_users.mig
```

The file name starts with a timestamp, which is the migration's version
and sets the order migrations run in. Fill in the generated file:

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

A `change` block describes the change once. FFMig works out the rollback
itself: here, drop the index, then drop the table. For what the language
does not model, such as views, triggers or data backfills, write `up`
and `down` blocks with raw SQL instead. [The .mig language](language.md)
covers every operation.

## Check it and look at the SQL

`ffmig check` parses every migration and reports the first error in each,
with its position:

```sh
$ ffmig check
ok migrations/20260923140512_create_users.mig
```

`ffmig sql` prints the SQL a migration will run, without touching a
database. `--down` prints the rollback:

```sh
$ ffmig sql migrations/20260923140512_create_users.mig
CREATE TABLE "users" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "email" varchar NOT NULL,
  "name" varchar NOT NULL,
  "created_at" timestamp(6) NOT NULL,
  "updated_at" timestamp(6) NOT NULL
);
CREATE UNIQUE INDEX "index_users_on_email" ON "users" ("email");

$ ffmig sql --down migrations/20260923140512_create_users.mig
DROP INDEX "index_users_on_email";
DROP TABLE "users";
```

## Apply it

```sh
$ ffmig migrate
Migrated migrations/20260923140512_create_users.mig

$ ffmig status
up    2026-09-23 14:07:02 UTC  migrations/20260923140512_create_users.mig
```

`migrate` applies every pending migration, oldest first, each in its own
transaction. It records each one in a `schema_migrations` table, which
`status` reads.

## Undo it

```sh
$ ffmig rollback
Rolled back migrations/20260923140512_create_users.mig
```

While you are still writing a migration, `ffmig redo` rolls it back and
applies it again in one step.

Once a migration has been applied anywhere other than your machine,
leave its file alone and write a new migration for the next change. FFMig
keeps a checksum of every applied file and warns when one changes; see
[How it works](how-it-works.md#changed-files).

## Next steps

- [The .mig language](language.md): every operation, type and option.
- [Commands](commands.md): every command and flag.
- [How it works](how-it-works.md): tracking, transactions, locking and
  rollbacks.
- [Running in production](production.md): timeouts, locks, protecting
  databases and CI.
