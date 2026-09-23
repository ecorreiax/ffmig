# The `.mig` language

This document is the specification of `.mig` migration files. The lexer,
parser and lowering implement what it says, and the tests cite it. If the
code and this document disagree, one of them is a bug.

A `.mig` file describes one schema change in database-neutral terms. It is
never SQL, and ffmig turns it into SQL for the configured database.

```
migration AddRoleToUsers {
  change {
    add_column :users, :role, :integer, null: false, default: 0
  }
}
```

## Lexical rules

- Source is UTF-8. Whitespace and newlines are insignificant. Commas are
  the only thing that continues an argument list, so `string :name`
  followed by `string :email` on the next line is two statements.
- Comments run from `#` to the end of the line. A `#` inside a string is
  not a comment.

| Token     | Rule                                         | Examples              |
|-----------|----------------------------------------------|-----------------------|
| `IDENT`   | `[A-Za-z_][A-Za-z0-9_]*`                     | `create_table`, `CreateUsers` |
| `LABEL`   | `IDENT` immediately followed by `:`          | `null:`, `default:`   |
| `SYMBOL`  | `:` immediately followed by `IDENT`          | `:users`, `:now`      |
| `INTEGER` | `-?[0-9]+`, must fit in a signed 64-bit int  | `0`, `-5`, `255`      |
| `STRING`  | `"..."` on one line, escapes `\" \\ \n \t`   | `"guest"`, `"a\"b"`   |
| punctuation | `{ } , [ ]`                                | —                     |

- "Immediately" means no whitespace in between: `null:false` and
  `null: false` are both a label followed by `false`, but `null :false` is
  an identifier followed by a symbol, and `: uuid` is invalid.
- `true`, `false` and `nil` are keywords. `migration`, `change`, `up` and
  `down` are contextual: they are plain identifiers that the parser checks
  by text, so they can still be used as symbols (`:up`) or labels.
- `[` and `]` are reserved for multi-column indexes. They lex, but no rule
  of the grammar accepts them yet, so any use is a syntax error.
- Any other byte outside a string or comment (`@`, `=`, `;`, `.`, ...) is
  invalid. So are an unterminated string, a line break inside a string, an
  unknown escape such as `\x`, a lone `:`, an integer out of range, and
  an integer immediately followed by an identifier (`0abc`).

## Grammar

```
file       = migration EOF ;
migration  = "migration" IDENT "{" body "}" ;
body       = section { section } ;          (* change | up, down *)
section    = ( "change" | "up" | "down" ) "{" { call } "}" ;
call       = IDENT [ args ] [ block ] ;
args       = arg { "," arg } ;
arg        = value | LABEL value ;          (* positional before labeled *)
value      = SYMBOL | STRING | INTEGER | "true" | "false" | "nil" ;
block      = "{" { call } "}" ;
```

Syntax rules beyond the EBNF:

- Positional arguments come before labeled ones.
  `add_index :users, unique: true, :email` is an error.
- No trailing comma: `add_index :users, :email,` is an error.
- A file holds exactly one migration. Anything after its closing `}`
  other than comments is an error.
- The migration name is any `IDENT`. `ffmig new` writes the PascalCase
  form of the file name (`20260923140512_create_users.mig` →
  `CreateUsers`), but the name is not checked against the file name.

The grammar is deliberately generic: `name args, key: value { block }`.
It does not know which operations exist. Everything below (operation
names, argument counts, option names, types, which calls take a block) is
checked after parsing, by lowering.

## Migration forms

A migration body is exactly one of two forms.

