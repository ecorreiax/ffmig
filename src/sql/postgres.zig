//! PostgreSQL spellings for `root.zig`: type mapping, identifier quoting,
//! primary keys, literals and named defaults.

const std = @import("std");
const Writer = std.Io.Writer;
const ast = @import("../mig/ast.zig");
const Capabilities = @import("root.zig").Capabilities;

pub const capabilities: Capabilities = .{
    .transactional_ddl = true,
};

/// `"name"`, with embedded `"` doubled.
pub fn identifier(w: *Writer, name: []const u8) Writer.Error!void {
    return identifierParts(w, &.{name});
}

/// The concatenation of `parts` as one quoted identifier.
pub fn identifierParts(w: *Writer, parts: []const []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (parts) |part| try escaped(w, part, '"');
    try w.writeByte('"');
}

/// `s` with each `quote` doubled.
fn escaped(w: *Writer, s: []const u8, quote: u8) Writer.Error!void {
    var rest = s;
    while (std.mem.indexOfScalar(u8, rest, quote)) |i| {
        try w.writeAll(rest[0 .. i + 1]);
        try w.writeByte(quote);
        rest = rest[i + 1 ..];
    }
    try w.writeAll(rest);
}

pub fn primaryKey(w: *Writer, id: ast.IdKind) Writer.Error!void {
    try w.writeAll(switch (id) {
        .bigint => "\"id\" bigserial PRIMARY KEY",
        .uuid => "\"id\" uuid PRIMARY KEY DEFAULT gen_random_uuid()",
        .none => unreachable,
    });
}

pub fn columnType(w: *Writer, c: ast.Column) Writer.Error!void {
    switch (c.type) {
        .string => if (c.limit) |n| try w.print("varchar({d})", .{n}) else try w.writeAll("varchar"),
        .decimal => if (c.precision) |p| {
            if (c.scale) |s| try w.print("numeric({d}, {d})", .{ p, s }) else try w.print("numeric({d})", .{p});
        } else try w.writeAll("numeric"),
        .text => try w.writeAll("text"),
        .integer => try w.writeAll("integer"),
        .bigint => try w.writeAll("bigint"),
        .float => try w.writeAll("double precision"),
        .boolean => try w.writeAll("boolean"),
        .date => try w.writeAll("date"),
        .datetime => try w.writeAll("timestamp(6)"),
        .time => try w.writeAll("time"),
        .binary => try w.writeAll("bytea"),
        .uuid => try w.writeAll("uuid"),
        .json => try w.writeAll("jsonb"),
    }
}

/// Strings are single-quoted with `'` doubled. Backslashes are literal
/// under `standard_conforming_strings`, the default since PostgreSQL 9.1.
pub fn literal(w: *Writer, l: ast.Literal) Writer.Error!void {
    switch (l) {
        .string => |s| {
            try w.writeByte('\'');
            try escaped(w, s, '\'');
            try w.writeByte('\'');
        },
        .integer => |i| try w.print("{d}", .{i}),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .nil => try w.writeAll("NULL"),
    }
}

/// `CURRENT_TIMESTAMP` fits `date` and `time` columns too, through
/// PostgreSQL's assignment casts.
pub fn namedDefault(w: *Writer, n: ast.NamedDefault, _: ast.ColumnType) Writer.Error!void {
    try w.writeAll(switch (n) {
        .now => "CURRENT_TIMESTAMP",
    });
}
