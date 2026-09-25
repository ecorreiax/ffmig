# Configuration

FFMig reads `ffmig.toml` from the current directory, or the file that
`--config` names. `ffmig init` writes one:

```toml
[migration]
path = "migrations"

[database]
url = "${DATABASE_URL}"
```

Only the part of TOML that this file needs is understood: `[section]`
headers, `key = "string"` pairs (or `'string'`) and `#` comments. Unknown
sections and keys are ignored.

## `[migration]`

| Key                 | Default        | Meaning |
|---------------------|----------------|---------|
| `path`              | `"migrations"` | The migrations directory, relative to the config file |
| `lock_timeout`      | unset          | Fail a statement that waits longer than this for a lock |
| `statement_timeout` | unset          | Fail a statement that runs longer than this |

The timeouts take a duration: a whole number followed by `ms`, `s`,
`min` or `h`, such as `"500ms"`, `"5s"` or `"2min"`, or `"0"` for no
limit. The most PostgreSQL accepts is about 24 days. When a timeout is
unset, the database server's own setting applies. They apply to
`migrate`, `rollback` and `redo`; see [Running in
production](production.md#lock-timeouts) for why `lock_timeout` matters.

## `[database]`

| Key   | Meaning |
|-------|---------|
| `url` | The database to migrate, such as `postgres://user@host:5432/app` |

Each `${NAME}` in `url` is replaced by the environment variable `NAME`. A
variable that is not set is an error, not an empty string. A `$` that is
not followed by `{` is kept as it is.

The URL's scheme picks the database. `postgres://` and `postgresql://`
are PostgreSQL, the only database FFMig supports so far. Everything else
in the URL goes to libpq as it is, so query parameters such as
`?sslmode=require` work as they do in `psql`.

## Choosing the database

The config's `url` is the last choice. FFMig uses the first of these that
is set:

1. the `--url` flag
2. the `FFMIG_DATABASE_URL` environment variable, when it is not empty
3. `url` in `[database]`, after `${VAR}` expansion

The first two are used as given, without `${VAR}` expansion. They are
useful for pointing one command at another database without editing the
config:

```sh
ffmig status --url postgres://localhost/app_test
FFMIG_DATABASE_URL=postgres://localhost/app_test ffmig migrate
```

For `init`, `--url` is the URL it writes into the new config.

## Another config file

`--config <path>` makes a command read another file. The file's `path`
is then relative to that file, not to the current directory, so a config
kept in a subdirectory still finds its migrations:

```sh
ffmig migrate --config db/ffmig.toml   # migrations in db/migrations
```

For `init`, `--config` is the file it creates.

## Environment variables

| Variable             | Meaning |
|----------------------|---------|
| `FFMIG_DATABASE_URL` | The database URL, ahead of the config's |
| any `${NAME}` in `url` | Filled into the config's URL |

libpq's own variables, such as `PGPASSWORD` and `PGSSLMODE`, also apply
to any setting the URL leaves out.
