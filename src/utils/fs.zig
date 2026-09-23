//! Helpers for naming files that ffmig creates: migration names,
//! timestamps and `<timestamp>_<name>.mig` file names.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;

pub const timestamp_len = "YYYYMMDDHHMMSS".len;
pub const migration_extension = ".mig";

/// Current wall-clock time in seconds since the Unix epoch.
pub fn now(io: Io) u64 {
    return @intCast(Io.Clock.real.now(io).toSeconds());
}

/// Non-empty, made only of letters, digits and underscores, and not
/// starting with a digit.
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

/// Returns `<timestamp>_<snake_case name>.mig`. Expects a name that passed
/// `isValidName`.
pub fn migrationFileName(gpa: Allocator, epoch_secs: u64, name: []const u8) Allocator.Error![]u8 {
    var buf: Writer.Allocating = .init(gpa);
    defer buf.deinit();
    const w = &buf.writer;
    writeTimestamp(w, epoch_secs) catch return error.OutOfMemory;
    w.writeByte('_') catch return error.OutOfMemory;
    writeSnakeCase(w, name) catch return error.OutOfMemory;
    w.writeAll(migration_extension) catch return error.OutOfMemory;
    return buf.toOwnedSlice();
}

/// The snake_case name inside a file name built by `migrationFileName`.
pub fn migrationName(file_name: []const u8) []const u8 {
    return file_name[timestamp_len + 1 .. file_name.len - migration_extension.len];
}

/// Writes `epoch_secs` as a UTC `YYYYMMDDHHMMSS` timestamp.
pub fn writeTimestamp(w: *Writer, epoch_secs: u64) Writer.Error!void {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = epoch_secs };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch.getDaySeconds();
    try w.print("{d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    });
}

/// `CreateUsers2` -> `create_users_2`, `HTTPRequest` -> `http_request`.
/// Expects a name that passed `isValidName`.
pub fn writeSnakeCase(w: *Writer, name: []const u8) Writer.Error!void {
    const ascii = std.ascii;
    for (name, 0..) |c, i| {
        if (i > 0 and name[i - 1] != '_') {
            const prev = name[i - 1];
            const next_is_lower = i + 1 < name.len and ascii.isLower(name[i + 1]);
            const boundary = if (ascii.isUpper(c))
                !ascii.isUpper(prev) or next_is_lower
            else if (ascii.isDigit(c))
                ascii.isAlphabetic(prev)
            else
                false;
            if (boundary) try w.writeByte('_');
        }
        try w.writeByte(ascii.toLower(c));
    }
}

/// `create_users_2` -> `CreateUsers2`. Expects the output of `writeSnakeCase`.
pub fn writePascalCase(w: *Writer, snake: []const u8) Writer.Error!void {
    var word_start = true;
    for (snake) |c| {
        if (c == '_') {
            word_start = true;
            continue;
        }
        try w.writeByte(if (word_start) std.ascii.toUpper(c) else c);
        word_start = false;
    }
}

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
