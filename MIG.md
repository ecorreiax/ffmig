# The `.mig` language

This document is the specification of `.mig` migration files. The lexer,
parser and lowering implement what it says, and the tests cite it. If the
code and this document disagree, one of them is a bug.

A `.mig` file describes one schema change in database-neutral terms. It is
never SQL, and FFMig turns it into SQL for the configured database.

```mig
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
| `DECIMAL` | `-?[0-9]+\.[0-9]+`, kept as written          | `0.5`, `-12.250`      |
| `STRING`  | `"..."` on one line, escapes `\" \\ \n \t`, or a [multi-line string](#multi-line-strings) | `"guest"`, `"a\"b"`   |
| punctuation | `{ } , [ ]`                                | —                     |

- "Immediately" means no whitespace in between: `null:false` and
  `null: false` are both a label followed by `false`, but `null :false` is
  an identifier followed by a symbol, and `: uuid` is invalid.
- `true`, `false` and `nil` are keywords. `migration`, `change`, `up` and
  `down` are contextual: they are plain identifiers that the parser checks
  by text, so they can still be used as symbols (`:up`) or labels.
- `[` and `]` enclose a list: `[:user_id, :created_at]`. Only the column
  of [`add_index` and `remove_index`](#add_index--remove_index) takes one.
- A `DECIMAL` has digits on both sides of the `.`: `1.` and `.5` are
  invalid. It is never converted to a binary float, so `0.10` stays
  `0.10` in the SQL.
- Any other byte outside a string or comment (`@`, `=`, `;`, ...) is
  invalid. So are an unterminated string, a line break inside a one-line
  string, an unknown escape such as `\x`, a lone `:`, an integer out of
  range, and a number immediately followed by an identifier or a `.`
  (`0abc`, `1.5.2`).

### Multi-line strings

A string that starts with `"""` runs across lines until the next `"""`
that is not escaped.
It is a `STRING` like any other, so it can be used wherever a string can:

```mig
execute """
  UPDATE users
  SET name = 'Ada "the first" Lovelace'
  WHERE id = 1
  """
```

- The opening `"""` must be followed by a line break, which is not part
  of the value (`expected a line break after '"""'`).
- The closing `"""` must be alone on its line, after nothing but spaces
  and tabs (`closing '"""' must be on its own line`). The rest of the
  call may follow it: `""", dialect: :postgres`. The line break before
  it is not part of the value.
- The spaces and tabs before the closing `"""` are its indentation, and
  are removed from the start of every line. Every line must start with
  exactly that indentation (`line is indented less than the closing
  '"""'`), except a line of only spaces and tabs, which becomes empty.
  Indentation beyond it is kept. The value above is three lines, with
  no indentation and no line break at the end.
- `"` needs no escape. `\"`, `\\`, `\n` and `\t` work as in one-line
  strings, and `"""` inside the value is written `\"""`. A `\` at the
  end of a line is an error (`unknown escape '\' at the end of a line`).
- A `\r\n` line break is read as `\n`, so a file checked out with
  Windows line endings gives the same value.

## Grammar

```
file       = migration EOF ;
migration  = "migration" IDENT [ "," args ] "{" body "}" ;
body       = section { section } ;          (* change | up, down *)
section    = ( "change" | "up" | "down" ) "{" { call } "}" ;
call       = IDENT [ args ] [ block ] ;
args       = arg { "," arg } ;
arg        = value | LABEL value ;          (* positional before labeled *)
value      = SYMBOL | STRING | INTEGER | DECIMAL | "true" | "false" | "nil" | list ;
list       = "[" value { "," value } "]" ;
block      = "{" { call } "}" ;
```

Syntax rules beyond the EBNF:

- Positional arguments come before labeled ones.
  `add_index :users, unique: true, :email` is an error.
- No trailing comma: `add_index :users, :email,` is an error, and so are
  `[:a, ]` and an empty list `[]`.
