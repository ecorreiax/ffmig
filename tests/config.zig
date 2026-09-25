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

test "reads the schema, empty meaning unset" {
    var diag: Diagnostics = .{};
    var c = try parse(testing.allocator, "[database]\nschema = \"billing\"\n", &diag);
    try testing.expectEqualStrings("billing", c.schema.?);
    c.deinit(testing.allocator);
    c = try parse(testing.allocator, "[database]\nschema = \"\"\n", &diag);
    try testing.expectEqual(null, c.schema);
    c.deinit(testing.allocator);
    c = try parse(testing.allocator, "[migration]\nschema = \"billing\"\n", &diag);
    defer c.deinit(testing.allocator);
    try testing.expectEqual(null, c.schema);
}

test "reads the timeouts in milliseconds" {
    var diag: Diagnostics = .{};
    var c = try parse(testing.allocator,
        \\[migration]
        \\# lock_timeout = "1h"
        \\lock_timeout = "5s"
        \\statement_timeout = '0' # no limit
        \\
    , &diag);
    try testing.expectEqual(5000, c.timeouts.lock.?);
    try testing.expectEqual(0, c.timeouts.statement.?);
    c.deinit(testing.allocator);

    // Unset by default, and only read from [migration].
    c = try parse(testing.allocator, "[database]\nlock_timeout = \"nope\"\n", &diag);
    defer c.deinit(testing.allocator);
    try testing.expectEqual(config.Timeouts{}, c.timeouts);
}

test "rejects a timeout that is not a duration" {
    var diag: Diagnostics = .{};
    try testing.expectError(error.InvalidTimeout, parse(testing.allocator, "[migration]\npath = \"db\"\nstatement_timeout = \"5\"\n", &diag));
    try testing.expectEqual(3, diag.line);
    try testing.expectEqualStrings("statement_timeout", diag.key);
    try testing.expectError(error.InvalidSyntax, parse(testing.allocator, "[migration]\nlock_timeout = 5s\n", &diag));
    try testing.expectEqual(2, diag.line);
}

test "parseDuration" {
    const cases = [_]struct { []const u8, ?u32 }{
        .{ "0", 0 },
        .{ "0s", 0 },
        .{ "250ms", 250 },
        .{ "5s", 5000 },
        .{ "2min", 120_000 },
        .{ "1h", 3_600_000 },
        .{ "596h", 2_145_600_000 },
        // Past 2^31 - 1 ms.
        .{ "597h", null },
        .{ "99999999999999999999h", null },
        // A unit is required, except for 0.
        .{ "5", null },
        .{ "", null },
        .{ "s", null },
        .{ "5 s", null },
        .{ "1.5s", null },
        .{ "-1s", null },
        .{ "5m", null },
        .{ "5S", null },
    };
    for (cases) |c| {
        errdefer std.debug.print("duration: \"{s}\"\n", .{c[0]});
        try testing.expectEqual(c[1], config.parseDuration(c[0]));
    }
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
