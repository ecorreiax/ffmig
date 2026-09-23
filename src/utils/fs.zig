//! Helpers for the files ffmig creates: migration names, timestamps,
//! `<timestamp>_<name>.mig` file names and listing them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;

pub const timestamp_len = "YYYYMMDDHHMMSS".len;
pub const migration_extension = ".mig";

/// Names of the `*.mig` files in `dir`, sorted.
pub fn listMigrations(io: Io, dir: Io.Dir, arena: Allocator) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, migration_extension)) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sortUnstable([]const u8, names.items, {}, lessThan);
    return names.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

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

/// The `YYYYMMDDHHMMSS` version at the start of a migration file name, or
/// null if `file_name` is not `<timestamp>_<name>.mig`.
pub fn migrationVersion(file_name: []const u8) ?[]const u8 {
    if (file_name.len <= timestamp_len + 1 + migration_extension.len) return null;
    if (!std.mem.endsWith(u8, file_name, migration_extension) or file_name[timestamp_len] != '_') return null;
    const version = file_name[0..timestamp_len];
    for (version) |c| if (!std.ascii.isDigit(c)) return null;
    return version;
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
