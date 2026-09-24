//! `ffmig create`
//!
//! Creates the database that the database url names, connecting to
//! the server's maintenance database to do it. An existing database is
//! left alone.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Env = @import("root.zig").Env;
const database = @import("database.zig");
const migrations = @import("migrations.zig");
const flags = @import("flags.zig");

pub const usage =
    \\Usage: ffmig create [flags]
    \\
    \\Create the database that the database url names, unless it exists.
    \\
    \\Flags:
    \\
++ flags.config_option ++ flags.url_option ++ flags.help_option;

pub fn run(env: Env, args: []const []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    if (args.len != 0) {
        try err.writeAll(usage);
        return 1;
    }

    var arena_state: std.heap.ArenaAllocator = .init(env.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const target = try database.connect(env, arena, err) orelse return 1;
    defer target.conn.db.close();
    return create(arena, target.conn, target.name, out, err);
}

/// `run` after connecting, split out so tests can pass a fake database.
pub fn create(arena: Allocator, conn: migrations.Connection, name: []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    if (try database.check(arena, conn, .{ .exists = name }, err) orelse return 1) {
        try out.print("Database {s} already exists\n", .{name});
        return 0;
    }
    if (!try database.exec(arena, conn, .{ .create = name }, err)) return 1;
    try out.print("Created database {s}\n", .{name});
    return 0;
}
