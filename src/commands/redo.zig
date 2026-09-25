//! `ffmig redo [--step N] [--lock-wait SECONDS]`
//!
//! Rolls back the last N applied migrations (default 1), newest first,
//! then applies the same ones again, oldest first: the loop of writing a
//! migration, trying it and changing it. Other pending files stay
//! pending. Every file is parsed, and its down plan derived, before
//! anything runs, and the migration lock is held across both halves, so
//! no other run can slip in between. Each migration runs as `rollback`
//! and `migrate` run it; a failure stops the redo and keeps what already
//! ran.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Env = @import("root.zig").Env;
const migrations = @import("migrations.zig");
const rollback = @import("rollback.zig");
const flags = @import("flags.zig");
const dump = @import("dump.zig");

pub const usage =
    \\Usage:
    \\
    \\      ffmig redo [flags]
    \\
    \\Undo the last applied migration and apply it again.
    \\
    \\Flags:
    \\      --step <n>            Redo the last n instead
    \\      --lock-wait <s>       Wait up to s seconds for another migrate or
    \\                            rollback to finish (default: 60; 0: do not wait)
    \\
++ flags.config_option ++ flags.url_option ++ flags.help_option;

pub const Options = struct {
    /// How many of the newest applied migrations to redo.
    step: usize = 1,
    /// Seconds to wait for another run to release the migration lock.
    lock_wait: u32 = migrations.default_lock_wait,
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
    const conn = try project.connect(env, arena, err) orelse return 1;
    defer conn.db.close();
    return redo(env, arena, project, conn, options, out, err);
}

/// The options, or null for invalid arguments.
fn parseArgs(args: []const []const u8) ?Options {
    var options: Options = .{};
    var it: flags.Iterator = .{ .args = args };
    while (it.next()) |arg| switch (arg) {
        .flag => |f| if (f.is("--step")) {
            options.step = rollback.parseStep(it.value(f) orelse return null) orelse return null;
        } else if (f.is("--lock-wait")) {
            options.lock_wait = migrations.parseLockWait(it.value(f) orelse return null) orelse return null;
        } else return null,
        .positional => return null,
    };
    return options;
}

/// `run` after connecting, split out so tests can pass a fake database.
pub fn redo(
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
        try err.writeAll("ffmig: nothing was redone\n");
        return 1;
    }
    defer migrations.unlock(arena, conn);
    const applied = try migrations.readApplied(arena, conn, err) orelse return 1;
    if (applied.len == 0) {
        try out.writeAll("Nothing to redo\n");
        return 0;
    }
    const versions = applied[applied.len - @min(options.step, applied.len) ..];

    // Newest first.
    const undos = try rollback.prepare(env, arena, project, conn.dialect, versions, err) orelse {
        try err.writeAll("ffmig: nothing was redone\n");
        return 1;
    };
    for (undos) |u| {
        if (!try rollback.undo(arena, conn, u, err)) return 1;
        try out.print("Rolled back {s}\n", .{u.parsed.path});
    }
    var i = undos.len;
    while (i > 0) {
        i -= 1;
        const p = &undos[i].parsed;
        if (!try migrations.apply(arena, conn, p.path, p.up(), p.insert(), p.migration.transaction, err)) return 1;
        try out.print("Migrated {s}\n", .{p.path});
    }
    if (!try dump.after(env, arena, project, conn, out, err)) return 1;
    return 0;
}
