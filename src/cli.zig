//! Command-line dispatch. Takes already-split arguments and writers so it
//! stays independent of the process and is easy to test.

const std = @import("std");
const Writer = std.Io.Writer;

pub const Command = enum {
    greet,
    help,
};

const usage =
    \\Usage: ffmig <command> [args]
    \\
    \\Commands:
    \\  greet <name>   Say hello
    \\  help           Show this message
    \\
;

pub fn run(args: []const []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    if (args.len == 0) {
        try err.writeAll(usage);
        return 1;
    }

    const command = std.meta.stringToEnum(Command, args[0]) orelse {
        try err.print("ffmig: unknown command '{s}'\n\n", .{args[0]});
        try err.writeAll(usage);
        return 1;
    };

    return switch (command) {
        .greet => greet(args[1..], out, err),
        .help => {
            try out.writeAll(usage);
            return 0;
        },
    };
}

fn greet(args: []const []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    if (args.len != 1) {
        try err.writeAll("Usage: ffmig greet <name>\n");
        return 1;
    }
    try out.print("Hello, {s}!\n", .{args[0]});
    return 0;
}

const testing = std.testing;

fn expectRun(args: []const []const u8, code: u8, stdout: []const u8, stderr: []const u8) !void {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: Writer.Allocating = .init(testing.allocator);
    defer err.deinit();

    try testing.expectEqual(code, try run(args, &out.writer, &err.writer));
    try testing.expectEqualStrings(stdout, out.written());
    try testing.expectEqualStrings(stderr, err.written());
}

test "greet prints a greeting" {
    try expectRun(&.{ "greet", "Ana" }, 0, "Hello, Ana!\n", "");
}

test "greet without a name fails" {
    try expectRun(&.{"greet"}, 1, "", "Usage: ffmig greet <name>\n");
}

test "unknown command fails" {
    try expectRun(&.{"nope"}, 1, "", "ffmig: unknown command 'nope'\n\n" ++ usage);
}

test "no command prints usage" {
    try expectRun(&.{}, 1, "", usage);
}
