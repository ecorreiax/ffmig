//! `ffmig rollback [--step N]`
//!
//! Undoes the last N applied migrations (default 1), newest first, using
//! each one's down plan: derived for `change`, as written for `up` /
//! `down`. Every file is parsed and its down plan derived before anything
//! runs, so an irreversible `change` stops the rollback untouched. Each
//! migration runs in its own transaction together with the delete of its
//! version.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Env = @import("root.zig").Env;
const check = @import("check.zig");
const migrations = @import("migrations.zig");
const mig = @import("../mig/root.zig");

pub const usage = "Usage: ffmig rollback [--step N]\n";

pub fn run(env: Env, args: []const []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    const step = parseArgs(args) orelse {
        try err.writeAll(usage);
        return 1;
    };

    var arena_state: std.heap.ArenaAllocator = .init(env.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var project = try migrations.Project.load(env, arena, err) orelse return 1;
    defer project.close(env.io);
    const conn = try migrations.connect(env, arena, project.url, err) orelse return 1;
    defer conn.db.close();
    return rollback(env, arena, project, conn, step, out, err);
}

/// The step count, or null for invalid arguments.
fn parseArgs(args: []const []const u8) ?usize {
    if (args.len == 0) return 1;
    if (args.len != 2 or !std.mem.eql(u8, args[0], "--step")) return null;
    const n = std.fmt.parseInt(usize, args[1], 10) catch return null;
    return if (n == 0) null else n;
}

/// `run` after connecting, split out so tests can pass a fake database.
pub fn rollback(
    env: Env,
    arena: Allocator,
    project: migrations.Project,
    conn: migrations.Connection,
    step: usize,
    out: *Writer,
    err: *Writer,
) Writer.Error!u8 {
    const applied = try migrations.appliedVersions(arena, conn, err) orelse return 1;
    if (applied.len == 0) {
        try out.writeAll("Nothing to roll back\n");
        return 0;
    }
    const versions = applied[applied.len - @min(step, applied.len) ..];

    const Undo = struct { parsed: migrations.Parsed, down: []const mig.ast.Operation };
    const undos = arena.alloc(Undo, versions.len) catch {
        try migrations.outOfMemory(err);
        return 1;
    };
    var ok = true;
    // Newest first.
    for (undos, 0..) |*u, i| {
        const version = versions[versions.len - 1 - i];
        const file = project.find(version) orelse {
            try err.print("ffmig: no file in {s} for applied migration {s}\n", .{ project.path, version });
            ok = false;
            continue;
        };
        const p = try project.parse(env.io, arena, file, err) orelse {
            ok = false;
            continue;
        };
        var diag: mig.Diagnostic = .{};
        const plan = mig.reverse.plan(arena, p.migration, &diag) catch |e| {
            switch (e) {
                error.OutOfMemory => try migrations.outOfMemory(err),
                error.Irreversible => try check.report(err, p.path, p.source, diag.span, "{s}; use 'up' / 'down' blocks to make it reversible", .{diag.message}),
            }
            ok = false;
            continue;
        };
        u.* = .{ .parsed = p, .down = plan.down };
    }
    if (!ok) {
        try err.writeAll("ffmig: nothing was rolled back\n");
        return 1;
    }

    for (undos) |u| {
        if (!try migrations.apply(arena, conn, u.parsed.path, u.down, .{ .delete = u.parsed.file.version }, err)) return 1;
        try out.print("Rolled back {s}\n", .{u.parsed.path});
    }
    return 0;
}
