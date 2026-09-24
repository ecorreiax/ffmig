//! SQL generation. Turns `ast.Operation`s into SQL statements for one
//! dialect, each ending with `;\n`: one per operation, plus an index
//! statement per reference (see `Statements`).
//!
//! This file holds what every dialect shares: the shape of each statement
//! and default index names. Each dialect file (`postgres.zig`) holds only
//! its spellings: type mapping, identifier quoting, primary keys, literals
//! and named defaults. Adding a dialect means adding a `Dialect` value and
//! a file; the `switch` statements below then point to what is missing.

const std = @import("std");
const Writer = std.Io.Writer;
const ast = @import("../mig/ast.zig");

pub const postgres = @import("postgres.zig");

pub const Dialect = enum { postgres };

/// Facts about a database that callers (`migrate`, `rollback`) read
/// instead of testing for a specific dialect.
pub const Capabilities = struct {
    /// DDL statements take part in transactions, so a failed migration
    /// leaves no partial schema change behind.
    transactional_ddl: bool,
    /// The database has a lock that `migrate` and `rollback` hold for the
    /// whole run (`Lock`), so two runs on one database take turns.
    advisory_lock: bool,
};

pub fn capabilities(dialect: Dialect) Capabilities {
    return switch (dialect) {
        .postgres => postgres.capabilities,
    };
}

pub fn write(dialect: Dialect, ops: []const ast.Operation, w: *Writer) Writer.Error!void {
    switch (dialect) {
        .postgres => try writeAll(postgres, ops, w),
    }
}

/// Table that records which migrations have run, one row per version:
/// `version`, the `checksum` of the file that ran (see
/// `commands/migrations.zig`), and when it ran (`applied_at`). Tables
/// created before `checksum` and `applied_at` existed get them added by
/// `upgrade`, with null in the rows already there: ffmig never knew those
/// values, so it does not make them up.
pub const tracking_table = "schema_migrations";

/// A statement that reads or writes the tracking table.
pub const Tracking = union(enum) {
    /// Creates the table if it does not exist.
    create,
    /// Selects one row if the table has every column that `create` gives
    /// it, none if an older ffmig created it.
    current,
    /// Adds the columns that `current` looks for. Only run when `current`
    /// finds none: adding a column locks the whole table, even when the
    /// column is already there.
    upgrade,
    /// Selects every recorded version, in order, with its checksum and
    /// its `applied_at` in whole seconds since 1970 (UTC).
    select,
    insert: struct { version: []const u8, checksum: []const u8 },
    delete: []const u8,
};

/// The columns after `version`, which `upgrade` adds to an older table.
const tracking_columns = [_][]const u8{ "checksum", "applied_at" };

/// Writes one tracking statement, without a trailing `;`.
pub fn writeTracking(dialect: Dialect, t: Tracking, w: *Writer) Writer.Error!void {
    switch (dialect) {
        .postgres => try tracking(postgres, t, w),
    }
}

fn tracking(comptime D: type, t: Tracking, w: *Writer) Writer.Error!void {
    switch (t) {
        .create => {
            try w.writeAll("CREATE TABLE IF NOT EXISTS ");
            try D.identifier(w, tracking_table);
            try w.writeAll(" (");
            try D.identifier(w, "version");
            try w.writeByte(' ');
            try D.columnType(w, .{ .name = "version", .type = .string, .span = .{ .start = 0, .end = 0 } });
            try w.writeAll(" PRIMARY KEY, ");
            try trackingColumn(D, "checksum", w);
            try w.writeAll(", ");
            try trackingColumn(D, "applied_at", w);
            try w.writeAll(" DEFAULT ");
            try D.namedDefault(w, .now, .datetime);
            try w.writeByte(')');
        },
        .current => try D.trackingCurrent(w, tracking_table, &tracking_columns),
        .upgrade => {
            // Added without the default, so the rows already there get
            // null instead of the time of the upgrade.
            try alterTable(D, tracking_table, w);
            for (tracking_columns) |c| {
                try w.writeAll(" ADD COLUMN IF NOT EXISTS ");
                try trackingColumn(D, c, w);
                try w.writeByte(',');
            }
            try w.writeAll(" ALTER COLUMN ");
            try D.identifier(w, "applied_at");
            try w.writeAll(" SET DEFAULT ");
            try D.namedDefault(w, .now, .datetime);
        },
        .select => {
            try w.writeAll("SELECT ");
            try D.identifier(w, "version");
            try w.writeAll(", ");
            try D.identifier(w, "checksum");
            try w.writeAll(", ");
            try D.epochSeconds(w, "applied_at");
            try w.writeAll(" FROM ");
            try D.identifier(w, tracking_table);
            try w.writeAll(" ORDER BY ");
            try D.identifier(w, "version");
        },
        .insert => |row| {
            try w.writeAll("INSERT INTO ");
            try D.identifier(w, tracking_table);
            try w.writeAll(" (");
            try D.identifier(w, "version");
            try w.writeAll(", ");
            try D.identifier(w, "checksum");
            try w.writeAll(") VALUES (");
            try D.literal(w, .{ .string = row.version });
            try w.writeAll(", ");
            try D.literal(w, .{ .string = row.checksum });
            try w.writeByte(')');
        },
        .delete => |v| {
            try w.writeAll("DELETE FROM ");
            try D.identifier(w, tracking_table);
            try w.writeAll(" WHERE ");
            try D.identifier(w, "version");
            try w.writeAll(" = ");
            try D.literal(w, .{ .string = v });
        },
    }
}

