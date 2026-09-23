//! SQL generation. Turns `ast.Operation`s into SQL statements for one
//! dialect, one statement per operation, each ending with `;\n`.
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

/// Table that records which migrations have run, one row per version.
pub const tracking_table = "schema_migrations";

/// A statement that reads or writes the tracking table.
pub const Tracking = union(enum) {
    /// Creates the table if it does not exist.
    create,
    /// Selects every recorded version, one per row, in order.
    select,
    insert: []const u8,
    delete: []const u8,
};

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
            try w.writeAll(" PRIMARY KEY)");
        },
        .select => {
            try w.writeAll("SELECT ");
            try D.identifier(w, "version");
            try w.writeAll(" FROM ");
            try D.identifier(w, tracking_table);
            try w.writeAll(" ORDER BY ");
            try D.identifier(w, "version");
        },
        .insert => |v| {
            try w.writeAll("INSERT INTO ");
            try D.identifier(w, tracking_table);
            try w.writeAll(" (");
            try D.identifier(w, "version");
            try w.writeAll(") VALUES (");
            try D.literal(w, .{ .string = v });
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

/// `D` is a dialect file; see `postgres.zig` for the functions it provides.
fn writeAll(comptime D: type, ops: []const ast.Operation, w: *Writer) Writer.Error!void {
    for (ops) |op| {
        try statement(D, op.kind, w);
        try w.writeAll(";\n");
    }
}

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
                try column(D, c, w);
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
            try column(D, o.column, w);
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

/// `"name" type [DEFAULT value] [NOT NULL]`
fn column(comptime D: type, c: ast.Column, w: *Writer) Writer.Error!void {
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
}
