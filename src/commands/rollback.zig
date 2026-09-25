//! `ffmig rollback [--step N | --to VERSION] [--dry-run] [--lock-wait SECONDS]`
//!
//! Undoes the last N applied migrations (default 1), or with `--to` every
//! one newer than that version, newest first, using each one's down plan:
//! derived for `change`, as written for `up` / `down`. Every file is
//! parsed and its down plan derived before anything runs, so an
//! irreversible `change` stops the rollback untouched. Each migration
//! runs in its own transaction together with the delete of its version,
//! unless it has `transaction: false`. The timeouts, the migration lock
//! and `--dry-run` work as for `migrate`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Env = @import("root.zig").Env;
const check = @import("check.zig");
const migrations = @import("migrations.zig");
const flags = @import("flags.zig");
const mig = @import("../mig/root.zig");
const sql = @import("../sql/root.zig");

pub const usage =
    \\Usage:
    \\
    \\      ffmig rollback [flags]
    \\
    \\Undo the last applied migration.
    \\
    \\Flags:
    \\      --step <n>            Undo the last n instead
    \\      --to <version>        Undo every migration newer than this one, which
    \\                            stays applied
    \\      --dry-run             Print the SQL that would run, and run nothing
    \\      --lock-wait <s>       Wait up to s seconds for another migrate or
    \\                            rollback to finish (default: 60; 0: do not wait)
    \\
++ flags.config_option ++ flags.url_option ++ flags.help_option;

pub const Options = struct {
    /// How many of the newest applied migrations to undo.
    step: usize = 1,
    /// Undo every applied migration newer than this version instead of
    /// `step` of them.
    to: ?[]const u8 = null,
    /// Print what would run instead of running it.
    dry_run: bool = false,
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
    var step = false;
    var it: flags.Iterator = .{ .args = args };
    while (it.next()) |arg| switch (arg) {
        .flag => |f| if (f.is("--step")) {
            options.step = parseStep(it.value(f) orelse return null) orelse return null;
            step = true;
        } else if (f.is("--to")) {
            options.to = it.value(f) orelse return null;
        } else if (f.isSwitch("--dry-run")) {
            options.dry_run = true;
        } else if (f.is("--lock-wait")) {
            options.lock_wait = migrations.parseLockWait(it.value(f) orelse return null) orelse return null;
        } else return null,
        .positional => return null,
    };
    // One or the other says how far to go.
    if (step and options.to != null) return null;
    return options;
}

/// Parses a `--step` value: a whole number from 1.
pub fn parseStep(arg: []const u8) ?usize {
    const step = std.fmt.parseInt(usize, arg, 10) catch return null;
    return if (step == 0) null else step;
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
    if (!options.dry_run and
        (!try migrations.setTimeouts(arena, conn, project.timeouts, err) or
            !try migrations.lock(env.io, arena, conn, options.lock_wait, err)))
    {
        try err.writeAll("ffmig: nothing was rolled back\n");
        return 1;
    }
    defer if (!options.dry_run) migrations.unlock(arena, conn);
    const applied = try migrations.readApplied(arena, conn, err) orelse return 1;
    const versions = if (options.to) |version| newer: {
        for (applied, 0..) |a, i| {
            if (std.mem.eql(u8, a.version, version)) break :newer applied[i + 1 ..];
        }
        try err.print("ffmig: {s} is not an applied migration\n", .{version});
        try err.writeAll("ffmig: nothing was rolled back\n");
        return 1;
    } else applied[applied.len - @min(options.step, applied.len) ..];
    if (versions.len == 0) {
        try out.writeAll(if (options.dry_run) "-- Nothing to roll back\n" else "Nothing to roll back\n");
        return 0;
    }

    const undos = try prepare(env, arena, project, conn.dialect, versions, err) orelse {
        try err.writeAll("ffmig: nothing was rolled back\n");
        return 1;
    };
    for (undos, 0..) |u, i| {
        if (options.dry_run) {
            if (i > 0) try out.writeByte('\n');
            if (!try migrations.show(arena, conn.dialect, u.parsed.path, u.down, u.delete(), u.parsed.migration.transaction, out, err)) return 1;
            continue;
        }
        if (!try undo(arena, conn, u, err)) return 1;
        try out.print("Rolled back {s}\n", .{u.parsed.path});
    }
    return 0;
}

/// An applied migration and the operations that undo it.
pub const Undo = struct {
    parsed: migrations.Parsed,
    down: []const mig.ast.Operation,

    /// The tracking statement that records it as no longer applied.
    pub fn delete(u: Undo) sql.Tracking {
        return .{ .delete = u.parsed.file.version };
    }
};

/// Parses the files of the applied `versions` (in version order) and
/// derives their down plans, returned newest first. Reports every file
/// that is missing, broken or irreversible, and then returns null, so
/// nothing runs unless all of them can.
pub fn prepare(
    env: Env,
    arena: Allocator,
    project: migrations.Project,
    dialect: sql.Dialect,
    versions: []const migrations.Applied,
    err: *Writer,
) Writer.Error!?[]const Undo {
    const undos = arena.alloc(Undo, versions.len) catch {
        try migrations.outOfMemory(err);
        return null;
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
        const p = try project.parse(env.io, arena, file, dialect, err) orelse {
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
    return if (ok) undos else null;
}

/// Runs `u`'s down plan together with the delete of its version.
pub fn undo(arena: Allocator, conn: migrations.Connection, u: Undo, err: *Writer) Writer.Error!bool {
    return migrations.apply(arena, conn, u.parsed.path, u.down, u.delete(), u.parsed.migration.transaction, err);
}