/// `"name" type` for one of `tracking_columns`, both nullable.
fn trackingColumn(comptime D: type, name: []const u8, w: *Writer) Writer.Error!void {
    try D.identifier(w, name);
    try w.writeByte(' ');
    if (std.mem.eql(u8, name, "applied_at")) return w.writeAll(D.instant_type);
    try D.columnType(w, .{ .name = name, .type = .string, .span = .{ .start = 0, .end = 0 } });
}

/// A statement on the lock that keeps two runs on one database apart.
/// Only for dialects whose `Capabilities.advisory_lock` is set.
pub const Lock = enum {
    /// Takes the lock if it is free. Selects one row if it was taken,
    /// none if another connection holds it.
    try_lock,
    /// Releases it.
    unlock,
};

/// Writes one lock statement, without a trailing `;`.
pub fn writeLock(dialect: Dialect, l: Lock, w: *Writer) Writer.Error!void {
    switch (dialect) {
        .postgres => try postgres.lock(w, l),
    }
}

/// A session setting that bounds how long each statement of `migrate`
/// and `rollback` may wait or run. Values are milliseconds, 0 for no
/// limit.
pub const Timeout = union(enum) {
    /// Waiting for a lock on a table or row.
    lock: u32,
    /// Running, waiting included.
    statement: u32,
};

/// Writes the statement that sets one timeout for the rest of the
/// session, without a trailing `;`.
pub fn writeTimeout(dialect: Dialect, t: Timeout, w: *Writer) Writer.Error!void {
    switch (dialect) {
        .postgres => try postgres.timeout(w, t),
    }
}

/// A statement that acts on a whole database, run by `create`, `drop`,
/// `protect` and `unprotect` from the maintenance database.
pub const Database = union(enum) {
    create: []const u8,
    drop: []const u8,
    /// Selects one row if the database exists, none otherwise.
    exists: []const u8,
    /// Marks the database so that `drop` refuses it.
    protect: []const u8,
    unprotect: []const u8,
    /// Selects one row if the database is protected, none otherwise.
    protected: []const u8,
};

/// Writes one database statement, without a trailing `;`.
pub fn writeDatabase(dialect: Dialect, d: Database, w: *Writer) Writer.Error!void {
    switch (dialect) {
        .postgres => try database(postgres, d, w),
    }
}

fn database(comptime D: type, d: Database, w: *Writer) Writer.Error!void {
    switch (d) {
        .create => |name| {
            try w.writeAll("CREATE DATABASE ");
            try D.identifier(w, name);
        },
        .drop => |name| {
            try w.writeAll("DROP DATABASE ");
            try D.identifier(w, name);
        },
        .exists => |name| try D.databaseExists(w, name),
        .protect => |name| try D.setProtected(w, name, true),
        .unprotect => |name| try D.setProtected(w, name, false),
        .protected => |name| try D.databaseProtected(w, name),
    }
}

/// `D` is a dialect file; see `postgres.zig` for the functions it provides.
fn writeAll(comptime D: type, ops: []const ast.Operation, w: *Writer) Writer.Error!void {
    var it: Statements = .{ .ops = ops };
    while (it.next()) |op| {
        try statement(D, op.kind, w);
        try w.writeAll(";\n");
    }
}

/// The operations that `ops` run as, one statement each: every operation,
/// each followed by an `add_index` for every reference column it adds
/// with `index: true` or `index: :unique`. Dropping a table or column drops its indexes, so
/// removals add nothing.
pub const Statements = struct {
    ops: []const ast.Operation,
    op: usize = 0,
    /// The next column of `ops[op]` to look at, once `ops[op]` itself has
    /// been returned.
    column: ?usize = null,

    pub fn next(s: *Statements) ?ast.Operation {
        while (s.op < s.ops.len) {
            const op = &s.ops[s.op];
            const i = s.column orelse {
                s.column = 0;
                return op.*;
            };
            const table, const columns = added(&op.kind);
            if (i < columns.len) {
                s.column = i + 1;
                const r = columns[i].reference orelse continue;
                if (r.index == .none) continue;
                return .{ .span = op.span, .kind = .{ .add_index = .{
                    .table = table,
                    .column = columns[i].name,
                    .unique = r.index == .unique,
                } } };
            }
            s.op += 1;
            s.column = null;
        }
        return null;
    }

    /// The table and the columns that `kind` adds.
    fn added(kind: *const ast.Operation.Kind) struct { []const u8, []const ast.Column } {
        return switch (kind.*) {
            .create_table => |*o| .{ o.table, o.columns },
            .add_column => |*o| .{ o.table, (&o.column)[0..1] },
            else => .{ "", &.{} },
        };
    }
};

