//! `ffmig check [--ast] [file...]`
//!
//! Parses and lowers `.mig` files and reports the first error in each, as
//! `<file>:<line>:<col>: <message>` followed by the source line and a
//! caret under the span. Without files, checks every `*.mig` in the
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

pub const usage = "Usage: ffmig check [--ast] [file...]\n";

/// Spans are `u32` offsets; real migrations are far smaller than this.
const max_source_size = 16 * 1024 * 1024;

pub fn run(env: Env, args: []const []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    var print_ast = false;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(env.gpa);
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--ast")) {
            print_ast = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            try err.writeAll(usage);
            return 1;
        } else {
            files.append(env.gpa, arg) catch return outOfMemory(err);
        }
    }

    if (files.items.len > 0) return checkFiles(env, env.cwd, "", files.items, print_ast, out, err);

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
    return checkFiles(env, dir, cfg.path, names, print_ast, out, err);
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
    print_ast: bool,
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
        const ok = try checkFile(env.io, dir, path, shown, arena_state.allocator(), print_ast, out, err);
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
    print_ast: bool,
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
            try report(err, shown, source, diag);
            return false;
        },
    };

    try out.print("ok {s}\n", .{shown});
    if (print_ast) try mig.print.migration(out, migration);
    return true;
}

/// `file:line:col: message`, then the source line and a caret under the
/// part of the span that is on that line.
fn report(err: *Writer, shown: []const u8, source: []const u8, diag: mig.Diagnostic) Writer.Error!void {
    const pos = mig.token.lineCol(source, diag.span.start);
    try err.print("{s}:{d}:{d}: {s}\n", .{ shown, pos.line, pos.col, diag.message });

    const start = @min(diag.span.start, source.len);
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..start], '\n')) |i| i + 1 else 0;
    const line_end = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
    const line = std.mem.trimEnd(u8, source[line_start..line_end], "\r");
    try err.print("{s}\n", .{line});

    // Keep tabs so the caret lines up with the source line.
    for (source[line_start..start]) |c| try err.writeByte(if (c == '\t') '\t' else ' ');
    try err.writeByte('^');
    const end = @min(diag.span.end, line_start + line.len);
    if (end > start + 1) try err.splatByteAll('~', end - start - 1);
    try err.writeByte('\n');
}

fn outOfMemory(err: *Writer) Writer.Error!u8 {
    try err.writeAll("ffmig: out of memory\n");
    return 1;
}

const testing = std.testing;

const Result = struct {
    code: u8,
    out: Writer.Allocating,
    err: Writer.Allocating,

    fn deinit(r: *Result) void {
        r.out.deinit();
        r.err.deinit();
    }
};

fn checkIn(dir: Io.Dir, args: []const []const u8) !Result {
    var r: Result = .{
        .code = undefined,
        .out = .init(testing.allocator),
        .err = .init(testing.allocator),
    };
    const env: Env = .{ .io = testing.io, .cwd = dir, .gpa = testing.allocator };
    r.code = try run(env, args, &r.out.writer, &r.err.writer);
    return r;
}

fn writeFile(dir: Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(testing.io, parent);
    try dir.writeFile(testing.io, .{ .sub_path = path, .data = data });
}

const empty_migration = "migration CreateUsers {\n  change {\n  }\n}\n";

test "check passes a migration generated by new" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, config.file_name, "[migration]\npath = \"db/migrations\"\n");

    var created: Writer.Allocating = .init(testing.allocator);
    defer created.deinit();
    var ignored: Writer.Allocating = .init(testing.allocator);
    defer ignored.deinit();
    const env: Env = .{ .io = testing.io, .cwd = tmp.dir, .gpa = testing.allocator };
    try testing.expectEqual(0, try @import("new.zig").run(env, &.{"CreateUsers"}, &created.writer, &ignored.writer));

    var r = try checkIn(tmp.dir, &.{});
    defer r.deinit();
    try testing.expectEqual(0, r.code);
    // "Created <path>\n" -> "ok <path>\n"
    const path = created.written()["Created ".len..];
    const expected = try std.mem.concat(testing.allocator, u8, &.{ "ok ", path });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, r.out.written());
    try testing.expectEqualStrings("", r.err.written());
}

