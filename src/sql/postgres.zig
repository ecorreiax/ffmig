//! PostgreSQL spellings for `root.zig`: type mapping, identifier quoting,
//! primary keys, literals, named defaults, the migration lock, timeouts
//! and the database lookup.

const std = @import("std");
const Writer = std.Io.Writer;
const ast = @import("../mig/ast.zig");
const root = @import("root.zig");

pub const capabilities: root.Capabilities = .{
    .transactional_ddl = true,
    .advisory_lock = true,
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

/// Key of the advisory lock: "ffmig" in ASCII. PostgreSQL scopes advisory
/// locks to the current database, so runs on different databases of one
/// server never wait for each other.
const lock_key = std.mem.readInt(u40, "ffmig", .big);

/// A session-level advisory lock: it outlives each migration's
/// transaction, and the server releases it if the connection drops.
pub fn lock(w: *Writer, l: root.Lock) Writer.Error!void {
    switch (l) {
        .try_lock => try w.print("SELECT 1 WHERE pg_try_advisory_lock({d})", .{lock_key}),
        .unlock => try w.print("SELECT pg_advisory_unlock({d})", .{lock_key}),
    }
}

/// `SET` without `LOCAL` lasts for the session, so it covers every
/// migration of the run, `transaction: false` ones included.
pub fn timeout(w: *Writer, t: root.Timeout) Writer.Error!void {
    switch (t) {
        .lock => |ms| try w.print("SET lock_timeout = '{d}ms'", .{ms}),
        .statement => |ms| try w.print("SET statement_timeout = '{d}ms'", .{ms}),
    }
}

pub fn databaseExists(w: *Writer, name: []const u8) Writer.Error!void {
    try w.writeAll("SELECT 1 FROM pg_database WHERE datname = ");
    try literal(w, .{ .string = name });
}

/// The protection mark is a custom setting on the database, which
/// PostgreSQL keeps in its catalog, so it survives everything short of
/// dropping the database and never depends on ffmig's own tables.
const protected_setting = "ffmig.protected";

pub fn setProtected(w: *Writer, name: []const u8, on: bool) Writer.Error!void {
    try w.writeAll("ALTER DATABASE ");
    try identifier(w, name);
    try w.writeAll(if (on) " SET " ++ protected_setting ++ " = on" else " RESET " ++ protected_setting);
}

pub fn databaseProtected(w: *Writer, name: []const u8) Writer.Error!void {
    try w.writeAll(
        \\SELECT 1 FROM pg_db_role_setting s JOIN pg_database d ON d.oid = s.setdatabase
        \\WHERE s.setrole = 0 AND '
    ++ protected_setting ++ "=on' = ANY (s.setconfig) AND d.datname = ");
    try literal(w, .{ .string = name });
}
