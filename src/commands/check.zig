//! `ffmig check [--ast] [--down] [file...]`
//!
//! Parses and lowers `.mig` files and reports the first error in each, as
//! `<file>:<line>:<col>: <message>` followed by the source line and a
//! caret under the span. A `change` operation that cannot be undone is
//! reported the same way as a warning; the file still passes. Without files, checks every `*.mig` in the
//! configured migrations directory in file-name (timestamp) order. Keeps
//! going after a broken file so one run reports all of them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const Env = @import("root.zig").Env;
const config = @import("../utils/config.zig");
const fs = @import("../utils/fs.zig");
const mig = @import("../mig/root.zig");

pub const usage = "Usage: ffmig check [--ast] [--down] [file...]\n";

const Options = struct {
    /// Print the lowered AST.
    ast: bool = false,
    /// Print the AST as `up` / `down` sections, deriving `down` for
    /// `change`. Implies `ast`.
    down: bool = false,
};

/// Spans are `u32` offsets; real migrations are far smaller than this.
pub const max_source_size = 16 * 1024 * 1024;

pub fn run(env: Env, args: []const []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    var opts: Options = .{};
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(env.gpa);
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--ast")) {
            opts.ast = true;
        } else if (std.mem.eql(u8, arg, "--down")) {
            opts.down = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            try err.writeAll(usage);
            return 1;
        } else {
            files.append(env.gpa, arg) catch return outOfMemory(err);
        }
    }

    if (files.items.len > 0) return checkFiles(env, env.cwd, "", files.items, opts, out, err);

    var diag: config.Diagnostics = .{};
    const cfg = config.load(env.io, env.cwd, env.gpa, &diag) catch |e| {
        switch (e) {
            error.FileNotFound => try err.print("ffmig: {s} not found; run 'ffmig init' first\n", .{config.file_name}),
            error.InvalidSyntax => try err.print("ffmig: {s}:{d}: invalid syntax\n", .{ config.file_name, diag.line }),
            else => try err.print("ffmig: cannot read {s}: {t}\n", .{ config.file_name, e }),
        }
        return 1;
    };
    defer cfg.deinit(env.gpa);

    var dir = env.cwd.openDir(env.io, cfg.path, .{ .iterate = true }) catch |e| {
        try err.print("ffmig: cannot open directory {s}: {t}\n", .{ cfg.path, e });
        return 1;
    };
    defer dir.close(env.io);

    var arena_state: std.heap.ArenaAllocator = .init(env.gpa);
    defer arena_state.deinit();
    const names = listMigrations(env.io, dir, arena_state.allocator()) catch |e| switch (e) {
        error.OutOfMemory => return outOfMemory(err),
        else => {
            try err.print("ffmig: cannot read directory {s}: {t}\n", .{ cfg.path, e });
            return 1;
        },
    };
    return checkFiles(env, dir, cfg.path, names, opts, out, err);
}

/// Names of the `*.mig` files in `dir`, sorted.
fn listMigrations(io: Io, dir: Io.Dir, arena: Allocator) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, fs.migration_extension)) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sortUnstable([]const u8, names.items, {}, lessThan);
    return names.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Checks `paths` relative to `dir`, reporting them prefixed with `prefix/`
/// when `prefix` is not empty. Returns 1 if any file failed.
fn checkFiles(
    env: Env,
    dir: Io.Dir,
    prefix: []const u8,
    paths: []const []const u8,
    opts: Options,
    out: *Writer,
    err: *Writer,
) Writer.Error!u8 {
    var arena_state: std.heap.ArenaAllocator = .init(env.gpa);
    defer arena_state.deinit();

    var status: u8 = 0;
    for (paths) |path| {
        _ = arena_state.reset(.retain_capacity);
        const shown = if (prefix.len == 0) path else std.fs.path.join(arena_state.allocator(), &.{ prefix, path }) catch
            return outOfMemory(err);
        const ok = try checkFile(env.io, dir, path, shown, arena_state.allocator(), opts, out, err);
        if (!ok) status = 1;
    }
    return status;
}

fn checkFile(
    io: Io,
    dir: Io.Dir,
    path: []const u8,
    shown: []const u8,
    arena: Allocator,
    opts: Options,
    out: *Writer,
    err: *Writer,
) Writer.Error!bool {
    const source = dir.readFileAlloc(io, path, arena, .limited(max_source_size)) catch |e| {
        try err.print("ffmig: cannot read {s}: {t}\n", .{ shown, e });
        return false;
    };

    var diag: mig.Diagnostic = .{};
    const migration = mig.parseMigration(arena, source, &diag) catch |e| switch (e) {
        error.OutOfMemory => {
            try err.print("ffmig: out of memory checking {s}\n", .{shown});
            return false;
        },
        error.InvalidSyntax, error.InvalidMigration => {
            try report(err, shown, source, diag.span, "{s}", .{diag.message});
            return false;
        },
    };

    try out.print("ok {s}\n", .{shown});
    const plan: ?mig.reverse.Plan = mig.reverse.plan(arena, migration, &diag) catch |e| switch (e) {
        error.OutOfMemory => {
            try err.print("ffmig: out of memory checking {s}\n", .{shown});
            return false;
        },
        error.Irreversible => blk: {
            try report(err, shown, source, diag.span, "warning: {s}; use 'up' / 'down' blocks to make it reversible", .{diag.message});
            break :blk null;
        },
    };
    if (opts.down and plan != null) {
        try mig.print.plan(out, migration.name, plan.?);
    } else if (opts.ast or opts.down) {
        try mig.print.migration(out, migration);
    }
    return true;
}

/// `file:line:col: message`, then the source line and a caret under the
/// part of the span that is on that line.
pub fn report(
    err: *Writer,
    shown: []const u8,
    source: []const u8,
    span: mig.token.Span,
    comptime fmt: []const u8,
    args: anytype,
) Writer.Error!void {
    const pos = mig.token.lineCol(source, span.start);
    try err.print("{s}:{d}:{d}: " ++ fmt ++ "\n", .{ shown, pos.line, pos.col } ++ args);

    const start = @min(span.start, source.len);
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..start], '\n')) |i| i + 1 else 0;
    const line_end = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
    const line = std.mem.trimEnd(u8, source[line_start..line_end], "\r");
    try err.print("{s}\n", .{line});

    // Keep tabs so the caret lines up with the source line.
    for (source[line_start..start]) |c| try err.writeByte(if (c == '\t') '\t' else ' ');
    try err.writeByte('^');
    const end = @min(span.end, line_start + line.len);
    if (end > start + 1) try err.splatByteAll('~', end - start - 1);
    try err.writeByte('\n');
}

fn outOfMemory(err: *Writer) Writer.Error!u8 {
    try err.writeAll("ffmig: out of memory\n");
    return 1;
}
