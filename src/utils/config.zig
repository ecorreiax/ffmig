//! Loads `ffmig.toml`. Only the subset of TOML that `ffmig init` writes is
//! understood: `[section]` headers, `key = "string"` pairs and comments.
//! Unknown sections and keys are ignored.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const file_name = "ffmig.toml";
pub const default_path = "migrations";

pub const Config = struct {
    /// Migrations directory, relative to the config file.
    path: []const u8,
    url: ?[]const u8,

    pub fn deinit(c: Config, gpa: Allocator) void {
        gpa.free(c.path);
        if (c.url) |u| gpa.free(u);
    }
};

pub const Diagnostics = struct {
    /// 1-based line of the first syntax error.
    line: usize = 0,
};

pub const ParseError = error{ InvalidSyntax, OutOfMemory };

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
        const slot = if (eql(section, "migration") and eql(key, "path"))
            &path
        else if (eql(section, "database") and eql(key, "url"))
            &url
        else
            continue;

        const value = try parseString(gpa, std.mem.trim(u8, line[eq + 1 ..], " \t"));
        if (slot.*) |old| gpa.free(old);
        slot.* = value;
    }

    return .{
        .path = path orelse try gpa.dupe(u8, default_path),
        .url = url,
    };
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
