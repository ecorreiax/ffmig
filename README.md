# FFMig

Fast Forward Migrations is a lightweight database migration tool inspired by Active Record. It is built for speed and developer experience, and it gives you full schema management without lock-in.

> **Status:** early development (v0.1.0). PostgreSQL is the only supported database for now. The `.mig` language itself is database-neutral, so other dialects can be added later.

## Installation

```sh
# macOS
brew install ffmig

# Linux
curl -o- https://raw.githubusercontent.com/ecorreiax/ffmig/v0.0.1/install.sh | bash
```

## Usage

### 1. Set up a project

```sh
ffmig init
```

This creates a `migrations/` directory and an `ffmig.toml`:

```toml
[migration]
path = "migrations"

[database]
url = "${DATABASE_URL}"
```

### 2. Write a migration

```sh
ffmig new create_users
# creates migrations/20260923140512_create_users.mig
```

Edit the generated file:

```sh
migration CreateUsers {
  change {
    create_table :users, id: :uuid {
      string :email, null: false
      string :phone, null: false

      string :name, null: false

      timestamps
    }

    add_index :users, :email, unique: true
    add_index :users, :phone, unique: true
  }
}
```

### 3. Apply the migration

```sh
ffmig migrate
```

Applied versions are recorded in a `schema_migrations` table. `migrate` checks every pending file before it runs anything, so a broken file never leaves a batch half-applied. Each migration runs in its own transaction.

### Commands

| Command          | Description                                            |
|------------------|--------------------------------------------------------|
| `init`           | Create `ffmig.toml` and the migrations directory       |
| `new <name>`     | Create a timestamped migration file                    |
| `check [files]`  | Check `.mig` files (`--ast`, `--down`)                 |
| `sql <file>`     | Print the SQL for a migration (`--down` for rollback)  |
| `migrate`        | Apply every pending migration                          |
| `rollback`       | Undo the last migration (`--step <n>` for more)        |
| `status`         | List migrations as up or down                          |
| `help`           | Show usage                                             |

## Contributing

Contributions are welcome. To get started:

### Requirements

- [nix](https://nixos.org) with flakes enabled
- A PostgreSQL server to run migrations against

## Setup

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
make integration   # migrate / rollback / status against a real database
```

`make integration` starts a throwaway PostgreSQL server in a temporary directory. It listens only on a Unix socket and is removed afterwards, so it needs no setup.

5. Open a pull request with a clear description of what the change does and why.

## License

[MIT](LICENSE)