**`change`**: ffmig derives the undo steps. Every operation in it must be
reversible (see [Reversibility](#reversibility)).

```
migration AddRoleToUsers {
  change {
    add_column :users, :role, :integer, null: false, default: 0
  }
}
```

**`up` + `down`**: you write both directions and nothing is derived, so
irreversible operations such as `drop_table :t` without a block are fine.

```
migration BackfillSlugs {
  up {
    add_column :posts, :slug, :string
  }
  down {
    remove_column :posts, :slug
  }
}
```

- Both `up` and `down` are required, in either order.
- Any section may be empty. An empty `change {}` does nothing (this is
  what `ffmig new` generates). An empty `down {}` means "rolling back does
  nothing".
- Mixing `change` with `up` or `down`, repeating a section, or having no
  section at all is an error. These are reported by lowering, not the
  parser:

| Body                        | Result                                        |
|-----------------------------|-----------------------------------------------|
| `change { }`                | valid                                         |
| `up { } down { }`           | valid                                         |
| `down { } up { }`           | valid                                         |
| (empty)                     | syntax error: expected `change`, `up` or `down` |
| `up { }`                    | `missing 'down' block`                        |
| `change { } up { }`         | `migration has both 'change' and 'up'`        |
| `change { } change { }`     | `'change' block defined twice`                |
| `up { } down { } up { }`    | `'up' block defined twice`                    |

The statements directly inside a section are operations. Column
statements (`string :name`, `timestamps`) are only valid inside a table
block, so `string :name` inside `change` is `unknown operation 'string'`.

## Database neutrality

The language describes schema, not SQL. It contains no database-specific
types, functions or raw SQL, so the same file can run on PostgreSQL, MySQL
or SQLite. Each column type is defined by its meaning (for example
`datetime` is a date and time without time zone), and mapping it to a real
SQL type is each dialect's job. If a dialect cannot express something
(say, a default on a `text` column in MySQL), that dialect reports it when
generating SQL; the file itself stays valid.

## Operations

| Operation       | Positional args                 | Options                                | Block |
|-----------------|---------------------------------|----------------------------------------|-------|
| `create_table`  | `:table`                        | `id:`                                  | required: columns |
| `drop_table`    | `:table`                        | `id:`                                  | optional: columns |
| `add_column`    | `:table, :column, :type`        | column options                         | none  |
| `remove_column` | `:table, :column [, :type]`     | column options (only with `:type`)     | none  |
| `rename_column` | `:table, :from, :to`            | none                                   | none  |
| `add_index`     | `:table, :column`               | `unique:`, `name:`                     | none  |
| `remove_index`  | `:table [, :column]`            | `unique:`, `name:`                     | none  |
| `add_reference` | `:table, :name`                 | reference options                      | none  |
| `remove_reference` | `:table, :name`              | reference options                      | none  |

Common rules:

- Positional arguments are symbols. Table, column and type names are
  never strings: `add_column "users", ...` is an error.
- The number of positional arguments must match exactly, e.g.
  `add_column expects 3 arguments (:table, :column, :type), got 2`.
- An option not listed for an operation is an error
  (`unknown option 'uniq' for add_index`), and so is giving the same
  option twice.
- A block on an operation that takes none is an error, and so is a
  missing block on `create_table`.

### `create_table` / `drop_table`

```
create_table :users, id: :uuid {
  string :email, null: false
  timestamps
}
```

- `id:` sets the primary key column `id`: `:bigint` (the default),
  `:uuid`, or `false` for no primary key. No other value is accepted.
- The block lists the table's columns (see [Table blocks](#table-blocks)).
  It may be empty: `create_table :t {}` makes a table with only `id`.
- `drop_table :t` drops the table. Giving it the same `id:` and block the
  table was created with makes the drop reversible, because the undo step
  can recreate the table. Without a block it is irreversible.

### `add_column` / `remove_column`

```
add_column :users, :role, :integer, null: false, default: 0
remove_column :users, :role, :integer, null: false, default: 0
remove_column :users, :role
```

- `:type` is a [column type](#column-types) written as a symbol.
- Column options follow the same rules as in a table block.
- `remove_column` with a type (and options) describes the column being
  removed, which makes it reversible. Without a type it takes no options
  and is irreversible.

### `rename_column`

```
rename_column :users, :name, :full_name
```

### `add_index` / `remove_index`

```
add_index :users, :email, unique: true
add_index :users, :email, name: "users_email_key"
remove_index :users, :email, unique: true
remove_index :users, name: "users_email_key"
```

- One column per index.
- `unique:` is `true` or `false` (default `false`).
- `name:` is a string. When absent, the index is named
  `index_<table>_on_<column>` (`index_users_on_email`).
- `remove_index` needs a column, a `name:`, or both
  (`remove_index needs a column or 'name:'`). With only `name:`, it drops
  that index; with a column, it drops the index with the given or default
  name.
- `remove_index` accepts `unique:` so that it can describe the index being
  removed, like `remove_column` does with a type. See
  [Reversibility](#reversibility).

### `add_reference` / `remove_reference`

```
add_reference :posts, :user, null: false, on_delete: :cascade
remove_reference :posts, :user, null: false, on_delete: :cascade
```

- `add_reference :t, :name, opts` adds the same column, foreign key and
  index as `references :name, opts` inside a `create_table :t` block (see
  [References](#references)). It lowers to an `add_column` of that column.
- `remove_reference` drops the column, which drops its foreign key and
  index with it. It lowers to a `remove_column` that describes the column.
  Every reference option has a default, so it is always reversible: the
  undo recreates the reference exactly as written, like `remove_index`.

## Table blocks

Inside a `create_table` or `drop_table` block, each statement is a
column, a reference or `timestamps`:

```
<type> :name [, column options]
references :name [, reference options]
timestamps
```

- `<type>` is a bare identifier here (`string :email`), where
  `add_column` takes a symbol (`:string`). An unknown type is
  `unknown column type 'strng'`.
- `timestamps` takes no arguments and adds `created_at` and `updated_at`,
  both `datetime, null: false` with no default.
- Column statements take no block.
- A column name may appear only once per table, counting the two
  `timestamps` columns and the `<name>_id` column of each reference:
  `column 'email' defined twice in table 'users'`.
- Unless `id: false`, a column named `id` is a duplicate of the primary
  key and is rejected the same way.
- Operations (`add_index`, ...) are not allowed inside a table block.

## Column types

| Type       | Meaning                                         |
|------------|-------------------------------------------------|
| `string`   | short text, optionally bounded by `limit:`      |
| `text`     | unbounded text                                  |
| `integer`  | 32-bit signed integer                           |
| `bigint`   | 64-bit signed integer                           |
| `float`    | double-precision floating point                 |
| `decimal`  | exact decimal, optionally `precision:`/`scale:` |
| `boolean`  | true / false                                    |
| `date`     | calendar date                                   |
| `datetime` | date and time, without time zone                |
| `time`     | time of day, without time zone                  |
| `binary`   | byte string                                     |
| `uuid`     | 128-bit UUID                                    |
| `json`     | JSON document                                   |

## Column options

| Option       | Value                                | Allowed on      | Default |
|--------------|--------------------------------------|-----------------|---------|
| `null:`      | `true` or `false`                    | every type      | `true`  |
| `default:`   | literal or named default (below)     | every type      | none    |
| `limit:`     | integer, 1 to 4294967295             | `string` only   | none    |
| `precision:` | integer, 1 to 255                    | `decimal` only  | none    |
| `scale:`     | integer, 0 to `precision`            | `decimal` only, needs `precision:` | none |

For example `limit: 10` on an `integer` column is an error, and so is
`scale: 2` without `precision:`.

## References

A reference is a column that points at the `id` of another table's row:

```
create_table :sessions, id: :uuid {
  references :user, null: false, type: :uuid, on_delete: :cascade
  string :ip_address
}
```

`references` is not a column type. It stands for three things, each
named after the table it is in (here `sessions`):

| What          | Here                                              | Default |
|---------------|---------------------------------------------------|---------|
| a column      | `user_id`, of `type:`, with `null:`               | always  |
| a foreign key | `fk_sessions_on_user_id`, on `user_id`, to `users(id)` | on, off with `foreign_key: false` |
| an index      | `index_sessions_on_user_id`, on `user_id`         | on, off with `index: false`, unique with `index: :unique` |

The name is written without `_id`, which the column adds:
`references :user_id` is an error.

### Reference options

| Option         | Value                                   | Default |
|----------------|-----------------------------------------|---------|
| `type:`        | `:bigint` or `:uuid`                    | `:bigint` |
| `to:`          | symbol: the table the foreign key points at | the plural of the name |
| `null:`        | `true` or `false`                       | `true`  |
| `foreign_key:` | `true` or `false`                       | `true`  |
| `index:`       | `true`, `false` or `:unique`            | `true`  |
| `on_delete:`   | `:cascade`, `:nullify` or `:restrict`   | none    |

- `type:` must match the `id:` of the table pointed at. ffmig checks each
  file on its own, so it cannot see that table and does not check this;
  the database does.
- `on_delete:` says what happens to this row when the row it points at is
  deleted: `:cascade` deletes it too, `:nullify` sets the column to null,
  `:restrict` refuses the delete. Without it the database refuses the
  delete (its `NO ACTION` default). `:nullify` is an error on a
  `null: false` column.
- `to:` and `on_delete:` describe the foreign key, so they are errors with
  `foreign_key: false`.
- `index: :unique` makes the index unique, for a one-to-one relation
  (`references :user, index: :unique` in `create_table :profiles`: each
  user has at most one profile). Use it rather than `index: false` plus a
  unique `add_index`, which is the same index written twice as long.
- The foreign key points at `id`; other columns are not supported.

### Table names

Without `to:`, the table is the plural of the name, by these rules only:

| Name ends in                     | Plural             | Example                  |
|----------------------------------|--------------------|--------------------------|
| a consonant followed by `y`      | `y` becomes `ies`  | `category` → `categories` |
| `s`, `x`, `z`, `ch` or `sh`      | add `es`           | `address` → `addresses`  |
| anything else                    | add `s`            | `user` → `users`, `key` → `keys` |

Anything these rules get wrong needs `to:`: `references :person, to:
:people`, `references :author, to: :users`. A wrong table fails in the
database (`relation "persons" does not exist`), and the migration's
transaction rolls it back.

### SQL

The foreign key is written with the column, so a reference in a
`create_table` block may point at the table being created
(`references :parent, to: :comments` inside `create_table :comments`).
The index is a separate statement right after the `create_table` or
`add_column`. Dropping the table or the column drops both, so
`drop_table` and `remove_column` need nothing extra.

```sql
CREATE TABLE "sessions" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "user_id" uuid NOT NULL CONSTRAINT "fk_sessions_on_user_id" REFERENCES "users" ("id") ON DELETE CASCADE,
  "ip_address" varchar
);
CREATE INDEX "index_sessions_on_user_id" ON "sessions" ("user_id");
```

Two tables that point at each other cannot both be created with
`references`, since the second does not exist yet when the first is
created. That needs a separate foreign key operation, which the language
does not have yet.

## Column defaults

`default:` is optional on every column, including `null: false` ones. If a
row is inserted without a value for a non-null column that has no default,
the database reports the error; ffmig does not check for it.

A default is either a literal or a named default.

### Literals

A literal is stored as-is. Its kind must fit the column type:

| Column type                    | Accepted literal                       |
|--------------------------------|----------------------------------------|
| `string`, `text`               | string                                 |
| `integer`, `bigint`            | integer                                |
| `float`, `decimal`             | integer (the language has no fractional literals yet) |
| `boolean`                      | `true`, `false`                        |
| `date`, `datetime`, `time`     | string in ISO 8601 form (`"2026-01-01"`, `"2026-01-01 12:00:00"`, `"12:00:00"`) |
| `uuid`                         | string                                 |
| `json`                         | string holding JSON text (`"{}"`)      |
| `binary`                       | none                                   |
| any type                       | `nil`                                  |

- `default: nil` means "explicitly no default" and is rejected on a
  `null: false` column (`default: nil on non-null column 'role'`).
- ffmig does not parse the contents of string literals: `"not a date"` on
  a `date` column is valid here and fails in the database.

### Named defaults

A named default is a symbol the database evaluates at insert time. Each
dialect translates it to its own SQL, so the file stays portable.

| Name   | Meaning      | Allowed on                 | PostgreSQL          |
|--------|--------------|----------------------------|---------------------|
| `:now` | current time | `datetime`, `date`, `time` | `CURRENT_TIMESTAMP` |

- Any other symbol is an error: `unknown default ':today'`.
- A known name on a type it does not allow is an error:
  `default ':now' is not allowed on integer column 'role'`.

More names (e.g. `:uuid`) can be added later by extending this table.

Raw SQL defaults are not part of the language.

## Reversibility

Inside `change`, ffmig derives the `down` steps by inverting each
operation, in reverse order. An operation is reversible when it carries
everything needed to undo it:

| Operation                            | Undo                                     |
|--------------------------------------|------------------------------------------|
| `create_table :t { cols }`           | `drop_table :t { cols }`                 |
| `drop_table :t { cols }`             | `create_table :t { cols }`               |
| `drop_table :t`                      | **irreversible**                         |
| `add_column :t, :c, :type, opts`     | `remove_column :t, :c, :type, opts`      |
| `remove_column :t, :c, :type, opts`  | `add_column :t, :c, :type, opts`         |
| `remove_column :t, :c`               | **irreversible**                         |
| `rename_column :t, :a, :b`           | `rename_column :t, :b, :a`               |
| `add_index :t, :c, opts`             | `remove_index :t, :c, opts`              |
| `remove_index :t, :c, opts`          | `add_index :t, :c, opts`                 |
| `remove_index :t, name: "n"`         | **irreversible**                         |
| `add_reference :t, :name, opts`      | `remove_reference :t, :name, opts`       |
| `remove_reference :t, :name, opts`   | `add_reference :t, :name, opts`          |

`remove_index` and `unique:`: `remove_index` accepts `unique:` and is
reversible whenever it has a column. The undo recreates the index exactly
as written, so `remove_index :users, :email` comes back as a non-unique
index. If the index was unique, write
`remove_index :users, :email, unique: true`, just as `remove_column` needs
the column's type and options to bring it back. Without a column there is
nothing to recreate the index on, so a name-only `remove_index` is
irreversible.

An irreversible operation inside `change` is still a valid file. It fails
only when a rollback needs the `down` steps, and `ffmig check` warns about
it and suggests `up` / `down` blocks. Inside `up` / `down` nothing is
derived, so reversibility does not matter.

## Worked example

```
# Profiles for users, keyed by UUID.
migration CreateUsersProfile {
  change {
    create_table :users_profile, id: :uuid {
      string :name
      string :email, null: false, limit: 255
      integer :role, null: false, default: 0
      boolean :active, default: true
      decimal :balance, precision: 10, scale: 2, default: 0
      json :settings, default: "{}"
      datetime :confirmed_at, default: :now
      timestamps
    }
    add_index :users_profile, :email, unique: true
  }
}
```

What each line lowers to:

| Line | Lowers to |
|------|-----------|
| `migration CreateUsersProfile` | migration named `CreateUsersProfile` |
| `change` | body in `change` form; `down` is derived |
| `create_table :users_profile, id: :uuid` | create table `users_profile` with a `uuid` primary key `id` |
| `string :name` | column `name`, `string`, nullable, no limit, no default |
| `string :email, null: false, limit: 255` | column `email`, `string`, not null, limit 255 |
| `integer :role, null: false, default: 0` | column `role`, `integer`, not null, literal default `0` |
| `boolean :active, default: true` | column `active`, `boolean`, nullable, literal default `true` |
| `decimal :balance, precision: 10, scale: 2, default: 0` | column `balance`, `decimal(10, 2)`, nullable, literal default `0` |
| `json :settings, default: "{}"` | column `settings`, `json`, nullable, literal default `"{}"` |
| `datetime :confirmed_at, default: :now` | column `confirmed_at`, `datetime`, nullable, named default `now` |
| `timestamps` | columns `created_at` and `updated_at`, `datetime`, not null, no default |
| `add_index :users_profile, :email, unique: true` | unique index `index_users_profile_on_email` on `users_profile(email)` |

The derived `down` is the inverse of each operation in reverse order:

```
remove_index :users_profile, :email, unique: true
drop_table :users_profile, id: :uuid { ...same columns... }
```

## Invalid examples

Each of these is rejected; the message is what `ffmig check` reports.

| Snippet (inside `change { }` unless noted)          | Error |
|-----------------------------------------------------|-------|
| `add_idx :users, :email`                            | `unknown operation 'add_idx'` |
| `create_table :t { strng :name }`                   | `unknown column type 'strng'` |
| `add_index :users, :email, uniq: true`              | `unknown option 'uniq' for add_index` |
| `add_column :users, :role`                          | `add_column expects 3 arguments (:table, :column, :type), got 2` |
| `create_table :t { string :a  string :a }`          | `column 'a' defined twice in table 't'` |
| `create_table :t`                                   | missing block on `create_table` |
| `add_column :t, :c, :string { }`                    | `add_column` takes no block |
| `add_index :users, unique: true, :email`            | `positional argument after option 'unique:'` |
| `add_column :t, :c, :integer, limit: 10`            | `limit:` is only allowed on `string` |
| `add_column :t, :c, :integer, default: "0"`         | string default on an `integer` column |
| `add_column :t, :c, :date, default: :today`         | `unknown default ':today'` |
| `add_column :t, :role, :integer, default: :now`     | `default ':now' is not allowed on integer column 'role'` |
| `add_column :t, :c, :integer, null: false, default: nil` | `default: nil on non-null column 'c'` |
| `remove_index :users`                               | `remove_index needs a column or 'name:'` |
| `create_table :t { references :user_id }`           | `reference ':user_id' already ends in '_id'; write ':user'` |
| `add_reference :t, :user, type: :integer`           | `'type:' must be :bigint or :uuid` |
| `add_reference :t, :user, index: :primary`          | `'index:' must be true, false or :unique` |
| `add_reference :t, :user, null: false, on_delete: :nullify` | `on_delete: :nullify on non-null column 'user_id'` |
| `add_reference :t, :user, foreign_key: false, to: :people` | `'to:' needs a foreign key` |
| `create_table :t, id: :integer { }`                 | `id:` must be `:bigint`, `:uuid` or `false` |
| `add_index :t, [:a, :b]`                            | syntax error: `[` is reserved |
| `migration M { }`                                   | syntax error: expected `change`, `up` or `down` |
