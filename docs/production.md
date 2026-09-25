# Running in production

## Review the SQL before it runs

`ffmig migrate --dry-run` against the production database prints what a
deploy would run, without running it or taking the migration lock.
Running it in CI, and posting the output on the pull request, lets
reviewers read the SQL along with the `.mig` file.

`ffmig sql <file>` prints one migration's SQL without any database, and
`ffmig sql --down <file>` its rollback.

## Lock timeouts

Most schema changes take a lock on the table they change. If a long
query holds a conflicting lock, the migration waits for it, and every
query that arrives after the migration waits behind the migration. A
migration stuck on a lock for a minute can stall the application for
that minute.

`lock_timeout` makes the migration fail instead:

```toml
[migration]
path = "migrations"
lock_timeout = "5s"
```

The migration is undone, stays pending, and can run again once the
long query is gone. `statement_timeout` limits how long any one
statement may run, lock or no lock. See
[Configuration](configuration.md#migration).

## Concurrent deploys

`migrate` takes a lock on the database for the whole run, so several
instances can run it at the same time on deploy: one applies the
migrations, and the others wait and then find nothing to do. A waiting
run gives up after 60 seconds; `--lock-wait <seconds>` changes that. See
[The migration lock](how-it-works.md#the-migration-lock).

## Building indexes without blocking writes

`CREATE INDEX` blocks writes to the table while it builds. PostgreSQL's
`CREATE INDEX CONCURRENTLY` does not, but it cannot run in a
transaction, so the migration has to turn its transaction off:

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

Keep such a migration to that one statement: without a transaction, a
failure part way leaves the statements before it applied.

## Keep history fixed in CI

Run `ffmig migrate --strict` in CI and deploys. It refuses to run if a
migration file was edited after it was applied, which would otherwise
mean the file and the database disagree. `ffmig check` needs no database
and catches syntax errors and irreversible `change` migrations early.

## Protect the database

```sh
ffmig protect --url "$PRODUCTION_DATABASE_URL"
```

`ffmig drop` then refuses the database, even with `--force`, until
someone runs `ffmig unprotect`. The mark is stored on the database
server, so a mistaken `DATABASE_URL` or a different config cannot get
around it.

For a guarantee that does not depend on FFMig, have the application
connect as a role that does not own the database. PostgreSQL then
rejects `DROP DATABASE` from it, whatever tool sends it.
