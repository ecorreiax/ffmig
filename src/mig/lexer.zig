//! Pull-based lexer for `.mig` source. The parser calls `next()` for one
//! token at a time; nothing is allocated. Errors come back as `.invalid`
//! tokens and the parser turns them into diagnostics.

const std = @import("std");
const token = @import("token.zig");
const Span = token.Span;
const Tag = token.Tag;
const Token = token.Token;

pub const Lexer = struct {
    source: []const u8,
    index: u32 = 0,

    pub fn init(source: []const u8) Lexer {
        std.debug.assert(source.len <= std.math.maxInt(u32));
        return .{ .source = source };
    }

    /// Returns the next token, and `.eof` forever once the source is exhausted.
    pub fn next(self: *Lexer) Token {
        self.skipTrivia();
        const start = self.index;
        const c = self.peek(0) orelse return self.make(.eof, start);
        self.index += 1;

        switch (c) {
            '{' => return self.make(.l_brace, start),
            '}' => return self.make(.r_brace, start),
            '[' => return self.make(.l_bracket, start),
            ']' => return self.make(.r_bracket, start),
            ',' => return self.make(.comma, start),
            ':' => {
                if (!isIdentStart(self.peek(0))) return self.make(.invalid, start);
                self.skipIdent();
                return .{ .tag = .symbol, .span = .{ .start = start + 1, .end = self.index } };
            },
            '"' => return self.string(start),
            '-', '0'...'9' => {
                if (c == '-' and !isDigit(self.peek(0))) return self.make(.invalid, start);
                while (isDigit(self.peek(0))) self.index += 1;
                // `0abc` is one bad token, not `0` followed by a new call `abc`.
                if (isIdentStart(self.peek(0))) {
                    self.skipIdent();
                    return self.make(.invalid, start);
                }
                return self.make(.integer, start);
            },
            'A'...'Z', 'a'...'z', '_' => {
                self.skipIdent();
                const end = self.index;
                if (self.peek(0) == ':') {
                    self.index += 1;
                    return .{ .tag = .label, .span = .{ .start = start, .end = end } };
                }
                const tag = token.keywords.get(self.source[start..end]) orelse .ident;
                return self.make(tag, start);
            },
            else => {
                // Keep a multi-byte UTF-8 character in one token so the
                // diagnostic can print it whole.
                const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
                self.index = @min(start + len, @as(u32, @intCast(self.source.len)));
                return self.make(.invalid, start);
            },
        }
    }

    /// Lexes a string whose opening quote at `start` is already consumed.
    /// Stops at the closing quote, or before a line break or EOF when unterminated.
    fn string(self: *Lexer, start: u32) Token {
        var valid = true;
        while (self.peek(0)) |c| {
            switch (c) {
                '\n', '\r' => break,
                '"' => {
                    self.index += 1;
                    return self.make(if (valid) .string else .invalid, start);
                },
                '\\' => {
                    self.index += 1;
                    const e = self.peek(0) orelse break;
                    switch (e) {
                        '\n', '\r' => break,
                        '"', '\\', 'n', 't' => {},
                        else => valid = false,
                    }
                    self.index += 1;
                },
                else => self.index += 1,
            }
        }
        return self.make(.invalid, start);
    }

    fn skipTrivia(self: *Lexer) void {
        while (self.peek(0)) |c| {
            switch (c) {
                ' ', '\t', '\r', '\n' => self.index += 1,
                '#' => while (self.peek(0)) |d| {
                    if (d == '\n') break;
                    self.index += 1;
                },
                else => return,
            }
        }
    }

    fn skipIdent(self: *Lexer) void {
        while (isIdentContinue(self.peek(0))) self.index += 1;
    }

    fn peek(self: *const Lexer, ahead: u32) ?u8 {
        const i = self.index + ahead;
        return if (i < self.source.len) self.source[i] else null;
    }

    fn make(self: *const Lexer, tag: Tag, start: u32) Token {
        return .{ .tag = tag, .span = .{ .start = start, .end = self.index } };
    }
};

