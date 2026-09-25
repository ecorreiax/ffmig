//! What `ffmig dump` needs from PostgreSQL's `pg_dump`: its arguments,
//! with the password kept out of them, and its output cleaned so that
//! dumping the same schema twice gives the same file.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// How to run `pg_dump`.
pub const Command = struct {
    argv: []const []const u8,
    /// For `PGPASSWORD`: a password in the argument list would show in
    /// `ps` to every user of the machine.
    password: ?[]const u8,
};

/// `program` dumping the schema of the database at `url`, only `schema`
/// when it is set, without owners and privileges, which differ between
/// the machines that load the file.
pub fn command(arena: Allocator, program: []const u8, url: []const u8, schema: ?[]const u8) Allocator.Error!Command {
    const split = try splitPassword(arena, url);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ program, "--schema-only", "--no-owner", "--no-privileges" });
    if (schema) |s| try argv.append(arena, try std.mem.concat(arena, u8, &.{ "--schema=", s }));
    try argv.append(arena, try std.mem.concat(arena, u8, &.{ "--dbname=", split.url }));
    return .{ .argv = argv.items, .password = split.password };
}

/// `url` without the password of its user info, and that password,
/// percent-decoded. A URL without one comes back as is.
pub fn splitPassword(arena: Allocator, url: []const u8) Allocator.Error!struct { url: []const u8, password: ?[]const u8 } {
    const scheme_end = (std.mem.indexOf(u8, url, "://") orelse return .{ .url = url, .password = null }) + 3;
    const rest = url[scheme_end..];
    const authority = rest[0 .. std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len];
    const at = std.mem.lastIndexOfScalar(u8, authority, '@') orelse return .{ .url = url, .password = null };
    const colon = std.mem.indexOfScalar(u8, authority[0..at], ':') orelse return .{ .url = url, .password = null };
    const password = try arena.dupe(u8, authority[colon + 1 .. at]);
    return .{
        .url = try std.mem.concat(arena, u8, &.{ url[0..scheme_end], authority[0..colon], rest[at..] }),
        .password = std.Uri.percentDecodeInPlace(password),
    };
}

/// What `clean` puts first, in place of `pg_dump`'s own settings, which
/// change from one `pg_dump` version to the next. These are the ones
/// that matter to loading the file: every name in it is qualified, so it
/// does not depend on the search path, and function bodies are not
/// checked, since they may use tables created further down.
pub const preamble =
    \\-- The schema of the database, written by 'ffmig dump' with pg_dump.
    \\-- 'ffmig load' creates it in an empty database.
    \\
    \\SET client_encoding = 'UTF8';
    \\SET standard_conforming_strings = on;
    \\SELECT pg_catalog.set_config('search_path', '', false);
    \\SET check_function_bodies = false;
    \\SET xmloption = content;
    \\
;

/// `pg_dump`'s plain output, cleaned for a file that is committed and
/// loaded elsewhere: `preamble` instead of its header and settings, which
/// name its version, without its footer and the random `\restrict` keys
/// of recent versions (psql commands, which `ffmig load` could not run
/// anyway), without comments on extensions (only their owner may set
/// them), and with `CREATE SCHEMA IF NOT EXISTS`, since the schema may
/// have been created by hand before loading, as `migrate` requires.
/// Ends with one line break.
pub fn clean(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, preamble);

    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "\\restrict ") or std.mem.startsWith(u8, line, "\\unrestrict ")) continue;
        try lines.append(arena, std.mem.trimEnd(u8, line, "\r"));
    }

    // Entries start with a `--` / `-- Name: ...` / `--` header. What comes
    // before the first one is the header and settings; the footer is an
    // entry of its own.
    var i: usize = 0;
    while (i < lines.items.len and !isEntryStart(lines.items, i)) i += 1;
    try out.append(arena, '\n');
    while (i < lines.items.len) : (i += 1) {
        const line = lines.items[i];
        if (isEntryStart(lines.items, i)) {
            const name = lines.items[i + 1];
            if (std.mem.eql(u8, name, "-- PostgreSQL database dump complete")) break;
            if (std.mem.startsWith(u8, name, "-- Name: EXTENSION ") and std.mem.indexOf(u8, name, "; Type: COMMENT;") != null) {
                // The header, the blank line after it, the statement up
                // to the next blank line, and the blank lines after it.
                // Settings may follow.
                i += 3;
                while (i < lines.items.len and lines.items[i].len == 0) i += 1;
                while (i < lines.items.len and lines.items[i].len != 0) i += 1;
                while (i < lines.items.len and lines.items[i].len == 0) i += 1;
                i -= 1;
                continue;
            }
        }
        if (std.mem.startsWith(u8, line, "CREATE SCHEMA ") and !std.mem.startsWith(u8, line, "CREATE SCHEMA IF NOT EXISTS ")) {
            try out.appendSlice(arena, "CREATE SCHEMA IF NOT EXISTS ");
            try out.appendSlice(arena, line["CREATE SCHEMA ".len..]);
        } else {
            try out.appendSlice(arena, line);
        }
        try out.append(arena, '\n');
    }

    // One line break at the end, however many blank lines pg_dump left.
    const trimmed = std.mem.trimEnd(u8, out.items, "\n");
    out.shrinkRetainingCapacity(trimmed.len);
    try out.append(arena, '\n');
    return out.items;
}

/// Whether `lines[i]` starts an entry: `--`, then `-- Name: ...` or the
/// footer, then `--`.
fn isEntryStart(lines: []const []const u8, i: usize) bool {
    if (i + 2 >= lines.len) return false;
    if (!std.mem.eql(u8, lines[i], "--") or !std.mem.eql(u8, lines[i + 2], "--")) return false;
    const name = lines[i + 1];
    return std.mem.startsWith(u8, name, "-- Name: ") or std.mem.eql(u8, name, "-- PostgreSQL database dump complete");
}

/// Whether `pg_dump`'s error output says that it is older than the
/// server, which it refuses.
pub fn versionMismatch(stderr: []const u8) bool {
    return std.mem.indexOf(u8, stderr, "server version mismatch") != null;
}