/// Writes one operation as a single statement, without a trailing `;`.
pub fn writeStatement(dialect: Dialect, op: ast.Operation, w: *Writer) Writer.Error!void {
    switch (dialect) {
        .postgres => try statement(postgres, op.kind, w),
    }
}

fn statement(comptime D: type, kind: ast.Operation.Kind, w: *Writer) Writer.Error!void {
    switch (kind) {
        .create_table => |o| {
            try w.writeAll("CREATE TABLE ");
            try D.identifier(w, o.table);
            if (o.id == .none and o.columns.len == 0) return w.writeAll(" ()");
            try w.writeAll(" (");
            var first = true;
            if (o.id != .none) {
                try w.writeAll("\n  ");
                try D.primaryKey(w, o.id);
                first = false;
            }
            for (o.columns) |c| {
                try w.writeAll(if (first) "\n  " else ",\n  ");
                try column(D, o.table, c, w);
                first = false;
            }
            try w.writeAll("\n)");
        },
        .drop_table => |o| {
            try w.writeAll("DROP TABLE ");
            try D.identifier(w, o.table);
        },
        .add_column => |o| {
            try alterTable(D, o.table, w);
            try w.writeAll(" ADD COLUMN ");
            try column(D, o.table, o.column, w);
        },
        .remove_column => |o| {
            try alterTable(D, o.table, w);
            try w.writeAll(" DROP COLUMN ");
            try D.identifier(w, o.name);
        },
        .rename_column => |o| {
            try alterTable(D, o.table, w);
            try w.writeAll(" RENAME COLUMN ");
            try D.identifier(w, o.from);
            try w.writeAll(" TO ");
            try D.identifier(w, o.to);
        },
        .add_index => |o| {
            try w.writeAll(if (o.unique) "CREATE UNIQUE INDEX " else "CREATE INDEX ");
            try indexName(D, o.table, o.column, o.name, w);
            try w.writeAll(" ON ");
            try D.identifier(w, o.table);
            try w.writeAll(" (");
            try D.identifier(w, o.column);
            try w.writeByte(')');
        },
        .remove_index => |o| {
            try w.writeAll("DROP INDEX ");
            // Lowering guarantees a column or a name.
            try indexName(D, o.table, o.column orelse "", o.name, w);
        },
    }
}

fn alterTable(comptime D: type, table: []const u8, w: *Writer) Writer.Error!void {
    try w.writeAll("ALTER TABLE ");
    try D.identifier(w, table);
}

/// `name`, or the default `index_<table>_on_<column>`, quoted.
fn indexName(comptime D: type, table: []const u8, col: []const u8, name: ?[]const u8, w: *Writer) Writer.Error!void {
    if (name) |n| return D.identifier(w, n);
    try D.identifierParts(w, &.{ "index_", table, "_on_", col });
}

/// `"name" type [DEFAULT value] [NOT NULL] [foreign key]`, for a column of
/// `table`.
fn column(comptime D: type, table: []const u8, c: ast.Column, w: *Writer) Writer.Error!void {
    try D.identifier(w, c.name);
    try w.writeByte(' ');
    try D.columnType(w, c);
    if (c.default) |d| {
        try w.writeAll(" DEFAULT ");
        switch (d) {
            .literal => |l| try D.literal(w, l),
            .named => |n| try D.namedDefault(w, n, c.type),
        }
    }
    if (!c.null) try w.writeAll(" NOT NULL");
    const r = c.reference orelse return;
    const fk = r.foreign_key orelse return;
    try w.writeAll(" CONSTRAINT ");
    try D.identifierParts(w, &.{ "fk_", table, "_on_", c.name });
    try w.writeAll(" REFERENCES ");
    try D.identifier(w, fk.table);
    try w.writeAll(" (");
    try D.identifier(w, "id");
    try w.writeByte(')');
    if (fk.on_delete) |a| try w.writeAll(switch (a) {
        .cascade => " ON DELETE CASCADE",
        .nullify => " ON DELETE SET NULL",
        .restrict => " ON DELETE RESTRICT",
    });
}
