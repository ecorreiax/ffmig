//! `ffmig drop [--force]`
//!
//! Drops the database that the database url names, taking every
//! table with it, `schema_migrations` included, so the next `create` and
//! `migrate` start from nothing. Connects to the server's maintenance
//! database to do it. A missing database is not an error.
//!
//! Two guards, neither of which trusts the config:
//! - A database marked with `ffmig protect` is refused, `--force` or not.
//! - Otherwise the user must type the database name, after being shown the
//!   server it lives on. Without a terminal to ask on, `--force` stands in
//!   for the answer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const Env = @import("root.zig").Env;
const database = @import("database.zig");
const migrations = @import("migrations.zig");
const flags = @import("flags.zig");

pub const usage =
    \\Usage:
    \\
    \\      ffmig drop [flags]
    \\
    \\Drop the database that the database url names, schema_migrations
    \\included, after asking for its name. A protected database is
    \\refused.
    \\
    \\Flags:
    \\      --force               Do not ask; needed where nobody can answer
    \\
++ flags.config_option ++ flags.url_option ++ flags.help_option;

pub const Options = struct {
    /// Skip the confirmation prompt. Does not override `ffmig protect`.
    force: bool = false,
};

pub fn run(env: Env, args: []const []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    const options = parseArgs(args) orelse {
        try err.writeAll(usage);
        return 1;
    };

    var arena_state: std.heap.ArenaAllocator = .init(env.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const target = try database.connect(env, arena, err) orelse return 1;
    defer target.conn.db.close();
    return drop(arena, target.conn, target.name, options, env.stdin, out, err);
}

/// The options, or null for invalid arguments.
fn parseArgs(args: []const []const u8) ?Options {
    var options: Options = .{};
    var it: flags.Iterator = .{ .args = args };
    while (it.next()) |arg| switch (arg) {
        .flag => |f| if (f.isSwitch("--force")) {
            options.force = true;
        } else return null,
        .positional => return null,
    };
    return options;
}

/// `run` after connecting, split out so tests can pass a fake database
/// and canned input.
pub fn drop(
    arena: Allocator,
    conn: migrations.Connection,
    name: []const u8,
    options: Options,
    stdin: ?*Io.Reader,
    out: *Writer,
    err: *Writer,
) Writer.Error!u8 {
    if (!(try database.check(arena, conn, .{ .exists = name }, err) orelse return 1)) {
        try out.print("Database {s} does not exist\n", .{name});
        return 0;
    }
    if (try database.check(arena, conn, .{ .protected = name }, err) orelse return 1) {
        try err.print("ffmig: database {s} is protected; run 'ffmig unprotect' first to drop it\n", .{name});
        return 1;
    }
    if (!options.force and !try confirm(conn, name, stdin, err)) return 1;

    if (!try database.exec(arena, conn, .{ .drop = name }, err)) return 1;
    try out.print("Dropped database {s}\n", .{name});
    return 0;
}

/// Asks for the database name on `stdin`. Reports a refusal and returns
/// false when it does not match or nobody can answer.
fn confirm(conn: migrations.Connection, name: []const u8, stdin: ?*Io.Reader, err: *Writer) Writer.Error!bool {
    const server = conn.db.server();
    const in = stdin orelse {
        try err.print("ffmig: dropping database {s} on {s}:{s} needs confirmation; run it in a terminal or pass --force\n", .{ name, server.host, server.port });
        return false;
    };
    try err.print("This drops database {s} on {s}:{s} and everything in it.\n" ++
        "Type the database name to confirm: ", .{ name, server.host, server.port });
    try err.flush();
    const line = in.takeDelimiter('\n') catch null;
    if (line == null or !std.mem.eql(u8, std.mem.trim(u8, line.?, " \t\r"), name)) {
        try err.writeAll("ffmig: the name did not match; nothing was dropped\n");
        return false;
    }
    return true;
}
