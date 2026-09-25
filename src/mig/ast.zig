//! Typed, validated IR of a migration, produced by lowering. It records
//! meaning only (`ColumnType.json`, `IdKind.uuid`) and never SQL spellings;
//! each dialect maps it to SQL. See `MIG.md`.

const Span = @import("token.zig").Span;

pub const Migration = struct {
    name: []const u8,
    /// `transaction: false` runs the migration's statements outside a
    /// transaction, in either direction.
    transaction: bool = true,
    body: Body,
};

pub const Body = union(enum) {
    change: []Operation,
    up_down: struct { up: []Operation, down: []Operation },
};

pub const Operation = struct {
    kind: Kind,
    span: Span,

    pub const Kind = union(enum) {
        create_table: CreateTable,
        drop_table: DropTable,
        add_column: AddColumn,
        remove_column: RemoveColumn,
        rename_column: RenameColumn,
        add_index: AddIndex,
        remove_index: RemoveIndex,
        rename_table: RenameTable,
        change_column: ChangeColumn,
        change_column_null: ChangeColumnNull,
        change_column_default: ChangeColumnDefault,
        rename_index: RenameIndex,
        add_foreign_key: AddForeignKey,
        remove_foreign_key: RemoveForeignKey,
        execute: Execute,
    };
};

/// Type of the `id` primary key column; `none` is `id: false`.
pub const IdKind = enum { bigint, uuid, none };

pub const CreateTable = struct { table: []const u8, id: IdKind = .bigint, columns: []Column };
/// `columns` is null without a block, which makes the drop irreversible.
pub const DropTable = struct { table: []const u8, id: IdKind = .bigint, columns: ?[]Column };
pub const AddColumn = struct { table: []const u8, column: Column };
/// `column` is null without a type, which makes the removal irreversible.
pub const RemoveColumn = struct { table: []const u8, name: []const u8, column: ?Column };
pub const RenameColumn = struct { table: []const u8, from: []const u8, to: []const u8 };
/// `name` is null for the default name `index_<table>_on_<c1>_and_<c2>`.
pub const AddIndex = struct {
    table: []const u8,
    /// One or more, in index order.
    columns: []const []const u8,
    unique: bool = false,
    name: ?[]const u8 = null,
    /// A partial index's condition, SQL carried as written.
    where: ?[]const u8 = null,
    algorithm: ?IndexAlgorithm = null,
};
/// At least one of `columns` and `name` is set. `unique` and `where`
/// describe the index so that the undo can recreate it.
pub const RemoveIndex = struct {
    table: []const u8,
    columns: ?[]const []const u8,
    unique: bool = false,
    name: ?[]const u8,
    where: ?[]const u8 = null,
    algorithm: ?IndexAlgorithm = null,
};

/// How an index is built or dropped. `concurrently` does not block
/// writes to the table, and needs a migration without a transaction.
pub const IndexAlgorithm = enum { concurrently };

/// The longest name, in bytes, of a table, column, index or foreign key:
/// PostgreSQL's limit, which is the smallest among the databases the
/// language targets. PostgreSQL would cut a longer name short, and a
/// default name computed later would no longer find it.
pub const max_name_length = 63;

/// Also renames the indexes and foreign keys named after `from` by
/// default; see "rename_table" in `MIG.md`.
pub const RenameTable = struct { from: []const u8, to: []const u8 };
/// `from` is null without `from:`, which makes the change irreversible.
pub const ChangeColumn = struct { table: []const u8, column: []const u8, to: SizedType, from: ?SizedType };
/// `default` fills the column's nulls first; only when `null` is false.
pub const ChangeColumnNull = struct { table: []const u8, column: []const u8, null: bool, default: ?Default = null };
/// A `nil` literal is no default. `from` is null without `from:`, which
/// makes the change irreversible.
pub const ChangeColumnDefault = struct { table: []const u8, column: []const u8, from: ?Default, to: Default };
pub const RenameIndex = struct { table: []const u8, from: []const u8, to: []const u8 };
/// `name` is null for the default name `fk_<table>_on_<column>`.
pub const AddForeignKey = struct { table: []const u8, column: []const u8, foreign_key: ForeignKey, name: ?[]const u8 = null };
/// At least one of `column` and `name` is set. Reversible only with both
/// `column` and `to_table`.
pub const RemoveForeignKey = struct {
    table: []const u8,
    to_table: ?[]const u8,
    column: ?[]const u8,
    on_delete: ?OnDelete = null,
    name: ?[]const u8,
};

/// Raw SQL, run as written. Only in `up` / `down`, so never reversed.
pub const Execute = struct {
    sql: []const u8,
    /// With `dialect:`, only that dialect may run it.
    dialect: ?Dialect = null,
};

/// A database an `execute` is written for. The same values as
/// `sql.Dialect`, kept here so that the AST does not depend on codegen.
pub const Dialect = enum { postgres };

pub const ColumnType = enum { string, text, integer, bigint, float, decimal, boolean, date, datetime, time, binary, uuid, json };

/// A column type with its size options and time zone, which
/// `change_column` changes.
pub const SizedType = struct {
    type: ColumnType,
    limit: ?u32 = null,
    precision: ?u8 = null,
    scale: ?u8 = null,
    time_zone: bool = false,
};

pub const Column = struct {
    name: []const u8,
    type: ColumnType,
    null: bool = true,
    /// Optional, even when `null` is false.
    default: ?Default = null,
    /// `string` only.
    limit: ?u32 = null,
    /// `decimal` only; `scale` requires `precision`.
    precision: ?u8 = null,
    scale: ?u8 = null,
    /// `datetime` only: a point in time rather than a wall-clock reading.
    time_zone: bool = false,
    /// Set on the `<name>_id` column a `references` statement makes.
    reference: ?Reference = null,
    span: Span,
};

/// What a reference adds besides its column. The column's type is
/// `bigint` or `uuid`.
pub const Reference = struct {
    /// Null with `foreign_key: false`.
    foreign_key: ?ForeignKey,
    /// The index `index_<table>_on_<column>`, if any.
    index: ReferenceIndex,
};

/// `index:` of a reference: `false`, `true` or `:unique`.
pub const ReferenceIndex = enum { none, plain, unique };

/// Points at `table(id)`, named `fk_<table>_on_<column>` after the table
/// that has the column, unless `add_foreign_key` gives a `name:`.
pub const ForeignKey = struct {
    table: []const u8,
    /// Null for the database's default, which refuses the delete.
    on_delete: ?OnDelete = null,
};

pub const OnDelete = enum { cascade, nullify, restrict };

pub const Default = union(enum) {
    literal: Literal,
    /// Translated per dialect in codegen.
    named: NamedDefault,
};

pub const Literal = union(enum) {
    string: []const u8,
    integer: i64,
    /// As written, e.g. `0.50`, so it is never rounded.
    decimal: []const u8,
    boolean: bool,
    nil,
};

pub const NamedDefault = enum {
    now,
    /// A new random UUID for each row.
    uuid,

    /// Column types the named default may be used on.
    pub fn allows(n: NamedDefault, t: ColumnType) bool {
        return switch (n) {
            .now => t == .datetime or t == .date or t == .time,
            .uuid => t == .uuid,
        };
    }
};