test "check reports file:line:col, the source line and a caret" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.mig", "migration AddIndex {\n  change {\n\tadd_index :users, :email, uniq: true\n  }\n}\n");

    var r = try checkIn(tmp.dir, &.{"a.mig"});
    defer r.deinit();
    try testing.expectEqual(1, r.code);
    try testing.expectEqualStrings("", r.out.written());
    try testing.expectEqualStrings(
        "a.mig:3:28: unknown option 'uniq' for add_index\n" ++
            "\tadd_index :users, :email, uniq: true\n" ++
            "\t" ++ " " ** 26 ++ "^~~~~\n",
        r.err.written(),
    );
}

test "check reports a syntax error at end of file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.mig", "migration M {\n  change {\n");

    var r = try checkIn(tmp.dir, &.{"a.mig"});
    defer r.deinit();
    try testing.expectEqual(1, r.code);
    try testing.expectEqualStrings(
        \\a.mig:2:3: expected '}' to close 'change' block opened here
        \\  change {
        \\  ^~~~~~
        \\
    , r.err.written());
}

test "check keeps going and reports every broken file in order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, config.file_name, "[migration]\npath = \"migrations\"\n");
    try writeFile(tmp.dir, "migrations/20260102000000_b.mig", "migration B { change { add_idx :t, :c } }\n");
    try writeFile(tmp.dir, "migrations/20260101000000_a.mig", empty_migration);
    try writeFile(tmp.dir, "migrations/20260103000000_c.mig", "migration C { up { } }\n");
    try writeFile(tmp.dir, "migrations/20260104000000_d.mig", empty_migration);
    try writeFile(tmp.dir, "migrations/notes.txt", "not a migration");

    var r = try checkIn(tmp.dir, &.{});
    defer r.deinit();
    try testing.expectEqual(1, r.code);
    try testing.expectEqualStrings(
        \\ok migrations/20260101000000_a.mig
        \\ok migrations/20260104000000_d.mig
        \\
    , r.out.written());
    try testing.expectEqualStrings(
        \\migrations/20260102000000_b.mig:1:24: unknown operation 'add_idx'
        \\migration B { change { add_idx :t, :c } }
        \\                       ^~~~~~~
        \\migrations/20260103000000_c.mig:1:15: missing 'down' block
        \\migration C { up { } }
        \\              ^~
        \\
    , r.err.written());
}

test "check with files ignores the config and reports unreadable files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "x/a.mig", empty_migration);

    var r = try checkIn(tmp.dir, &.{ "x/a.mig", "missing.mig" });
    defer r.deinit();
    try testing.expectEqual(1, r.code);
    try testing.expectEqualStrings("ok x/a.mig\n", r.out.written());
    try testing.expectEqualStrings("ffmig: cannot read missing.mig: FileNotFound\n", r.err.written());
}

test "check --ast prints the lowered migration" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.mig",
        \\migration AddRole {
        \\  up {
        \\    add_column :users, :role, :integer, null: false, default: 0
        \\  }
        \\  down {
        \\    remove_column :users, :role
        \\  }
        \\}
        \\
    );

    var r = try checkIn(tmp.dir, &.{ "--ast", "a.mig" });
    defer r.deinit();
    try testing.expectEqual(0, r.code);
    try testing.expectEqualStrings(
        \\ok a.mig
        \\migration AddRole
        \\  up
        \\    add_column users
        \\      column role integer not_null default=0
        \\  down
        \\    remove_column users role
        \\
    , r.out.written());
}

test "check without files needs ffmig.toml" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var r = try checkIn(tmp.dir, &.{});
    defer r.deinit();
    try testing.expectEqual(1, r.code);
    try testing.expectEqualStrings("ffmig: ffmig.toml not found; run 'ffmig init' first\n", r.err.written());
}

test "check rejects unknown flags" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var r = try checkIn(tmp.dir, &.{"--nope"});
    defer r.deinit();
    try testing.expectEqual(1, r.code);
    try testing.expectEqualStrings(usage, r.err.written());
}
