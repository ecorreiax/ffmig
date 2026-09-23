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

fn expectExpand(s: []const u8, expected: []const u8) !void {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("DATABASE_URL", "postgres://localhost/app");
    try environ.put("USER", "me");
    var missing: []const u8 = "";
    const actual = try config.expandEnv(testing.allocator, s, &environ, &missing);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

test "expands ${VAR} from the environment" {
    try expectExpand("${DATABASE_URL}", "postgres://localhost/app");
    try expectExpand("postgres://${USER}@host/${USER}_db", "postgres://me@host/me_db");
    try expectExpand("postgres://localhost/a$b", "postgres://localhost/a$b");
    try expectExpand("", "");
}

test "expandEnv reports undefined variables and bad syntax" {
    const environ: std.process.Environ.Map = .init(testing.allocator);
    var missing: []const u8 = "";
    try testing.expectError(error.UndefinedVariable, config.expandEnv(testing.allocator, "x${NOPE}y", &environ, &missing));
    try testing.expectEqualStrings("NOPE", missing);
    try testing.expectError(error.InvalidSyntax, config.expandEnv(testing.allocator, "${NOPE", &environ, &missing));
    try testing.expectError(error.InvalidSyntax, config.expandEnv(testing.allocator, "${}", &environ, &missing));
}
