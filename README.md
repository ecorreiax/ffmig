# FFMig

Fast Forward Migrations is a lightweight database migration tool inspired by Active Record. Designed for speed and developer experience, it gives you full schema management without lock-in.

## Documentation

- [The `.mig` language](docs/mig.md): grammar, operations and column types for migration files.

## Development

The [nix](https://nixos.org) dev shell (`nix develop`) provides Zig, libpq and PostgreSQL; the `make` targets use it automatically when those are not on your `PATH`.

- `make test` runs the unit tests. They need no database.
- `make integration` runs `migrate`, `rollback` and `status` against a real PostgreSQL. It starts a throwaway server in a temporary directory, on a Unix socket only, and removes it afterwards.