fn isDigit(c: ?u8) bool {
    return c != null and std.ascii.isDigit(c.?);
}

fn isIdentStart(c: ?u8) bool {
    return c != null and (std.ascii.isAlphabetic(c.?) or c.? == '_');
}

fn isIdentContinue(c: ?u8) bool {
    return c != null and (std.ascii.isAlphanumeric(c.?) or c.? == '_');
}

const testing = std.testing;

const Expected = struct { Tag, []const u8 };

/// Lexes `source` and checks each token's tag and text, then `.eof`.
fn expectTokens(source: []const u8, expected: []const Expected) !void {
    var lexer: Lexer = .init(source);
    for (expected, 0..) |e, i| {
        const tok = lexer.next();
        errdefer std.debug.print("token {d}: expected {t} \"{s}\", got {t} \"{s}\"\n", .{
            i, e[0], e[1], tok.tag, tok.span.slice(source),
        });
        try testing.expectEqual(e[0], tok.tag);
        try testing.expectEqualStrings(e[1], tok.span.slice(source));
    }
    const eof = lexer.next();
    try testing.expectEqual(Tag.eof, eof.tag);
    try testing.expectEqual(Span{ .start = @intCast(source.len), .end = @intCast(source.len) }, eof.span);
}

test "every token kind on its own" {
    const cases = [_]struct { []const u8, Tag, []const u8 }{
        .{ "create_table", .ident, "create_table" },
        .{ "CreateUsers2", .ident, "CreateUsers2" },
        .{ "_x", .ident, "_x" },
        .{ "null:", .label, "null" },
        .{ ":users", .symbol, "users" },
        .{ "123", .integer, "123" },
        .{ "\"guest\"", .string, "\"guest\"" },
        .{ "true", .kw_true, "true" },
        .{ "false", .kw_false, "false" },
        .{ "nil", .kw_nil, "nil" },
        .{ "{", .l_brace, "{" },
        .{ "}", .r_brace, "}" },
        .{ "[", .l_bracket, "[" },
        .{ "]", .r_bracket, "]" },
        .{ ",", .comma, "," },
        .{ "@", .invalid, "@" },
    };
    for (cases) |c| try expectTokens(c[0], &.{.{ c[1], c[2] }});
}

test "empty source is eof forever" {
    var lexer: Lexer = .init("  # only a comment");
    for (0..3) |_| try testing.expectEqual(Tag.eof, lexer.next().tag);
}

test "labels and symbols are decided by adjacency" {
    try expectTokens("id: :uuid", &.{ .{ .label, "id" }, .{ .symbol, "uuid" } });
    try expectTokens("null:false", &.{ .{ .label, "null" }, .{ .kw_false, "false" } });
    try expectTokens("null: false", &.{ .{ .label, "null" }, .{ .kw_false, "false" } });
    try expectTokens("null :false", &.{ .{ .ident, "null" }, .{ .symbol, "false" } });
    try expectTokens("default::now", &.{ .{ .label, "default" }, .{ .symbol, "now" } });
    try expectTokens(":up up: true:", &.{ .{ .symbol, "up" }, .{ .label, "up" }, .{ .label, "true" } });
}

test "integers" {
    try expectTokens("-5 0 123", &.{ .{ .integer, "-5" }, .{ .integer, "0" }, .{ .integer, "123" } });
    try expectTokens("1,2", &.{ .{ .integer, "1" }, .{ .comma, "," }, .{ .integer, "2" } });
}

test "strings" {
    try expectTokens("\"a\\\"b\"", &.{.{ .string, "\"a\\\"b\"" }});
    try expectTokens("\"\\\\ \\n \\t\"", &.{.{ .string, "\"\\\\ \\n \\t\"" }});
    try expectTokens("\"\"", &.{.{ .string, "\"\"" }});
    try expectTokens("\"h\xc3\xa9\"", &.{.{ .string, "\"h\xc3\xa9\"" }});
}

