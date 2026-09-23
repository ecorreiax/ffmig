//! Command-line router. Takes already-split arguments and writers so it
//! stays independent of the process and is easy to test.

const std = @import("std");
const Writer = std.Io.Writer;
const commands = @import("commands/root.zig");

const usage =
    \\Usage: ffmig <command> [args]
    \\
    \\Commands:
    \\  init           Create ffmig.toml and the migrations directory
    \\                   --path <dir>  Migrations directory (default: migrations)
    \\                   --url <url>   Database URL (default: ${DATABASE_URL})
    \\  new <name>     Create a timestamped migration file, e.g. new create_users
    \\  check [files]  Check .mig files (default: all in the migrations directory)
    \\                   --ast         Print the parsed migration
    \\  help           Show this message
    \\
;

pub fn run(env: commands.Env, args: []const []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    if (args.len == 0) {
        try err.writeAll(usage);
        return 1;
    }

    const command = std.meta.stringToEnum(commands.Command, args[0]) orelse {
        try err.print("ffmig: unknown command '{s}'\n\n", .{args[0]});
        try err.writeAll(usage);
        return 1;
    };

    return switch (command) {
        .help => {
            try out.writeAll(usage);
            return 0;
        },
        else => commands.run(env, command, args[1..], out, err),
    };
}

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

test {
    testing.refAllDecls(@This());
    _ = commands;
}
