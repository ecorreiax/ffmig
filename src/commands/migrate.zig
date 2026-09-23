//! `ffmig migrate`
//!
//! Runs, in version order, every migration whose version is not recorded
//! in `schema_migrations`. Every pending file is parsed and checked before
//! anything runs, so a broken file never leaves half a batch applied.
//! Each migration runs in its own transaction together with the insert of
//! its version; a failure stops the batch and keeps what already ran.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Env = @import("root.zig").Env;
const migrations = @import("migrations.zig");

pub const usage = "Usage: ffmig migrate\n";

pub fn run(env: Env, args: []const []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    if (args.len != 0) {
        try err.writeAll(usage);
        return 1;
    }

    var arena_state: std.heap.ArenaAllocator = .init(env.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var project = try migrations.Project.load(env, arena, err) orelse return 1;
    defer project.close(env.io);
    const conn = try migrations.connect(env, arena, project.url, err) orelse return 1;
    defer conn.db.close();
    return migrate(env, arena, project, conn, out, err);
}

/// `run` after connecting, split out so tests can pass a fake database.
pub fn migrate(
    env: Env,
    arena: Allocator,
    project: migrations.Project,
    conn: migrations.Connection,
    out: *Writer,
    err: *Writer,
) Writer.Error!u8 {
    const applied = try migrations.appliedVersions(arena, conn, err) orelse return 1;
    const files = migrations.pending(arena, project.files, applied) catch {
        try migrations.outOfMemory(err);
        return 1;
    };
    if (files.len == 0) {
        try out.writeAll("Nothing to migrate\n");
        return 0;
    }

    const parsed = arena.alloc(migrations.Parsed, files.len) catch {
        try migrations.outOfMemory(err);
        return 1;
    };
    var ok = true;
    for (files, parsed) |f, *p| {
        if (try project.parse(env.io, arena, f, err)) |m| p.* = m else ok = false;
    }
    if (!ok) {
        try err.writeAll("ffmig: nothing was migrated\n");
        return 1;
    }

    for (parsed) |p| {
        const ops = switch (p.migration.body) {
            .change => |ops| ops,
            .up_down => |b| b.up,
        };
        if (!try migrations.apply(arena, conn, p.path, ops, .{ .insert = p.file.version }, err)) return 1;
        try out.print("Migrated {s}\n", .{p.path});
    }
    return 0;
}
