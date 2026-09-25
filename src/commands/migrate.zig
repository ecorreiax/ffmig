//! `ffmig migrate [--to VERSION] [--dry-run] [--fake] [--lock-wait SECONDS] [--strict]`
//!
//! Runs, in version order, every migration whose version is not recorded
//! in `schema_migrations`, or with `--to` those up to that version. Every
//! pending file is parsed and checked before anything runs, so a broken
//! file never leaves half a batch applied. Each migration runs in its own
//! transaction together with the insert of its version and checksum,
//! unless it has `transaction: false`; a failure stops the batch and
//! keeps what already ran. The `[migration]` timeouts in `ffmig.toml` are
//! set first. The whole run holds the migration lock, so a concurrent
//! `migrate` or `rollback` on the same database waits for it (up to
//! `--lock-wait` seconds) and then sees what this one applied.
//!
//! An applied file whose checksum no longer matches gets a warning, or,
//! with `--strict`, stops the run before anything is applied. A pending
//! file older than the newest applied version gets a note and still runs.
//!
//! `--fake` records the pending versions without running their
//! statements, to adopt a database that already has their schema.
//! `--dry-run` prints, as a script, the statements that the run would
//! send, and sends none of them; like `status`, it takes no lock and
//! sets no timeouts.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Env = @import("root.zig").Env;
const migrations = @import("migrations.zig");
const flags = @import("flags.zig");
const dump = @import("dump.zig");
const mig = @import("../mig/root.zig");

pub const usage =
    \\Usage:
    \\
    \\      ffmig migrate [flags]
    \\
    \\Apply every pending migration, oldest first.
    \\
    \\Flags:
    \\      --to <version>        Stop after the migration with this version
    \\      --dry-run             Print the SQL that would run, and run nothing
    \\      --fake                Record the migrations as applied without running
    \\                            them, to adopt a database that already has them
    \\      --lock-wait <s>       Wait up to s seconds for another migrate or
    \\                            rollback to finish (default: 60; 0: do not wait)
    \\      --strict              Refuse to run if an applied file has changed
    \\                            since it ran
    \\
++ flags.config_option ++ flags.url_option ++ flags.help_option;

pub const Options = struct {
    /// Seconds to wait for another run to release the migration lock.
    lock_wait: u32 = migrations.default_lock_wait,
    /// Refuse to run when an applied file has changed, instead of warning.
    strict: bool = false,
    /// The version of the last migration to apply; null for all of them.
    to: ?[]const u8 = null,
    /// Print what would run instead of running it.
    dry_run: bool = false,
    /// Record the migrations without running their statements.
    fake: bool = false,
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
    return migrate(env, arena, project, conn, options, out, err);
}

/// The options, or null for invalid arguments.
fn parseArgs(args: []const []const u8) ?Options {
    var options: Options = .{};
    var it: flags.Iterator = .{ .args = args };
    while (it.next()) |arg| switch (arg) {
        .flag => |f| if (f.isSwitch("--strict")) {
            options.strict = true;
        } else if (f.isSwitch("--dry-run")) {
            options.dry_run = true;
        } else if (f.isSwitch("--fake")) {
            options.fake = true;
        } else if (f.is("--to")) {
            options.to = it.value(f) orelse return null;
        } else if (f.is("--lock-wait")) {
            options.lock_wait = migrations.parseLockWait(it.value(f) orelse return null) orelse return null;
        } else return null,
        .positional => return null,
    };
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
    if (options.to) |version| if (project.find(version) == null) {
        try err.print("ffmig: no migration in {s} has version {s}\n", .{ project.path, version });
        try err.writeAll("ffmig: nothing was migrated\n");
        return 1;
    };
    if (!options.dry_run and
        (!try migrations.setTimeouts(arena, conn, project.timeouts, err) or
            !try migrations.lock(env.io, arena, conn, options.lock_wait, err)))
    {
        try err.writeAll("ffmig: nothing was migrated\n");
        return 1;
    }
    defer if (!options.dry_run) migrations.unlock(arena, conn);
    const applied = try migrations.readApplied(arena, conn, err) orelse return 1;
    if (!try checkApplied(env, arena, project, applied, options.strict, err)) {
        try err.writeAll("ffmig: nothing was migrated\n");
        return 1;
    }
    const all = migrations.pending(arena, project.files, applied) catch {
        try migrations.outOfMemory(err);
        return 1;
    };
    // Pending files are in version order, so those up to `to` come first.
    var count = all.len;
    if (options.to) |version| {
        count = 0;
        while (count < all.len and std.mem.order(u8, all[count].version, version) != .gt) count += 1;
    }
    const files = all[0..count];
    if (files.len == 0) {
        try out.writeAll(if (options.dry_run) "-- Nothing to migrate\n" else "Nothing to migrate\n");
        return 0;
    }

    const parsed = arena.alloc(migrations.Parsed, files.len) catch {
        try migrations.outOfMemory(err);
        return 1;
    };
    var ok = true;
    for (files, parsed) |f, *p| {
        if (try project.parse(env.io, arena, f, conn.dialect, err)) |m| p.* = m else ok = false;
    }
    if (!ok) {
        try err.writeAll("ffmig: nothing was migrated\n");
        return 1;
    }

    const newest = if (applied.len == 0) "" else applied[applied.len - 1].version;
    for (parsed, 0..) |*p, i| {
        if (std.mem.order(u8, p.file.version, newest) == .lt) {
            try err.print("ffmig: note: {s} is older than the last applied migration {s}\n", .{ p.path, newest });
        }
        // Faking sends the tracking insert alone.
        const ops: []const mig.ast.Operation = if (options.fake) &.{} else p.up();
        const transaction = !options.fake and p.migration.transaction;
        if (options.dry_run) {
            if (i > 0) try out.writeByte('\n');
            if (!try migrations.show(arena, conn.dialect, p.path, ops, p.insert(), transaction, out, err)) return 1;
            continue;
        }
        if (!try migrations.apply(arena, conn, p.path, ops, p.insert(), transaction, err)) return 1;
        try out.print("{s} {s}\n", .{ if (options.fake) "Recorded (not run)" else "Migrated", p.path });
    }
    if (!options.dry_run and !try dump.after(env, arena, project, conn, out, err)) return 1;
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
