//! Indented text dump of an `ast.Migration`, for `ffmig check --ast` and
//! the golden tests in `tests/mig`. Deterministic and free of spans.
//!
//! ```
//! migration CreateUsersProfile
//!   change
//!     create_table users_profile id=uuid
//!       column name string null
//!       column email string not_null limit=255
//!     add_index users_profile email unique
//! ```

const std = @import("std");
const Writer = std.Io.Writer;
const ast = @import("ast.zig");

pub fn migration(w: *Writer, m: ast.Migration) Writer.Error!void {
    try w.print("migration {s}\n", .{m.name});
    switch (m.body) {
        .change => |ops| try section(w, "change", ops),
        .up_down => |b| {
            try section(w, "up", b.up);
            try section(w, "down", b.down);
        },
    }
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
    }
}

fn index(w: *Writer, table: []const u8, col: ?[]const u8, unique: bool, name: ?[]const u8) Writer.Error!void {
    try w.print(" {s}", .{table});
    if (col) |c| try w.print(" {s}", .{c});
    if (unique) try w.writeAll(" unique");
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
    try w.writeByte('\n');
}
