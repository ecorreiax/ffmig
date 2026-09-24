//! `ffmig rollback [--step N] [--lock-wait SECONDS]`
//!
//! Undoes the last N applied migrations (default 1), newest first, using
//! each one's down plan: derived for `change`, as written for `up` /
//! `down`. Every file is parsed and its down plan derived before anything
//! runs, so an irreversible `change` stops the rollback untouched. Each
//! migration runs in its own transaction together with the delete of its
//! version, unless it has `transaction: false`. The timeouts and the
//! migration lock work as for `migrate`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Env = @import("root.zig").Env;
const check = @import("check.zig");
const migrations = @import("migrations.zig");
const flags = @import("flags.zig");
const mig = @import("../mig/root.zig");

pub const usage =
    \\Usage: ffmig rollback [flags]
    \\
    \\Undo the last applied migration.
    \\
    \\Flags:
    \\  --step <n>       Undo the last n instead
    \\  --lock-wait <s>  Wait up to s seconds for another migrate or
    \\                   rollback to finish (default: 60; 0: do not wait)
    \\
++ flags.config_option ++ flags.url_option ++ flags.help_option;

pub const Options = struct {
    /// How many of the newest applied migrations to undo.
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
    const conn = try migrations.connect(env, arena, project.url, err) orelse return 1;
    defer conn.db.close();
    return rollback(env, arena, project, conn, options, out, err);
}

/// The options, or null for invalid arguments.
fn parseArgs(args: []const []const u8) ?Options {
    var options: Options = .{};
    var it: flags.Iterator = .{ .args = args };
    while (it.next()) |arg| switch (arg) {
        .flag => |f| if (f.is("--step")) {
            options.step = std.fmt.parseInt(usize, it.value(f) orelse return null, 10) catch return null;
            if (options.step == 0) return null;
        } else if (f.is("--lock-wait")) {
            options.lock_wait = migrations.parseLockWait(it.value(f) orelse return null) orelse return null;
        } else return null,
        .positional => return null,
    };
    return options;
}

/// `run` after connecting, split out so tests can pass a fake database.
pub fn rollback(
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
        try err.writeAll("ffmig: nothing was rolled back\n");
        return 1;
    }
    defer migrations.unlock(arena, conn);
    const applied = try migrations.readApplied(arena, conn, err) orelse return 1;
    if (applied.len == 0) {
        try out.writeAll("Nothing to roll back\n");
        return 0;
    }
    const versions = applied[applied.len - @min(options.step, applied.len) ..];

    const Undo = struct { parsed: migrations.Parsed, down: []const mig.ast.Operation };
    const undos = arena.alloc(Undo, versions.len) catch {
        try migrations.outOfMemory(err);
        return 1;
    };
    var ok = true;
    // Newest first.
    for (undos, 0..) |*u, i| {
        const version = versions[versions.len - 1 - i].version;
        const file = project.find(version) orelse {
            try err.print("ffmig: no file in {s} for applied migration {s}\n", .{ project.path, version });
            ok = false;
            continue;
        };
        const p = try project.parse(env.io, arena, file, conn.dialect, err) orelse {
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
        if (!try migrations.apply(arena, conn, u.parsed.path, u.down, .{ .delete = u.parsed.file.version }, u.parsed.migration.transaction, err)) return 1;
        try out.print("Rolled back {s}\n", .{u.parsed.path});
    }
    return 0;
}
