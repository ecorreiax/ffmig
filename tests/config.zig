const std = @import("std");
const config = @import("ffmig").config;
const Diagnostics = config.Diagnostics;
const default_path = config.default_path;
const parse = config.parse;

const testing = std.testing;

fn expectParse(source: []const u8, path: []const u8, url: ?[]const u8) !void {
    var diag: Diagnostics = .{};
    const c = try parse(testing.allocator, source, &diag);
    defer c.deinit(testing.allocator);
    try testing.expectEqualStrings(path, c.path);
    if (url) |u| try testing.expectEqualStrings(u, c.url.?) else try testing.expectEqual(null, c.url);
}

test "parses the init template" {
    try expectParse(
        \\[migration]
        \\path = "db/migrations"
        \\
        \\[database]
        \\url = "${DATABASE_URL}"
        \\
    , "db/migrations", "${DATABASE_URL}");
}

test "defaults path when missing" {
    try expectParse("[database]\nurl = 'x'\n", default_path, "x");
}

test "handles comments, escapes and literal strings" {
    try expectParse(
        \\# top comment
        \\[migration] # trailing
        \\path = 'C:\dir' # comment
        \\[database]
        \\url = "a\"b\\c"
    , "C:\\dir", "a\"b\\c");
}

test "ignores keys in other sections" {
    try expectParse("path = \"nope\"\n[other]\npath = \"nope\"\n", default_path, null);
}

test "reports the line of a syntax error" {
    var diag: Diagnostics = .{};
    try testing.expectError(error.InvalidSyntax, parse(testing.allocator, "[migration]\n\npath = \"unterminated\n", &diag));
    try testing.expectEqual(3, diag.line);
}
