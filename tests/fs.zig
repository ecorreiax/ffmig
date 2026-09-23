const std = @import("std");
const Writer = std.Io.Writer;
const fs = @import("ffmig").fs;
const timestamp_len = fs.timestamp_len;
const isValidName = fs.isValidName;
const migrationFileName = fs.migrationFileName;
const migrationName = fs.migrationName;
const writeTimestamp = fs.writeTimestamp;
const writeSnakeCase = fs.writeSnakeCase;
const writePascalCase = fs.writePascalCase;

const testing = std.testing;

// 2026-09-23 14:05:12 UTC
const fixed_time = 1790172312;

fn expectFileName(name: []const u8, expected: []const u8) !void {
    const actual = try migrationFileName(testing.allocator, fixed_time, name);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

test "migration file names are timestamped snake case" {
    try expectFileName("create_users", "20260923140512_create_users.mig");
    try expectFileName("CreateUsers", "20260923140512_create_users.mig");
    try expectFileName("CreateUsers2", "20260923140512_create_users_2.mig");
    try expectFileName("create_users2", "20260923140512_create_users_2.mig");
    try expectFileName("createUsers", "20260923140512_create_users.mig");
    try expectFileName("AddHTTPRequestLog", "20260923140512_add_http_request_log.mig");
    try expectFileName("add_Index", "20260923140512_add_index.mig");
}

test "migration name round-trips from a file name" {
    const file_name = try migrationFileName(testing.allocator, fixed_time, "CreateUsers2");
    defer testing.allocator.free(file_name);
    try testing.expectEqualStrings("create_users_2", migrationName(file_name));
}

fn expectPascalCase(name: []const u8, expected: []const u8) !void {
    var snake_buf: [64]u8 = undefined;
    var snake: Writer = .fixed(&snake_buf);
    try writeSnakeCase(&snake, name);
    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writePascalCase(&w, snake.buffered());
    try testing.expectEqualStrings(expected, w.buffered());
}

test "pascal case follows the snake case words" {
    try expectPascalCase("create_user", "CreateUser");
    try expectPascalCase("DropUser", "DropUser");
    try expectPascalCase("Addemailtousers", "Addemailtousers");
    try expectPascalCase("Add_email_to_Users", "AddEmailToUsers");
    try expectPascalCase("CreateUsers2", "CreateUsers2");
    try expectPascalCase("AddHTTPRequestLog", "AddHttpRequestLog");
    try expectPascalCase("_users", "Users");
}

test "timestamps are zero padded" {
    var buf: [timestamp_len]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeTimestamp(&w, 0);
    try testing.expectEqualStrings("19700101000000", w.buffered());
}

test "name validation" {
    for ([_][]const u8{ "create_users", "CreateUsers", "CreateUsers2", "a", "a_1", "_users" }) |name| {
        try testing.expect(isValidName(name));
    }
    for ([_][]const u8{ "", "2", "2users", "create-users", "create users", "users!", "café" }) |name| {
        try testing.expect(!isValidName(name));
    }
}
