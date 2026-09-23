//! `ffmig greet <name>`

const std = @import("std");
const Writer = std.Io.Writer;

pub const usage = "Usage: ffmig greet <name>\n";

pub fn run(args: []const []const u8, out: *Writer, err: *Writer) Writer.Error!u8 {
    if (args.len != 1) {
        try err.writeAll(usage);
        return 1;
    }
    try out.print("Hello, {s}!\n", .{args[0]});
    return 0;
}

const testing = std.testing;

test "greet prints a greeting" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: Writer.Allocating = .init(testing.allocator);
    defer err.deinit();

    try testing.expectEqual(0, try run(&.{"Ana"}, &out.writer, &err.writer));
    try testing.expectEqualStrings("Hello, Ana!\n", out.written());
    try testing.expectEqualStrings("", err.written());
}

test "greet without a name fails" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: Writer.Allocating = .init(testing.allocator);
    defer err.deinit();

    try testing.expectEqual(1, try run(&.{}, &out.writer, &err.writer));
    try testing.expectEqualStrings("", out.written());
    try testing.expectEqualStrings(usage, err.written());
}
