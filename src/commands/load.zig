//! `ffmig load [--force]`
//!
//! Runs the file that `ffmig dump` wrote against the database, to set up
//! a fresh database without replaying every migration: its schema, and
//! `schema_migrations` with the migrations it had applied. The file runs
//! as one implicit transaction, so a failure leaves nothing behind.
//!
//! Refuses a database that already records applied migrations, unless
//! `--force`: loading on top of a schema fails, or mixes the two.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Env = @import("root.zig").Env;
const migrations = @import("migrations.zig");
const flags = @import("flags.zig");
const sql = @import("../sql/root.zig");
const db = @import("../db/root.zig");

pub const usage =
    \\Usage:
    \\
    \\      ffmig load [flags]
    \\
    \\Create the schema that 'ffmig dump' wrote to schema.sql (or the [dump]
    \\path in ffmig.toml) in an empty database, with its migrations recorded
    \\as applied.
    \\
    \\Flags:
    \\      --force               Load even if the database records applied
    \\                            migrations
    \\
++ flags.config_option ++ flags.url_option ++ flags.help_option;

/// Largest dump file that `load` reads.
const max_size = 256 * 1024 * 1024;

pub fn run(env: Env, args: []const []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    var force = false;
    var it: flags.Iterator = .{ .args = args };
    while (it.next()) |arg| switch (arg) {
        .flag => |f| if (f.isSwitch("--force")) {
            force = true;
        } else return usageError(err),
        .positional => return usageError(err),
    };

    var arena_state: std.heap.ArenaAllocator = .init(env.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cfg = try migrations.loadConfig(env, arena, err) orelse return 1;
    const path = cfg.dump.path.?;
    const source = env.cwd.readFileAlloc(env.io, path, arena, .limited(max_size)) catch |e| {
        switch (e) {
            error.FileNotFound => try err.print("ffmig: {s} not found; run 'ffmig dump' first\n", .{path}),
            else => try err.print("ffmig: cannot read {s}: {t}\n", .{ path, e }),
        }
        return 1;
    };
    // Not `Project.connect`: the file may be what creates the schema.
    const conn = try migrations.connect(env, arena, cfg.url, err) orelse return 1;
    defer conn.db.close();

    if (!force) {
        const applied = try hasApplied(arena, conn, cfg.schema, err) orelse return 1;
        if (applied) {
            try err.print("ffmig: the database already records applied migrations; load {s} into an empty database, or pass --force\n", .{path});
            return 1;
        }
    }
    var diag: db.Diagnostic = .{};
    conn.db.exec(source, &diag) catch |e| {
        const context = std.fmt.allocPrint(arena, "cannot load {s}", .{path}) catch "cannot load";
        try migrations.dbError(e, err, context, diag);
        return 1;
    };
    try out.print("Loaded the schema from {s}\n", .{path});
    return 0;
}

/// Whether the tracking table, in `schema` when set, exists and has a
/// row. Null after reporting an error.
fn hasApplied(arena: Allocator, conn: migrations.Connection, schema: ?[]const u8, err: *Writer) Writer.Error!?bool {
    if (schema) |name| {
        const exists = try query(arena, conn, .{ .schema = .{ .exists = name } }, err) orelse return null;
        if (!exists) return false;
        if (!try migrations.useSchema(arena, conn, name, err)) return null;
    }
    const table = try query(arena, conn, .{ .tracking = .schema }, err) orelse return null;
    if (!table) return false;
    return try query(arena, conn, .{ .tracking = .any }, err);
}

const Statement = union(enum) { schema: sql.Schema, tracking: sql.Tracking };

/// Whether `s` selects a row. Null after reporting an error.
fn query(arena: Allocator, conn: migrations.Connection, s: Statement, err: *Writer) Writer.Error!?bool {
    var w: Writer.Allocating = .init(arena);
    const written = switch (s) {
        .schema => |x| sql.writeSchema(conn.dialect, x, &w.writer),
        .tracking => |x| sql.writeTracking(conn.dialect, x, &w.writer),
    };
    written catch {
        try migrations.outOfMemory(err);
        return null;
    };
    var diag: db.Diagnostic = .{};
    const rows = conn.db.query(arena, w.written(), &diag) catch |e| {
        try migrations.dbError(e, err, "cannot read " ++ sql.tracking_table, diag);
        return null;
    };
    return rows.len != 0;
}

fn usageError(err: *Writer) Writer.Error!u8 {
    try err.writeAll(usage);
    return 1;
}
