//! Loads `ffmig.toml`. Only the subset of TOML that `ffmig init` writes is
//! understood: `[section]` headers, `key = "string"` pairs and comments.
//! Unknown sections and keys are ignored.
//!
//! ```toml
//! [migration]
//! path = "migrations"
//! lock_timeout = "5s"      # optional; unset leaves the server's setting
//! statement_timeout = "0"  # optional; "0" means no limit
//!
//! [database]
//! url = "${DATABASE_URL}"
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const file_name = "ffmig.toml";
pub const default_path = "migrations";

pub const Config = struct {
    /// Migrations directory, relative to the config file.
    path: []const u8,
    url: ?[]const u8,
    timeouts: Timeouts = .{},

    pub fn deinit(c: Config, gpa: Allocator) void {
        gpa.free(c.path);
        if (c.url) |u| gpa.free(u);
    }
};

/// `[migration] lock_timeout` and `statement_timeout`, in milliseconds,
/// 0 for no limit. Null leaves the database server's setting alone.
pub const Timeouts = struct {
    lock: ?u32 = null,
    statement: ?u32 = null,
};

pub const Diagnostics = struct {
    /// 1-based line of the first error.
    line: usize = 0,
    /// On `error.InvalidTimeout`, the key whose value is not a duration.
    key: []const u8 = "",
};

pub const ParseError = error{ InvalidSyntax, InvalidTimeout, OutOfMemory };

pub const LoadError = ParseError || Io.Dir.ReadFileAllocError;

pub fn load(io: Io, dir: Io.Dir, gpa: Allocator, diag: *Diagnostics) LoadError!Config {
    const source = try dir.readFileAlloc(io, file_name, gpa, .limited(1024 * 1024));
    defer gpa.free(source);
    return parse(gpa, source, diag);
}

pub fn parse(gpa: Allocator, source: []const u8, diag: *Diagnostics) ParseError!Config {
    var path: ?[]const u8 = null;
    errdefer if (path) |p| gpa.free(p);
    var url: ?[]const u8 = null;
    errdefer if (url) |u| gpa.free(u);
    var timeouts: Timeouts = .{};

    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_no: usize = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        errdefer diag.line = line_no;

        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse return error.InvalidSyntax;
            if (!isBlankOrComment(line[end + 1 ..])) return error.InvalidSyntax;
            section = std.mem.trim(u8, line[1..end], " \t");
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidSyntax;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const raw_value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (eql(section, "migration")) if (timeoutSlot(&timeouts, key)) |t| {
            const text = try parseString(gpa, raw_value);
            defer gpa.free(text);
            t.slot.* = parseDuration(text) orelse {
                diag.key = t.key;
                return error.InvalidTimeout;
            };
            continue;
        };
        const slot = if (eql(section, "migration") and eql(key, "path"))
            &path
        else if (eql(section, "database") and eql(key, "url"))
            &url
        else
            continue;

        const value = try parseString(gpa, raw_value);
        if (slot.*) |old| gpa.free(old);
        slot.* = value;
    }

    return .{
        .path = path orelse try gpa.dupe(u8, default_path),
        .url = url,
        .timeouts = timeouts,
    };
}

/// The field of `t` that `key` sets, and `key` itself with a lifetime
/// that outlives the source.
fn timeoutSlot(t: *Timeouts, key: []const u8) ?struct { key: []const u8, slot: *?u32 } {
    if (eql(key, "lock_timeout")) return .{ .key = "lock_timeout", .slot = &t.lock };
    if (eql(key, "statement_timeout")) return .{ .key = "statement_timeout", .slot = &t.statement };
    return null;
}

/// Parses a duration: `0`, or a whole number followed by `ms`, `s`, `min`
/// or `h`, such as `5s`. Returns milliseconds, or null when `s` is not a
/// duration or exceeds 2^31 - 1 ms (about 24 days, the most PostgreSQL
/// accepts).
pub fn parseDuration(s: []const u8) ?u32 {
    if (eql(s, "0")) return 0;
    const digits = std.mem.indexOfNone(u8, s, "0123456789") orelse return null;
    if (digits == 0) return null;
    const units = [_]struct { []const u8, u64 }{ .{ "ms", 1 }, .{ "s", 1000 }, .{ "min", 60_000 }, .{ "h", 3_600_000 } };
    const scale = for (units) |u| {
        if (eql(s[digits..], u[0])) break u[1];
    } else return null;
    const n = std.fmt.parseInt(u64, s[0..digits], 10) catch return null;
    const ms = std.math.mul(u64, n, scale) catch return null;
    return if (ms <= std.math.maxInt(i32)) @intCast(ms) else null;
}

/// Parses a basic ("...") or literal ('...') string, allowing a trailing comment.
fn parseString(gpa: Allocator, s: []const u8) ParseError![]const u8 {
    if (s.len < 2) return error.InvalidSyntax;

    if (s[0] == '\'') {
        const end = std.mem.indexOfScalarPos(u8, s, 1, '\'') orelse return error.InvalidSyntax;
        if (!isBlankOrComment(s[end + 1 ..])) return error.InvalidSyntax;
        return gpa.dupe(u8, s[1..end]);
    }
    if (s[0] != '"') return error.InvalidSyntax;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '"' => {
                if (!isBlankOrComment(s[i + 1 ..])) return error.InvalidSyntax;
                return buf.toOwnedSlice(gpa);
            },
            '\\' => {
                i += 1;
                if (i == s.len) return error.InvalidSyntax;
                try buf.append(gpa, switch (s[i]) {
                    '"', '\\' => s[i],
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    else => return error.InvalidSyntax,
                });
            },
            else => |c| try buf.append(gpa, c),
        }
    }
    return error.InvalidSyntax;
}

fn isBlankOrComment(s: []const u8) bool {
    const rest = std.mem.trimStart(u8, s, " \t");
    return rest.len == 0 or rest[0] == '#';
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub const ExpandError = error{ UndefinedVariable, InvalidSyntax, OutOfMemory };

/// Replaces each `${NAME}` in `s` with the variable's value from `environ`.
/// On `error.UndefinedVariable`, `missing` holds the variable name, a
/// slice of `s`. A `$` not followed by `{` is kept as is.
pub fn expandEnv(
    gpa: Allocator,
    s: []const u8,
    environ: *const std.process.Environ.Map,
    missing: *[]const u8,
) ExpandError![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var rest = s;
    while (std.mem.indexOf(u8, rest, "${")) |i| {
        try buf.appendSlice(gpa, rest[0..i]);
        const end = std.mem.indexOfScalarPos(u8, rest, i + 2, '}') orelse return error.InvalidSyntax;
        const name = rest[i + 2 .. end];
        if (name.len == 0) return error.InvalidSyntax;
        const value = environ.get(name) orelse {
            missing.* = name;
            return error.UndefinedVariable;
        };
        try buf.appendSlice(gpa, value);
        rest = rest[end + 1 ..];
    }
    try buf.appendSlice(gpa, rest);
    return buf.toOwnedSlice(gpa);
}
