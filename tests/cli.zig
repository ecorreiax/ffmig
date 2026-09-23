const std = @import("std");
const Writer = std.Io.Writer;
const ffmig = @import("ffmig");
const commands = ffmig.commands;
const run = ffmig.cli.run;
const usage = ffmig.cli.usage;

const testing = std.testing;

fn expectRun(args: []const []const u8, code: u8, stdout: []const u8, stderr: []const u8) !void {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: Writer.Allocating = .init(testing.allocator);
    defer err.deinit();

    try testing.expectEqual(code, try run(.{ .io = testing.io, .cwd = std.Io.Dir.cwd(), .gpa = testing.allocator }, args, &out.writer, &err.writer));
    try testing.expectEqualStrings(stdout, out.written());
    try testing.expectEqualStrings(stderr, err.written());
}

test "dispatches to init" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: Writer.Allocating = .init(testing.allocator);
    defer err.deinit();

    const env: commands.Env = .{ .io = testing.io, .cwd = tmp.dir, .gpa = testing.allocator };
    try testing.expectEqual(0, try run(env, &.{"init"}, &out.writer, &err.writer));
    try testing.expectEqualStrings("Created ffmig.toml\nCreated migrations/\n", out.written());
    try testing.expectEqualStrings("", err.written());
}

test "help prints usage" {
    try expectRun(&.{"help"}, 0, usage, "");
}

test "unknown command fails" {
    try expectRun(&.{"nope"}, 1, "", "ffmig: unknown command 'nope'\n\n" ++ usage);
}

test "no command prints usage" {
    try expectRun(&.{}, 1, "", usage);
}
