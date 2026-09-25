//! `ffmig protect`
//!
//! Marks the database that the database url names so that `drop`
//! refuses it, even with `--force`, until `ffmig unprotect`. The mark lives
//! in the database server's catalog, so no config or environment variable
//! can bypass it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Env = @import("root.zig").Env;
const database = @import("database.zig");
const migrations = @import("migrations.zig");
const flags = @import("flags.zig");
const sql = @import("../sql/root.zig");
const unprotect = @import("unprotect.zig");

pub const usage =
    \\Usage:
    \\
    \\      ffmig protect [flags]
    \\
    \\Mark the database that the database url names so that drop refuses
    \\it, even with --force, until 'ffmig unprotect'.
    \\
    \\Flags:
    \\
++ flags.config_option ++ flags.url_option ++ flags.help_option;

pub fn run(env: Env, args: []const []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    return runWith(env, args, true, out, err);
}

/// `run` for `protect` and `unprotect`.
pub fn runWith(env: Env, args: []const []const u8, on: bool, out: *Writer, err: *Writer) Writer.Error!u8 {
    if (args.len != 0) {
        try err.writeAll(if (on) usage else unprotect.usage);
        return 1;
    }

    var arena_state: std.heap.ArenaAllocator = .init(env.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const target = try database.connect(env, arena, err) orelse return 1;
    defer target.conn.db.close();
    return setProtected(arena, target.conn, target.name, on, out, err);
}

/// `run` after connecting, split out so tests can pass a fake database.
pub fn setProtected(arena: Allocator, conn: migrations.Connection, name: []const u8, on: bool, out: *Writer, err: *Writer) Writer.Error!u8 {
    if (!(try database.check(arena, conn, .{ .exists = name }, err) orelse return 1)) {
        try err.print("ffmig: database {s} does not exist\n", .{name});
        return 1;
    }
    const statement: sql.Database = if (on) .{ .protect = name } else .{ .unprotect = name };
    if (!try database.exec(arena, conn, statement, err)) return 1;
    try out.print("{s} database {s}\n", .{ if (on) "Protected" else "Unprotected", name });
    return 0;
}
