const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;
const ffmig = @import("ffmig");
const config = ffmig.config;
const Env = ffmig.commands.Env;
const new = ffmig.commands.new;
const generate = new.generate;
const usage = new.usage;

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
