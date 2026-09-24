const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;
const ffmig = @import("ffmig");
const init = ffmig.commands.init;
const run = init.run;
const usage = init.usage;
const config_file = ffmig.config.file_name;

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

fn runIn(dir: Io.Dir, args: []const []const u8) !Result {
    var r: Result = .{
        .code = undefined,
        .out = .init(testing.allocator),
        .err = .init(testing.allocator),
    };
    r.code = try run(.{ .io = testing.io, .cwd = dir, .gpa = testing.allocator }, args, &r.out.writer, &r.err.writer);
    return r;
}

fn expectConfig(dir: Io.Dir, expected: []const u8) !void {
    const actual = try dir.readFileAlloc(testing.io, config_file, testing.allocator, .unlimited);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

test "init with defaults" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var r = try runIn(tmp.dir, &.{});
    defer r.deinit();

    try testing.expectEqual(0, r.code);
    try testing.expectEqualStrings("Created ffmig.toml\nCreated migrations/\n", r.out.written());
    try testing.expectEqualStrings("", r.err.written());
    try expectConfig(tmp.dir,
        \\[migration]
        \\path = "migrations"
        \\# Fail a migration that waits longer than this for a lock, instead of
        \\# blocking every query queued behind it:
        \\# lock_timeout = "5s"
        \\
        \\[database]
        \\url = "${DATABASE_URL}"
        \\
    );
    try tmp.dir.access(testing.io, "migrations", .{});
}

test "init with --path and --url" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var r = try runIn(tmp.dir, &.{
        "--path", "db/migrations",
        "--url",  "postgres://user:password@localhost:5432/mydatabase",
    });
    defer r.deinit();

    try testing.expectEqual(0, r.code);
    try testing.expectEqualStrings("Created ffmig.toml\nCreated db/migrations/\n", r.out.written());
    try expectConfig(tmp.dir,
        \\[migration]
        \\path = "db/migrations"
        \\# Fail a migration that waits longer than this for a lock, instead of
        \\# blocking every query queued behind it:
        \\# lock_timeout = "5s"
        \\
        \\[database]
        \\url = "postgres://user:password@localhost:5432/mydatabase"
        \\
    );
    try tmp.dir.access(testing.io, "db/migrations", .{});
}

test "init accepts --flag=value" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var r = try runIn(tmp.dir, &.{"--path=db/migrations"});
    defer r.deinit();

    try testing.expectEqual(0, r.code);
    try tmp.dir.access(testing.io, "db/migrations", .{});
}

test "init escapes toml strings" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var r = try runIn(tmp.dir, &.{ "--url", "a\"b\\c" });
    defer r.deinit();

    try testing.expectEqual(0, r.code);
    try expectConfig(tmp.dir,
        \\[migration]
        \\path = "migrations"
        \\# Fail a migration that waits longer than this for a lock, instead of
        \\# blocking every query queued behind it:
        \\# lock_timeout = "5s"
        \\
        \\[database]
        \\url = "a\"b\\c"
        \\
    );
}

test "init keeps an existing migrations directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "migrations");

    var r = try runIn(tmp.dir, &.{});
    defer r.deinit();

    try testing.expectEqual(0, r.code);
    try testing.expectEqualStrings("Created ffmig.toml\n", r.out.written());
}

test "init refuses to overwrite ffmig.toml" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = config_file, .data = "keep me" });

    var r = try runIn(tmp.dir, &.{});
    defer r.deinit();

    try testing.expectEqual(1, r.code);
    try testing.expectEqualStrings("", r.out.written());
    try testing.expectEqualStrings("ffmig: ffmig.toml already exists\n", r.err.written());
    try expectConfig(tmp.dir, "keep me");
}

test "init rejects bad arguments" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    for ([_][]const []const u8{ &.{"--path"}, &.{"--bogus"}, &.{"--url="} }) |args| {
        var r = try runIn(tmp.dir, args);
        defer r.deinit();
        try testing.expectEqual(1, r.code);
        try testing.expectEqualStrings(usage, r.err.written());
    }
}
