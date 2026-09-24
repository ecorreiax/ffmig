//! `ffmig migrate [--lock-wait SECONDS] [--strict]`
//!
//! Runs, in version order, every migration whose version is not recorded
//! in `schema_migrations`. Every pending file is parsed and checked before
//! anything runs, so a broken file never leaves half a batch applied.
//! Each migration runs in its own transaction together with the insert of
//! its version and checksum, unless it has `transaction: false`; a
//! failure stops the batch and keeps what already ran. The `[migration]`
//! timeouts in `ffmig.toml` are set first. The whole run holds the
//! migration lock, so a concurrent `migrate` or `rollback` on the same
//! database waits for it (up to `--lock-wait` seconds) and then sees what
//! this one applied.
//!
//! An applied file whose checksum no longer matches gets a warning, or,
//! with `--strict`, stops the run before anything is applied. A pending
//! file older than the newest applied version gets a note and still runs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Env = @import("root.zig").Env;
const migrations = @import("migrations.zig");
const sql = @import("../sql/root.zig");

pub const usage = "Usage: ffmig migrate [--lock-wait SECONDS] [--strict]\n";

pub const Options = struct {
    /// Seconds to wait for another run to release the migration lock.
    lock_wait: u32 = migrations.default_lock_wait,
    /// Refuse to run when an applied file has changed, instead of warning.
    strict: bool = false,
};

pub fn run(env: Env, args: []const []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    const options = parseArgs(args) orelse {
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
    return migrate(env, arena, project, conn, options, out, err);
}

/// The options, or null for invalid arguments.
fn parseArgs(args: []const []const u8) ?Options {
    var options: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--strict")) {
            options.strict = true;
        } else if (std.mem.eql(u8, args[i], "--lock-wait")) {
            i += 1;
            if (i == args.len) return null;
            options.lock_wait = migrations.parseLockWait(args[i]) orelse return null;
        } else return null;
    }
    return options;
}

/// `run` after connecting, split out so tests can pass a fake database.
pub fn migrate(
    env: Env,
    arena: Allocator,
    project: migrations.Project,
    conn: migrations.Connection,
    options: Options,
    out: *Writer,
    err: *Writer,
) Writer.Error!u8 {
    if (!try migrations.setTimeouts(arena, conn, project.timeouts, err) or
        !try migrations.lock(env.io, arena, conn, options.lock_wait, err))
    {
        try err.writeAll("ffmig: nothing was migrated\n");
        return 1;
    }
    defer migrations.unlock(arena, conn);
    const applied = try migrations.readApplied(arena, conn, err) orelse return 1;
    if (!try checkApplied(env, arena, project, applied, options.strict, err)) {
        try err.writeAll("ffmig: nothing was migrated\n");
        return 1;
    }
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

    const newest = if (applied.len == 0) "" else applied[applied.len - 1].version;
    for (parsed) |p| {
        const ops = switch (p.migration.body) {
            .change => |ops| ops,
            .up_down => |b| b.up,
        };
        if (std.mem.order(u8, p.file.version, newest) == .lt) {
            try err.print("ffmig: note: {s} is older than the last applied migration {s}\n", .{ p.path, newest });
        }
        const tracking: sql.Tracking = .{ .insert = .{ .version = p.file.version, .checksum = &p.checksum } };
        if (!try migrations.apply(arena, conn, p.path, ops, tracking, p.migration.transaction, err)) return 1;
        try out.print("Migrated {s}\n", .{p.path});
    }
    return 0;
}

/// Reports every applied file that has changed since it ran: a warning,
/// or an error when `strict` is set. Returns false if the run must stop.
fn checkApplied(
    env: Env,
    arena: Allocator,
    project: migrations.Project,
    applied: []const migrations.Applied,
    strict: bool,
    err: *Writer,
) Writer.Error!bool {
    var ok = true;
    for (applied) |a| {
        const file = project.find(a.version) orelse continue;
        const changed = try project.changed(env.io, arena, file, a, err) orelse {
            ok = false;
            continue;
        };
        if (!changed) continue;
        const path = project.shown(arena, file.name) catch {
            try migrations.outOfMemory(err);
            return false;
        };
        try err.print("ffmig: {s}{s} has changed since it was applied; its changes will not run\n", .{ if (strict) "" else "warning: ", path });
        if (strict) ok = false;
    }
    return ok;
}
