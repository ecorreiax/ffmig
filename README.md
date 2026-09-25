# FFMig

Fast Forward Migrations is a lightweight database migration tool inspired by Active Record. It is built for speed and developer experience, and it gives you full schema management without lock-in.

> **Status:** early development (v0.1.0). PostgreSQL is the only supported database for now. The `.mig` language itself is database-neutral, so other dialects can be added later.

## Installation

```sh
# macOS
brew install ffmig

# Linux
curl -o- https://ffmig.sh/release/v0.0.1/install.sh | bash
```

## Usage

Set up a project, which creates `ffmig.toml` and a `migrations/` directory, then create the database if it does not exist yet:

```sh
ffmig init
ffmig create
```

Write your first migration:

```sh
ffmig new create_users
# creates migrations/20260923140512_create_users.mig
```

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

Apply the migrations to the database:

```sh
ffmig migrate
```

See [Getting started](docs/getting-started.md) for the full walkthrough.

## Contributing

Contributions are welcome. To get started:

### Requirements

- [nix](https://nixos.org) with flakes enabled
- A PostgreSQL server to run migrations against

### Setup

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
make integration   # integrations tests against a real database
```

5. Open a pull request with a clear description of what the change does and why.

## License

[MIT](LICENSE)
