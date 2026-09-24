//! Indented text dump of an `ast.Migration`, for `ffmig check --ast` and
//! the golden tests in `tests/mig`. Deterministic and free of spans.
//!
//! ```
//! migration CreateUsersProfile
//!   change
//!     create_table users_profile id=uuid
//!       column name string null
//!       column email string not_null limit=255
//!       column owner_id uuid not_null reference fk=users on_delete=cascade index
//!     add_index users_profile email unique
//! ```
//!
//! `execute` prints its SQL as one escaped string: `execute "SELECT 1\n"`.

const std = @import("std");
const Writer = std.Io.Writer;
const ast = @import("ast.zig");
const reverse = @import("reverse.zig");

pub fn migration(w: *Writer, m: ast.Migration) Writer.Error!void {
    try header(w, m);
    switch (m.body) {
        .change => |ops| try section(w, "change", ops),
        .up_down => |b| {
            try section(w, "up", b.up);
            try section(w, "down", b.down);
        },
    }
}

/// `m` as its `reverse.plan` `p`: `up` and `down` sections, the same as
/// an `up` / `down` migration prints.
pub fn plan(w: *Writer, m: ast.Migration, p: reverse.Plan) Writer.Error!void {
    try header(w, m);
    try section(w, "up", p.up);
    try section(w, "down", p.down);
}

/// `migration <name>`, and `transaction=false` when it opted out.
fn header(w: *Writer, m: ast.Migration) Writer.Error!void {
    try w.print("migration {s}", .{m.name});
    if (!m.transaction) try w.writeAll(" transaction=false");
    try w.writeByte('\n');
}

fn section(w: *Writer, name: []const u8, ops: []const ast.Operation) Writer.Error!void {
    try w.print("  {s}\n", .{name});
    for (ops) |op| try operation(w, op.kind);
}

fn operation(w: *Writer, kind: ast.Operation.Kind) Writer.Error!void {
    try w.print("    {t}", .{kind});
    switch (kind) {
        .create_table => |o| {
            try w.print(" {s} id={t}\n", .{ o.table, o.id });
            try columns(w, o.columns);
        },
        .drop_table => |o| {
            try w.print(" {s} id={t}", .{ o.table, o.id });
            if (o.columns) |cols| {
                try w.writeByte('\n');
                try columns(w, cols);
            } else try w.writeAll(" no_columns\n");
        },
        .add_column => |o| {
            try w.print(" {s}\n", .{o.table});
            try column(w, o.column);
        },
        .remove_column => |o| {
            try w.print(" {s} {s}\n", .{ o.table, o.name });
            if (o.column) |c| try column(w, c);
        },
        .rename_column => |o| try w.print(" {s} {s} {s}\n", .{ o.table, o.from, o.to }),
        .add_index => |o| try index(w, o.table, o.column, o.unique, o.name),
        .remove_index => |o| try index(w, o.table, o.column, o.unique, o.name),
        .rename_table => |o| try w.print(" {s} {s}\n", .{ o.from, o.to }),
        .change_column => |o| {
            try w.print(" {s} {s} ", .{ o.table, o.column });
            try sizedType(w, o.to, "");
            if (o.from) |from| {
                try w.writeAll(" from=");
                try sizedType(w, from, "from_");
            }
            try w.writeByte('\n');
        },
        .change_column_null => |o| {
            try w.print(" {s} {s} {s}", .{ o.table, o.column, if (o.null) "null" else "not_null" });
            if (o.default) |d| {
                try w.writeAll(" default=");
                try defaultValue(w, d);
            }
            try w.writeByte('\n');
        },
        .change_column_default => |o| {
            try w.print(" {s} {s}", .{ o.table, o.column });
            if (o.from) |d| {
                try w.writeAll(" from=");
                try defaultValue(w, d);
            }
            try w.writeAll(" to=");
            try defaultValue(w, o.to);
            try w.writeByte('\n');
        },
        .rename_index => |o| try w.print(" {s} \"{f}\" \"{f}\"\n", .{ o.table, std.zig.fmtString(o.from), std.zig.fmtString(o.to) }),
        .add_foreign_key => |o| try foreignKey(w, o.table, o.foreign_key.table, o.column, o.foreign_key.on_delete, o.name),
        .remove_foreign_key => |o| try foreignKey(w, o.table, o.to_table, o.column, o.on_delete, o.name),
        .execute => |o| {
            try w.print(" \"{f}\"", .{std.zig.fmtString(o.sql)});
            if (o.dialect) |d| try w.print(" dialect={t}", .{d});
            try w.writeByte('\n');
        },
    }
}

fn index(w: *Writer, table: []const u8, col: ?[]const u8, unique: bool, name: ?[]const u8) Writer.Error!void {
    try w.print(" {s}", .{table});
    if (col) |c| try w.print(" {s}", .{c});
    if (unique) try w.writeAll(" unique");
    if (name) |n| try w.print(" name=\"{f}\"", .{std.zig.fmtString(n)});
    try w.writeByte('\n');
}

/// `string limit=255`; `prefix` goes before each size option's name.
fn sizedType(w: *Writer, t: ast.SizedType, comptime prefix: []const u8) Writer.Error!void {
    try w.print("{t}", .{t.type});
    if (t.limit) |n| try w.print(" " ++ prefix ++ "limit={d}", .{n});
    if (t.precision) |n| try w.print(" " ++ prefix ++ "precision={d}", .{n});
    if (t.scale) |n| try w.print(" " ++ prefix ++ "scale={d}", .{n});
}

fn foreignKey(
    w: *Writer,
    table: []const u8,
    to_table: ?[]const u8,
    col: ?[]const u8,
    on_delete: ?ast.OnDelete,
    name: ?[]const u8,
) Writer.Error!void {
    try w.print(" {s}", .{table});
    if (to_table) |t| try w.print(" {s}", .{t});
    if (col) |c| try w.print(" column={s}", .{c});
    if (on_delete) |a| try w.print(" on_delete={t}", .{a});
    if (name) |n| try w.print(" name=\"{f}\"", .{std.zig.fmtString(n)});
    try w.writeByte('\n');
}

fn columns(w: *Writer, cols: []const ast.Column) Writer.Error!void {
    for (cols) |c| try column(w, c);
}

fn column(w: *Writer, c: ast.Column) Writer.Error!void {
    try w.print("      column {s} {t} {s}", .{ c.name, c.type, if (c.null) "null" else "not_null" });
    if (c.limit) |n| try w.print(" limit={d}", .{n});
    if (c.precision) |n| try w.print(" precision={d}", .{n});
    if (c.scale) |n| try w.print(" scale={d}", .{n});
    if (c.default) |d| {
        try w.writeAll(" default=");
        try defaultValue(w, d);
    }
    if (c.reference) |r| {
        try w.writeAll(" reference");
        if (r.foreign_key) |fk| {
            try w.print(" fk={s}", .{fk.table});
            if (fk.on_delete) |a| try w.print(" on_delete={t}", .{a});
        }
        switch (r.index) {
            .none => {},
            .plain => try w.writeAll(" index"),
            .unique => try w.writeAll(" unique_index"),
        }
    }
    try w.writeByte('\n');
}

fn defaultValue(w: *Writer, d: ast.Default) Writer.Error!void {
    switch (d) {
        .named => |n| try w.print(":{t}", .{n}),
        .literal => |l| switch (l) {
            .string => |s| try w.print("\"{f}\"", .{std.zig.fmtString(s)}),
            .integer => |i| try w.print("{d}", .{i}),
            .boolean => |b| try w.print("{}", .{b}),
            .nil => try w.writeAll("nil"),
        },
    }
}
