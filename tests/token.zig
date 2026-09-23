const std = @import("std");
const token = @import("ffmig").mig.token;
const LineCol = token.LineCol;
const lineCol = token.lineCol;

const testing = std.testing;

test lineCol {
    const source = "ab\ncd\n\nx";
    try testing.expectEqual(LineCol{ .line = 1, .col = 1 }, lineCol(source, 0));
    try testing.expectEqual(LineCol{ .line = 1, .col = 3 }, lineCol(source, 2));
    try testing.expectEqual(LineCol{ .line = 2, .col = 1 }, lineCol(source, 3));
    try testing.expectEqual(LineCol{ .line = 2, .col = 2 }, lineCol(source, 4));
    try testing.expectEqual(LineCol{ .line = 4, .col = 1 }, lineCol(source, 7));
    try testing.expectEqual(LineCol{ .line = 4, .col = 2 }, lineCol(source, 8));
}
