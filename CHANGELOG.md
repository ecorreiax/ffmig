# Changelog

Every release of FFMig, newest first. The release workflow publishes a
version's section as its release notes, so each release needs one,
headed `## <version>`.

## 0.1.0

The first release.

- The `.mig` language ([MIG.md](MIG.md)): tables, columns, references,
  indexes (on several columns, partial, built concurrently), foreign keys,
  renames and type, null and default changes, with the undo derived from
  `change` or written in `up` / `down`, and `execute` for raw SQL.
- Column types from `string` to `json`, time-zone-aware `datetime`, and
  literal, decimal, `:now` and `:uuid` defaults.
- PostgreSQL: SQL generation, and a driver on libpq with TLS.
- Commands: `init`, `new`, `check`, `sql`, `create`, `drop`, `protect`,
  `unprotect`, `migrate`, `rollback`, `redo`, `status`, `dump` and `load`.
- `migrate`: one transaction per migration unless `transaction: false`,
  a lock against concurrent runs, lock and statement timeouts, checksums
  of applied files, `--to`, `--dry-run`, `--fake` and `--strict`.
- `ffmig.toml`: the migrations directory, the database URL with
  `${VAR}`, a PostgreSQL schema, timeouts, and the schema dump.