- A list may span lines: inside `[` `]` a line break is whitespace.
- A file holds exactly one migration. Anything after its closing `}`
  other than comments is an error.
- Arguments after the migration name follow a comma, like a call's:
  `migration M, transaction: false {`. Lowering accepts only the options
  in [Transactions](#transactions).
- The migration name is any `IDENT`. `ffmig new` writes the PascalCase
  form of the file name (`20260923140512_create_users.mig` →
  `CreateUsers`), but the name is not checked against the file name.

The grammar is deliberately generic: `name args, key: value { block }`.
It does not know which operations exist. Everything below (operation
names, argument counts, option names, types, which calls take a block) is
checked after parsing, by lowering.

## Migration forms

A migration body is exactly one of two forms.

**`change`**: FFMig derives the undo steps. Every operation in it must be
reversible (see [Reversibility](#reversibility)).

```mig
migration AddRoleToUsers {
  change {
    add_column :users, :role, :integer, null: false, default: 0
  }
}
```

**`up` + `down`**: you write both directions and nothing is derived, so
irreversible operations such as `drop_table :t` without a block are fine.

```mig
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

## Transactions

A migration runs in one transaction together with the row that records
it in `schema_migrations`, so it applies completely or not at all: if a
statement fails, its earlier statements are undone and the migration is
still pending. Rolling it back works the same way.

Some statements cannot run inside a transaction, such as PostgreSQL's
`CREATE INDEX CONCURRENTLY` and `VACUUM`. A migration that needs them
opts out with `transaction: false` after its name:

```mig
migration AddSlugIndex, transaction: false {
  change {
    add_index :posts, :slug, unique: true, algorithm: :concurrently
  }
}
```

- `transaction:` is `true` (the default) or `false`. It is the only
  option a migration takes: any other is an error
  (`unknown option 'lock' for migration`), and so is a positional
  argument (`migration takes only options, such as 'transaction: false'`).
- It applies in both directions: the `down` steps run without a
  transaction too.
- Without a transaction, each statement takes effect as soon as it runs,
  and the `schema_migrations` row is written after the last one. If a
  statement fails, the statements before it stay applied and the
  migration is not recorded: it still shows as `down`, and the next
  `migrate` runs it again from its first statement. Fix the database by
  hand before that, or write the migration so that it can run twice.
  Keeping such a migration to the statements that need it limits what
  can be left half done.
- On a database whose schema changes are not transactional, every
  migration runs this way. PostgreSQL's are.

Statements the language does not model run through [`execute`](#raw-sql):

```mig
migration VacuumPosts, transaction: false {
  up {
    execute "VACUUM ANALYZE posts"
  }
  down {
  }
}
```

Without `transaction: false`, PostgreSQL refuses it:
`VACUUM cannot run inside a transaction block`.

## Database neutrality

The language describes schema, not SQL. It contains no database-specific
types or functions, so the same file can run on PostgreSQL, MySQL or
SQLite. The one exception is [`execute`](#raw-sql), which runs SQL as
written; a file that uses it opts out of portability. Each column type is defined by its meaning (for example
`datetime` is a date and time without time zone), and mapping it to a real
SQL type is each dialect's job. If a dialect cannot express something
(say, a default on a `text` column in MySQL), that dialect reports it when
generating SQL; the file itself stays valid.

## Operations

| Operation       | Positional args                 | Options                                | Block |
|-----------------|---------------------------------|----------------------------------------|-------|
| `create_table`  | `:table`                        | `id:`                                  | required: columns |
| `drop_table`    | `:table`                        | `id:`                                  | optional: columns |
| `rename_table`  | `:from, :to`                    | none                                   | none  |
| `add_column`    | `:table, :column, :type`        | column options                         | none  |
| `remove_column` | `:table, :column [, :type]`     | column options (only with `:type`)     | none  |
| `rename_column` | `:table, :from, :to`            | none                                   | none  |
| `change_column` | `:table, :column, :type`        | `limit:`, `precision:`, `scale:`, `from:`, `from_limit:`, `from_precision:`, `from_scale:` | none |
| `change_column_null` | `:table, :column, true/false` | `default:`                          | none  |
| `change_column_default` | `:table, :column`        | `to:` (required), `from:`              | none  |
| `add_index`     | `:table, :column` or `:table, [:columns]` | `unique:`, `name:`, `where:`, `algorithm:` | none |
| `remove_index`  | `:table [, :column or [:columns]]` | `unique:`, `name:`, `where:`, `algorithm:` | none |
| `rename_index`  | `:table, "from", "to"`          | none                                   | none  |
| `add_reference` | `:table, :name`                 | reference options                      | none  |
| `remove_reference` | `:table, :name`              | reference options                      | none  |
| `add_foreign_key` | `:table, :to_table`           | `column:` (required), `on_delete:`, `name:` | none |
| `remove_foreign_key` | `:table [, :to_table]`     | `column:`, `on_delete:`, `name:`       | none  |
| `execute`       | `"sql"`                         | `dialect:`                             | none  |

Common rules:

- Positional arguments are symbols, except `execute`'s SQL,
  `rename_index`'s index names (strings, like `name:`),
  `change_column_null`'s `true` or `false`, and an index's list of
  columns. Table, column and type names are never strings:
  `add_column "users", ...` is an error.
- A name is at most 63 bytes: a table, a column, a `name:`, and the
  default name of an index or a foreign key
  (`name '...' is longer than 63 bytes`). That is PostgreSQL's limit, the
  smallest among the databases the language targets, and PostgreSQL would
  cut a longer name short, so that an operation computing the same
  default name later would not find it.
- The number of positional arguments must match exactly, e.g.
  `add_column expects 3 arguments (:table, :column, :type), got 2`.
- An option not listed for an operation is an error
  (`unknown option 'uniq' for add_index`), and so is giving the same
  option twice.
- A block on an operation that takes none is an error, and so is a
  missing block on `create_table`.

### `create_table` / `drop_table`

```mig
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

### `rename_table`

```mig
rename_table :posts, :articles
```

- Renames the table, and with it the names that were made from its name,
  so that it looks as if it had been created as `:to`:

  | Before                      | After                          |
  |-----------------------------|--------------------------------|
  | `index_posts_on_<column>`   | `index_articles_on_<column>`   |
  | `fk_posts_on_<column>`      | `fk_articles_on_<column>`      |
  | `posts_pkey` (PostgreSQL's primary key) | `articles_pkey`    |
  | `posts_id_seq` (PostgreSQL's `id` sequence) | `articles_id_seq` |

  Operations that compute a default name, such as
  `remove_index :articles, :title` and `remove_reference :articles, :user`,
  then find it. Indexes and foreign keys with a custom `name:` keep it.
- FFMig checks each file on its own and cannot know which of these exist,
  so the database looks them up when the migration runs. In PostgreSQL,
  the `ALTER TABLE ... RENAME TO` is followed by a `DO` block that reads
  the catalog and renames each one; both are sent as one statement, so
  they apply together even with `transaction: false`.
- A new name longer than the database allows (63 bytes in PostgreSQL) is
  an error that names it
  (`cannot rename index_posts_on_user_id to index_..._on_user_id: longer than 63 bytes`),
  and the rename is undone.
- Foreign keys on other tables that point at the renamed one are named
  after their own table, so they keep their names.

### `add_column` / `remove_column`

```mig
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

```mig
rename_column :users, :name, :full_name
```

### `change_column`

```mig
change_column :users, :age, :bigint, from: :integer
change_column :users, :name, :string, limit: 255, from: :string, from_limit: 100
change_column :users, :bio, :text
```

- Changes the column's type to `:type`, a [column type](#column-types)
  written as a symbol. `limit:`, `precision:`, `scale:` and `time_zone:`
  follow the rules in [Column options](#column-options), so
  `change_column :events, :at, :datetime, time_zone: true, from: :datetime`
  makes a column time-zone aware. It changes only the type:
  the column keeps its nullability and default, which
  [`change_column_null`](#change_column_null) and
  [`change_column_default`](#change_column_default) change
  (`unknown option 'null' for change_column`).
- `from:` is the type before the change, as a symbol, and `from_limit:`,
  `from_precision:`, `from_scale:` and `from_time_zone:` are its options, by the same
  rules (`'from_limit:' is only allowed on string columns`). They describe
  the old type so that the undo can restore it, like `remove_column`'s
  type, which makes `change_column` reversible. Without `from:` it is
  irreversible, and the `from_` options are an error
  (`'from_limit:' needs 'from:'`).
- The database converts the values already in the column, and the
  column's default. PostgreSQL does it when the old type converts to the
  new one implicitly or by assignment (`integer` to `bigint`, `string` to
  `text`, a longer or shorter `limit:`, which fails on a value that no
  longer fits); otherwise it refuses
  (`column "age" cannot be cast automatically to type integer`). There is
  no `using:` option, since that would be SQL inside `change`: write such
  a change in `up` / `down` with [`execute`](#raw-sql), e.g.
  `execute "ALTER TABLE users ALTER COLUMN age TYPE integer USING age::integer"`.

### `change_column_null`

```mig
change_column_null :users, :role, false, default: 0
change_column_null :users, :nickname, true
```

- The third argument is `true` to allow nulls or `false` to forbid them,
  written as is (`change_column_null expects true or false, found a symbol`).
- `default:` first sets the column to that value in every row where it is
  null, so that forbidding nulls does not fail on rows already there. It
  takes a literal or a named default, as in
  [Column defaults](#column-defaults), except `nil`
  (`change_column_null cannot fill nulls with nil`), and only with
  `false` (`change_column_null takes 'default:' only with false`). It does
  not become the column's default; `change_column_default` sets that.
  FFMig does not know the column's type here, so the database checks that
  the value fits.
- The undo flips `true` and `false`. It does not put the nulls back.

### `change_column_default`

```mig
change_column_default :users, :role, from: 0, to: 1
change_column_default :posts, :published_at, from: nil, to: :now
change_column_default :users, :role, to: nil
```

- `to:` is the new default and is required
  (`change_column_default needs 'to:'`). `from:` is the default before
  the change. Each is a literal or a named default, as in
  [Column defaults](#column-defaults), or `nil` for no default.
- With `from:`, the undo sets the `from:` default back. Without it, the
  change is irreversible.
- FFMig does not know the column's type here, so it does not check that
  the value fits (`to: "x"` on an `integer` column); the database does.
  A named default must still be a known name (`unknown default ':today'`).

### `add_index` / `remove_index`

```mig
add_index :users, :email, unique: true
add_index :users, :email, name: "users_email_key"
add_index :events, [:user_id, :created_at]
add_index :users, :email, unique: true, where: "deleted_at IS NULL"
remove_index :users, :email, unique: true
remove_index :users, name: "users_email_key"
```

- The column is a symbol, or a list of symbols for an index on several
  columns, in index order: `[:user_id, :created_at]`. A column may appear
  once (`column 'a' listed twice in the index`), and `[:email]` is the
  same as `:email`.
- `unique:` is `true` or `false` (default `false`).
- `name:` is a string. When absent, the index is named
  `index_<table>_on_<column>` (`index_users_on_email`), with the columns
  of a list joined by `_and_` (`index_events_on_user_id_and_created_at`).
  A default name longer than 63 bytes is an error that asks for a
  shorter `name:`.
- `where:` makes a partial index, over only the rows where the condition
  holds. It is a string of SQL, sent as written (`WHERE deleted_at IS
  NULL`), so a file that uses it depends on that SQL being valid for its
  database, as with [`execute`](#raw-sql). Unlike `execute`, it is
  allowed in `change`: FFMig still models the index, so it can undo it.
  A string of only whitespace is an error (`'where:' has no condition`).
- `algorithm: :concurrently` builds or drops the index without blocking
  writes to the table, which matters on a large table. PostgreSQL does it
  with `CREATE INDEX CONCURRENTLY` / `DROP INDEX CONCURRENTLY`, which
  cannot run in a transaction, so the migration must have
  [`transaction: false`](#transactions)
  (`a concurrent index needs 'transaction: false' on the migration`). If
  a concurrent build fails, PostgreSQL leaves an invalid index behind:
  drop it by hand before running the migration again.
- `remove_index` needs a column, a `name:`, or both
  (`remove_index needs a column or 'name:'`). With only `name:`, it drops
  that index; with a column, it drops the index with the given or default
  name.
- `remove_index` accepts `unique:` and `where:` so that it can describe
  the index being removed, like `remove_column` does with a type. See
  [Reversibility](#reversibility).

### `rename_index`

```mig
rename_index :users, "index_users_on_email", "users_email_key"
```

- The index names are strings, like `name:` on `add_index`
  (`rename_index expects "from" to be a string, found a symbol`).
- PostgreSQL does not need the table, but other databases name indexes
  per table, so it is always given.

### `add_reference` / `remove_reference`

```mig
add_reference :posts, :user, null: false, on_delete: :cascade
remove_reference :posts, :user, null: false, on_delete: :cascade
```

- `add_reference :t, :name, opts` adds the same column, foreign key and
  index as `references :name, opts` inside a `create_table :t` block (see
  [References](#references)). It lowers to an `add_column` of that column.
- The index and foreign key are named after the table and column, and a
  name longer than 63 bytes is an error. Write the reference with
  `index: false` or `foreign_key: false` and add that part with
  `add_index` or `add_foreign_key` and a shorter `name:`.
- `remove_reference` drops the column, which drops its foreign key and
  index with it. It lowers to a `remove_column` that describes the column.
  Every reference option has a default, so it is always reversible: the
  undo recreates the reference exactly as written, like `remove_index`.

### `add_foreign_key` / `remove_foreign_key`

```mig
add_foreign_key :posts, :users, column: :author_id, on_delete: :cascade
remove_foreign_key :posts, :users, column: :author_id, on_delete: :cascade
remove_foreign_key :posts, name: "posts_author_fkey"
```

- `add_foreign_key :table, :to_table` makes `column:` of `:table` point
  at `:to_table`'s `id`: the foreign key of a
  [reference](#references), for a column that already exists. It adds no
  column and no index.
- `column:` is a symbol and is required
  (`add_foreign_key needs 'column:'`): FFMig does not guess it from the
  table name.
- `on_delete:` is as in [Reference options](#reference-options). FFMig
  does not see the column here, so it cannot reject `:nullify` on a
  `null: false` column; the database then refuses the delete.
- `name:` is a string. When absent, the foreign key is named
  `fk_<table>_on_<column>` (`fk_posts_on_author_id`), like a reference's.
- `remove_foreign_key` needs `column:`, `name:`, or both
  (`remove_foreign_key needs 'column:' or 'name:'`), like `remove_index`.
  It accepts `:to_table` and `on_delete:` so that it can describe the
  foreign key being removed: with `:to_table` and `column:` it is
  reversible, and the undo recreates the foreign key as written.

## Raw SQL

`execute` runs SQL that the language does not model: extensions, views,
functions, triggers, check constraints, data backfills.

```mig
migration CreateActiveUsers {
  up {
    execute "CREATE EXTENSION IF NOT EXISTS pgcrypto"
    execute """
      CREATE VIEW active_users AS
      SELECT * FROM users WHERE deleted_at IS NULL
      """
    execute "UPDATE users SET email = lower(email)", dialect: :postgres
  }
  down {
    execute "DROP VIEW active_users"
  }
}
```

- `execute` takes one string, the SQL
  (`execute expects "sql" to be a string, found a symbol`), usually a
  [multi-line string](#multi-line-strings). FFMig does not read it: it
  is sent to the database as written, as one statement of the migration.
  A string of only whitespace and `;` is an error (`execute has no SQL`).
- It is allowed only in `up` and `down`, never in `change`
  (`execute is not allowed in 'change'; write 'up' and 'down'`): FFMig
  cannot derive the undo of SQL it does not understand, so the file
  writes both directions.
- The string may hold several statements separated by `;`. PostgreSQL
  runs them as one implicit transaction, so a statement that cannot run
  in a transaction (`CREATE INDEX CONCURRENTLY`) must be alone in its
  `execute`, in a `transaction: false` migration (see
  [Transactions](#transactions)).
- A trailing `;` is optional. `ffmig sql` prints each `execute` followed
  by one `;`, whether the string ends in one or not, and puts that `;` on
  a line of its own when the last line holds a `--` comment.
- `dialect:` names the one database the SQL is written for. Its value is
  a symbol: `:postgres`, the only dialect so far; any other is an error
  (`unknown dialect ':mysql'`). With it, running the migration on another
  database fails before anything runs (`execute is for postgres only`),
  in both directions. Without it, the SQL runs as written on any
  database.

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
- `timestamps` adds `created_at` and `updated_at`, both
  `datetime, null: false` with no default. Its only option is
  `time_zone:`, which it gives both columns (`timestamps time_zone: true`).
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
| `datetime` | date and time, without time zone unless `time_zone: true` |
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
| `time_zone:` | `true` or `false`                    | `datetime` only | `false` |

For example `limit: 10` on an `integer` column is an error, and so is
`scale: 2` without `precision:`.

`time_zone: true` makes a `datetime` a point in time rather than a
wall-clock reading: the database converts it to and from the session's
time zone (PostgreSQL's `timestamptz`). Many teams use it for every
timestamp.

## References

A reference is a column that points at the `id` of another table's row:

```mig
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

- `type:` must match the `id:` of the table pointed at. FFMig checks each
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
created. Create the first one's reference without a foreign key, and add
it with [`add_foreign_key`](#add_foreign_key--remove_foreign_key) once the
second exists:

```mig
create_table :users {
  references :team, foreign_key: false
}
create_table :teams {
  references :owner, to: :users
}
add_foreign_key :users, :teams, column: :team_id
```

## Column defaults

`default:` is optional on every column, including `null: false` ones. If a
row is inserted without a value for a non-null column that has no default,
the database reports the error; FFMig does not check for it.

A default is either a literal or a named default.

### Literals

A literal is stored as-is. Its kind must fit the column type:

| Column type                    | Accepted literal                       |
|--------------------------------|----------------------------------------|
| `string`, `text`               | string                                 |
| `integer`, `bigint`            | integer                                |
| `float`, `decimal`             | integer or decimal (`0.5`)             |
| `boolean`                      | `true`, `false`                        |
| `date`, `datetime`, `time`     | string in ISO 8601 form (`"2026-01-01"`, `"2026-01-01 12:00:00"`, `"12:00:00"`) |
| `uuid`                         | string                                 |
| `json`                         | string holding JSON text (`"{}"`)      |
| `binary`                       | none                                   |
| any type                       | `nil`                                  |

- `default: nil` means "explicitly no default" and is rejected on a
  `null: false` column (`default: nil on non-null column 'role'`).
- FFMig does not parse the contents of string literals: `"not a date"` on
  a `date` column is valid here and fails in the database.

### Named defaults

A named default is a symbol the database evaluates at insert time. Each
dialect translates it to its own SQL, so the file stays portable.

| Name    | Meaning         | Allowed on                 | PostgreSQL          |
|---------|-----------------|----------------------------|---------------------|
| `:now`  | current time    | `datetime`, `date`, `time` | `CURRENT_TIMESTAMP` |
| `:uuid` | a random UUID   | `uuid`                     | `gen_random_uuid()` (PostgreSQL 13 or later) |

- Any other symbol is an error: `unknown default ':today'`.
- A known name on a type it does not allow is an error:
  `default ':now' is not allowed on integer column 'role'`.

[`change_column_default`](#change_column_default) changes an existing
column's default to a literal or a named one. Defaults written in SQL are
not part of the language. An `up` / `down` migration can set one with
[`execute`](#raw-sql) (`ALTER TABLE ... ALTER COLUMN ... SET DEFAULT ...`).

## Reversibility

Inside `change`, FFMig derives the `down` steps by inverting each
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
| `rename_table :a, :b`                | `rename_table :b, :a`                    |
| `rename_column :t, :a, :b`           | `rename_column :t, :b, :a`               |
| `change_column :t, :c, :new, opts, from: :old, from_opts` | `change_column :t, :c, :old, opts, from: :new, from_opts` (the sizes swapped too) |
| `change_column :t, :c, :type, opts`  | **irreversible**                         |
| `change_column_null :t, :c, false, default: v` | `change_column_null :t, :c, true` |
| `change_column_null :t, :c, true`    | `change_column_null :t, :c, false`       |
| `change_column_default :t, :c, from: a, to: b` | `change_column_default :t, :c, from: b, to: a` |
| `change_column_default :t, :c, to: b` | **irreversible**                        |
| `add_index :t, :c, opts`             | `remove_index :t, :c, opts` (the same columns, `where:` and `algorithm:`) |
| `remove_index :t, :c, opts`          | `add_index :t, :c, opts`                 |
| `remove_index :t, name: "n"`         | **irreversible**                         |
| `rename_index :t, "a", "b"`          | `rename_index :t, "b", "a"`              |
| `add_reference :t, :name, opts`      | `remove_reference :t, :name, opts`       |
| `remove_reference :t, :name, opts`   | `add_reference :t, :name, opts`          |
| `add_foreign_key :t, :u, opts`       | `remove_foreign_key :t, :u, opts`        |
| `remove_foreign_key :t, :u, column: :c, opts` | `add_foreign_key :t, :u, column: :c, opts` |
| `remove_foreign_key :t, name: "n"`   | **irreversible**                         |
| `execute "sql"`                      | not allowed in `change`                  |

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

```mig
# Profiles for users, keyed by UUID.
migration CreateUsersProfile {
  change {
    create_table :users_profile, id: :uuid {
      string :name
      string :email, null: false, limit: 255
      integer :role, null: false, default: 0
      boolean :active, default: true
      decimal :balance, precision: 10, scale: 2, default: 0.50
      uuid :api_key, null: false, default: :uuid
      json :settings, default: "{}"
      datetime :confirmed_at, time_zone: true, default: :now
      timestamps time_zone: true
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
| `decimal :balance, precision: 10, scale: 2, default: 0.50` | column `balance`, `decimal(10, 2)`, nullable, literal default `0.50` |
| `uuid :api_key, null: false, default: :uuid` | column `api_key`, `uuid`, not null, named default `uuid` (a new random UUID per row) |
| `json :settings, default: "{}"` | column `settings`, `json`, nullable, literal default `"{}"` |
| `datetime :confirmed_at, time_zone: true, default: :now` | column `confirmed_at`, `datetime` with time zone, nullable, named default `now` |
| `timestamps time_zone: true` | columns `created_at` and `updated_at`, `datetime` with time zone, not null, no default |
| `add_index :users_profile, :email, unique: true` | unique index `index_users_profile_on_email` on `users_profile(email)` |

The derived `down` is the inverse of each operation in reverse order:

```mig
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
| `rename_table :posts`                               | `rename_table expects 2 arguments (:from, :to), got 1` |
| `change_column :users, :age, :bigint, null: false`  | `unknown option 'null' for change_column` |
| `change_column :users, :name, :text, from_limit: 100` | `'from_limit:' needs 'from:'` |
| `change_column :users, :name, :text, from: "string"` | `'from:' must be a column type such as :string` |
| `change_column :users, :age, :bigint, from: :integer, from_limit: 10` | `'from_limit:' is only allowed on string columns` |
| `change_column_null :users, :role, :no`             | `change_column_null expects true or false, found a symbol` |
| `change_column_null :users, :role, true, default: 0` | `change_column_null takes 'default:' only with false` |
| `change_column_null :users, :role, false, default: nil` | `change_column_null cannot fill nulls with nil` |
| `change_column_default :users, :role, from: 0`      | `change_column_default needs 'to:'` |
| `change_column_default :users, :role, to: :today`   | `unknown default ':today'` |
| `rename_index :users, :a, :b`                       | `rename_index expects "from" to be a string, found a symbol` |
| `add_foreign_key :posts, :users`                    | `add_foreign_key needs 'column:'` |
| `add_foreign_key :posts, :users, column: "author_id"` | `'column:' must be a symbol` |
| `add_foreign_key :posts, :users, column: :author_id, on_delete: :delete` | `'on_delete:' must be :cascade, :nullify or :restrict` |
| `remove_foreign_key :posts, :users`                 | `remove_foreign_key needs 'column:' or 'name:'` |
| `execute "CREATE EXTENSION pgcrypto"`               | `execute is not allowed in 'change'; write 'up' and 'down'` |
| `execute` (inside `up`)                             | `execute expects 1 argument ("sql"), got 0` |
| `execute :users` (inside `up`)                      | `execute expects "sql" to be a string, found a symbol` |
| `execute " ; "` (inside `up`)                       | `execute has no SQL` |
| `execute "SELECT 1", dialect: :mysql` (inside `up`) | `unknown dialect ':mysql'` |
| `execute "SELECT 1", dialect: "postgres"` (inside `up`) | `'dialect:' must be a symbol such as :postgres` |
| `execute """ SELECT 1` ... (inside `up`)             | syntax error: `expected a line break after '"""'` |
| a multi-line string whose `SELECT 1"""` closes on a line with text | syntax error: `closing '"""' must be on its own line` |
| a multi-line string with a line indented less than its closing `"""` | syntax error: `line is indented less than the closing '"""'` |
| a multi-line string with a line ending in `\`       | syntax error: `unknown escape '\' at the end of a line` |
| a `"""` that is never closed                         | syntax error: `unterminated string` |
| `migration M, transaction: 0 { change { } }` (whole file) | `'transaction:' must be true or false` |
| `migration M, lock: true { change { } }` (whole file) | `unknown option 'lock' for migration` |
| `migration M, :fast { change { } }` (whole file)    | `migration takes only options, such as 'transaction: false'` |
| `migration M transaction: false { change { } }` (whole file) | syntax error: expected `,` after migration name |
| `add_index :t, []`                                  | syntax error: expected a value after `[` |
| `add_index :t, [:a, :a]`                            | `column 'a' listed twice in the index` |
| `add_column :t, [:a, :b], :string`                  | `add_column expects :column to be a symbol, found a list` |
| `add_index :t, :c, algorithm: :concurrently` (in a migration with a transaction) | `a concurrent index needs 'transaction: false' on the migration` |
| `add_index :t, :c, algorithm: :online`              | `'algorithm:' must be :concurrently` |
| `add_index :t, :c, where: " "`                      | `'where:' has no condition` |
| `add_index :t, :c, where: :active`                  | `'where:' must be a string` |
| `add_index :t, [:a, :b, ...]` with a default name over 63 bytes | `index name '...' is longer than 63 bytes; give the index a shorter 'name:'` |
| `add_column :t, :c, :string, time_zone: true`       | `'time_zone:' is only allowed on datetime columns` |
| `add_column :t, :c, :integer, default: 0.5`         | `decimal default is not allowed on integer column 'c'` |
| `add_column :t, :c, :string, default: :uuid`        | `default ':uuid' is not allowed on string column 'c'` |
| `add_column :t, :c, :float, default: 1.`            | syntax error: `invalid number '1.'` |
| `migration M { }`                                   | syntax error: expected `change`, `up` or `down` |