test "comments and blank lines are skipped" {
    try expectTokens(
        \\# heading
        \\
        \\  foo # trailing
        \\
        \\bar "# not a comment" # real one
    , &.{ .{ .ident, "foo" }, .{ .ident, "bar" }, .{ .string, "\"# not a comment\"" } });
    try expectTokens("a\r\n\tb", &.{ .{ .ident, "a" }, .{ .ident, "b" } });
}

test "invalid tokens" {
    // Unterminated: stops before the line break, and lexing continues after it.
    try expectTokens("\"abc", &.{.{ .invalid, "\"abc" }});
    try expectTokens("\"abc\nx", &.{ .{ .invalid, "\"abc" }, .{ .ident, "x" } });
    try expectTokens("\"abc\\", &.{.{ .invalid, "\"abc\\" }});
    try expectTokens("\"abc\\\n\"", &.{ .{ .invalid, "\"abc\\" }, .{ .invalid, "\"" } });
    // Bad escape: the whole string is one invalid token.
    try expectTokens("\"a\\xb\" c", &.{ .{ .invalid, "\"a\\xb\"" }, .{ .ident, "c" } });
    // Lone colon.
    try expectTokens(": x", &.{ .{ .invalid, ":" }, .{ .ident, "x" } });
    try expectTokens("a :", &.{ .{ .ident, "a" }, .{ .invalid, ":" } });
    // Unexpected bytes.
    try expectTokens("@", &.{.{ .invalid, "@" }});
    try expectTokens("a=b;", &.{ .{ .ident, "a" }, .{ .invalid, "=" }, .{ .ident, "b" }, .{ .invalid, ";" } });
    try expectTokens("- 5", &.{ .{ .invalid, "-" }, .{ .integer, "5" } });
    try expectTokens("0abc 1", &.{ .{ .invalid, "0abc" }, .{ .integer, "1" } });
    try expectTokens("\xc3\xa9x", &.{ .{ .invalid, "\xc3\xa9" }, .{ .ident, "x" } });
    try expectTokens("\xc3", &.{.{ .invalid, "\xc3" }});
}

test "the worked example lexes without invalid tokens" {
    const source =
        \\# Profiles for users, keyed by UUID.
        \\migration CreateUsersProfile {
        \\  change {
        \\    create_table :users_profile, id: :uuid {
        \\      string :name
        \\      string :email, null: false, limit: 255
        \\      integer :role, null: false, default: 0
        \\      boolean :active, default: true
        \\      decimal :balance, precision: 10, scale: 2, default: 0
        \\      json :settings, default: "{}"
        \\      datetime :confirmed_at, default: :now
        \\      timestamps
        \\    }
        \\    add_index :users_profile, :email, unique: true
        \\  }
        \\}
        \\
    ;
    var lexer: Lexer = .init(source);
    var count: usize = 0;
    while (true) : (count += 1) {
        const tok = lexer.next();
        try testing.expect(tok.tag != .invalid);
        if (tok.tag == .eof) break;
    }
    try testing.expectEqual(66, count);

    // Spot-check spans on the create_table line.
    lexer = .init(source);
    while (lexer.next().tag != .l_brace) {} // migration CreateUsersProfile {
    while (lexer.next().tag != .l_brace) {} // change {
    try testing.expectEqualStrings("create_table", lexer.next().span.slice(source));
    try testing.expectEqualStrings("users_profile", lexer.next().span.slice(source));
    try testing.expectEqual(Tag.comma, lexer.next().tag);
    const id = lexer.next();
    try testing.expectEqual(Tag.label, id.tag);
    try testing.expectEqualStrings("id", id.span.slice(source));
    try testing.expectEqual(token.LineCol{ .line = 4, .col = 34 }, token.lineCol(source, id.span.start));
    try testing.expectEqualStrings("uuid", lexer.next().span.slice(source));
}
