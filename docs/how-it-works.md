# How it works

## Versions and order

A migration's version is the timestamp at the start of its file name,
such as `20260923140512` in `20260923140512_create_users.mig`.
Migrations run in version order. `ffmig new` writes the current UTC time,
so a new migration sorts after the ones before it.

A pending migration older than the newest applied one, as happens when
two branches each add a migration and then merge, still runs. `migrate`
prints a note about it:

```
ffmig: note: migrations/20260922100000_add_slug.mig is older than the last applied migration 20260923140512
```

## Checking before running

`migrate` parses and checks every pending file before it runs any of
them, and `rollback` derives the down plan of every migration it will
undo first. A typo in the third of five migrations stops the run before
the first one starts, instead of leaving the batch half-applied.

## The tracking table

FFMig records applied migrations in a `schema_migrations` table in the
migrated database, which it creates on first use:

| Column       | Holds |
|--------------|-------|
| `version`    | The migration's version |
| `checksum`   | A SHA-256 checksum of the file as it was when it ran |
| `applied_at` | When it ran |

`migrate` inserts a row for each migration it applies, and `rollback`
deletes it. A `schema_migrations` table made by an older FFMig gains the
`checksum` and `applied_at` columns the next time FFMig reads it; its
existing rows have neither, so they are never flagged as changed.

## Transactions

Each migration runs in its own transaction, together with its tracking
row. If any statement fails, the whole migration is undone and stays
pending, and the migrations before it stay applied. `--dry-run` prints
exactly that:

```sql
-- migrations/20260924091500_add_role_to_users.mig
BEGIN;
ALTER TABLE "users" ADD COLUMN "role" varchar DEFAULT 'member' NOT NULL;
INSERT INTO "schema_migrations" ("version", "checksum") VALUES ('20260924091500', 'f5f8b5…');
COMMIT;
```

Some statements cannot run inside a transaction, such as PostgreSQL's
`CREATE INDEX CONCURRENTLY`. A migration that needs them turns the
transaction off:

```mig
migration AddSlugIndex, transaction: false {
  up {
    execute "CREATE INDEX CONCURRENTLY index_posts_on_slug ON posts (slug)"
  }
  down {
    execute "DROP INDEX CONCURRENTLY index_posts_on_slug"
  }
}
```

Its statements then run one at a time, and the tracking row is written
after the last one. If a statement fails, the ones before it are not
undone and the migration stays pending, so keep such migrations to one
statement where you can. See [Transactions](language.md#transactions) in
the language reference.

## Reversing `change` migrations

Inside `change`, FFMig derives the rollback by inverting each operation,
in reverse order: `create_table` becomes `drop_table`, `add_index`
becomes `remove_index`, and so on. For that to work, every operation has
to carry what is needed to undo it. `remove_column` needs the column's
type and options to add it back, and `change_column` needs `from:` to
know the type to change back to:

```mig
migration WidenUserAge {
  change {
    change_column :users, :age, :bigint, from: :integer
    change_column_default :users, :role, from: nil, to: "member"
  }
}
```

An operation without that information is still valid. `ffmig check`
warns about it, and `rollback` refuses the migration before running
anything. For such changes, and for raw SQL, write `up` and `down`
blocks instead; nothing is derived from them. The
[Reversibility](language.md#reversibility) table lists the undo of every
operation.

`ffmig check --down` shows the derived plan, and `ffmig sql --down` the
SQL it becomes.

### Renaming tables

`rename_table :users, :accounts` also renames what is named after the
table: the indexes and foreign keys FFMig named (`index_users_on_email`
becomes `index_accounts_on_email`, `fk_users_on_team_id` becomes
`fk_accounts_on_team_id`), and PostgreSQL's primary key `users_pkey` and
id sequence `users_id_seq`. Later migrations can then keep using the
default names. It finds them in the database's catalog when it runs, and
leaves any other name alone.

## The migration lock

`migrate`, `rollback` and `redo` hold a lock on the database for the
whole run (a PostgreSQL advisory lock). When several deploys start at
once, one of them applies the pending migrations while the others wait,
then find nothing left to do. Each migration runs exactly once.

A run waits up to 60 seconds for the lock, then gives up.
`--lock-wait <seconds>` changes that, and `--lock-wait 0` does not wait at
all. `status` and any `--dry-run` never take the lock.

## Changed files

When a migration is applied, its checksum is recorded. If the file is
edited afterwards, the edit never runs: the database already has the
old version. FFMig tells you rather than letting the file and the
database quietly disagree:

- `status` marks the migration `(changed)`.
- `migrate` warns about it, and carries on with the pending migrations.
- `migrate --strict` refuses to run at all, which suits CI.

```sh
$ ffmig migrate --strict
ffmig: migrations/20260923120000_create_teams.mig has changed since it was applied; its changes will not run
ffmig: nothing was migrated
```

To change a schema that a migration already set up, write a new
migration. While a migration exists only on your machine, `ffmig redo`
is the way to re-run it after editing it.

## Dry runs

`migrate --dry-run` and `rollback --dry-run` print the SQL they would
send, one `-- <file>` section per migration with its `BEGIN`, `COMMIT`
and tracking statement, and run none of it. They take no lock, and they
read the database only to find what is pending. `ffmig sql` prints the
statements of one file without any database.
