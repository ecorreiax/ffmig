//! `ffmig new <name>`
//!
//! Creates `<timestamp>_<snake_name>.mig` in the configured migrations
//! directory. The timestamp is the current UTC time as YYYYMMDDHHMMSS.

const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;
const Env = @import("root.zig").Env;
const config = @import("../utils/config.zig");
const fs = @import("../utils/fs.zig");

pub const usage = "Usage: ffmig new <name>\n";

pub fn run(env: Env, args: []const []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    return generate(env, args, fs.now(env.io), out, err);
}

/// `run` with the clock injected so tests get stable file names.
fn generate(env: Env, args: []const []const u8, now: u64, out: *Writer, err: *Writer) Writer.Error!u8 {
    if (args.len != 1) {
        try err.writeAll(usage);
        return 1;
    }
    const name = args[0];
    if (!fs.isValidName(name)) {
        try err.print(
            "ffmig: invalid migration name '{s}'; use letters, digits and underscores, not starting with a digit\n",
            .{name},
        );
        return 1;
    }

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

    const file_name = fs.migrationFileName(env.gpa, now, name) catch {
        try err.writeAll("ffmig: out of memory\n");
        return 1;
    };
    defer env.gpa.free(file_name);

    var content_buf: [512]u8 = undefined;
    const content = writeTemplate(&content_buf, fs.migrationName(file_name)) catch {
        try err.print("ffmig: migration name '{s}' is too long\n", .{name});
        return 1;
    };

    env.cwd.createDirPath(env.io, cfg.path) catch |e| {
        try err.print("ffmig: cannot create directory {s}: {t}\n", .{ cfg.path, e });
        return 1;
    };
    var dir = env.cwd.openDir(env.io, cfg.path, .{}) catch |e| {
        try err.print("ffmig: cannot open directory {s}: {t}\n", .{ cfg.path, e });
        return 1;
    };
    defer dir.close(env.io);

    dir.writeFile(env.io, .{
        .sub_path = file_name,
        .data = content,
        .flags = .{ .exclusive = true },
    }) catch |e| {
        try err.print("ffmig: cannot create {s}/{s}: {t}\n", .{ cfg.path, file_name, e });
        return 1;
    };

    try out.print("Created {s}/{s}\n", .{ cfg.path, file_name });
    return 0;
}

/// The body of a new migration, named after its snake_case file name.
fn writeTemplate(buf: []u8, snake: []const u8) Writer.Error![]const u8 {
    var w: Writer = .fixed(buf);
    try w.writeAll("migration ");
    try fs.writePascalCase(&w, snake);
    try w.writeAll(" {\n  change {\n  }\n}\n");
    return w.buffered();
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

fn generateIn(dir: Io.Dir, args: []const []const u8) !Result {
    var r: Result = .{
        .code = undefined,
        .out = .init(testing.allocator),
        .err = .init(testing.allocator),
    };
    const env: Env = .{ .io = testing.io, .cwd = dir, .gpa = testing.allocator };
    r.code = try generate(env, args, 1790172312, &r.out.writer, &r.err.writer);
    return r;
}

fn writeConfig(dir: Io.Dir, path: []const u8) !void {
    var buf: [256]u8 = undefined;
    const data = try std.fmt.bufPrint(&buf, "[migration]\npath = \"{s}\"\n", .{path});
    try dir.writeFile(testing.io, .{ .sub_path = config.file_name, .data = data });
}

test "new creates a migration in the configured directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeConfig(tmp.dir, "db/migrations");

    var r = try generateIn(tmp.dir, &.{"CreateUsers2"});
    defer r.deinit();

    try testing.expectEqual(0, r.code);
    try testing.expectEqualStrings("Created db/migrations/20260923140512_create_users_2.mig\n", r.out.written());
    try testing.expectEqualStrings("", r.err.written());

    const content = try tmp.dir.readFileAlloc(
        testing.io,
        "db/migrations/20260923140512_create_users_2.mig",
        testing.allocator,
        .unlimited,
    );
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("migration CreateUsers2 {\n  change {\n  }\n}\n", content);
}

test "new names the migration in pascal case" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeConfig(tmp.dir, "migrations");

    var r = try generateIn(tmp.dir, &.{"Add_email_to_Users"});
    defer r.deinit();
    try testing.expectEqual(0, r.code);

    const content = try tmp.dir.readFileAlloc(
        testing.io,
        "migrations/20260923140512_add_email_to_users.mig",
        testing.allocator,
        .unlimited,
    );
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("migration AddEmailToUsers {\n  change {\n  }\n}\n", content);
}

test "new rejects invalid names" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeConfig(tmp.dir, "migrations");

    var r = try generateIn(tmp.dir, &.{"create-users"});
    defer r.deinit();

    try testing.expectEqual(1, r.code);
    try testing.expectEqualStrings("", r.out.written());
    try testing.expectEqualStrings(
        "ffmig: invalid migration name 'create-users'; use letters, digits and underscores, not starting with a digit\n",
        r.err.written(),
    );
}

test "new requires exactly one name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    for ([_][]const []const u8{ &.{}, &.{ "a", "b" } }) |args| {
        var r = try generateIn(tmp.dir, args);
        defer r.deinit();
        try testing.expectEqual(1, r.code);
        try testing.expectEqualStrings(usage, r.err.written());
    }
}

test "new needs ffmig.toml" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var r = try generateIn(tmp.dir, &.{"create_users"});
    defer r.deinit();

    try testing.expectEqual(1, r.code);
    try testing.expectEqualStrings("ffmig: ffmig.toml not found; run 'ffmig init' first\n", r.err.written());
}

test "new does not overwrite an existing migration" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeConfig(tmp.dir, "migrations");

    var first = try generateIn(tmp.dir, &.{"create_users"});
    defer first.deinit();
    try testing.expectEqual(0, first.code);

    var second = try generateIn(tmp.dir, &.{"CreateUsers"});
    defer second.deinit();
    try testing.expectEqual(1, second.code);
    try testing.expectEqualStrings(
        "ffmig: cannot create migrations/20260923140512_create_users.mig: PathAlreadyExists\n",
        second.err.written(),
    );
}
