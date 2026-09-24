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
            '"' => {
                if (self.peek(0) == '"' and self.peek(1) == '"') return self.multilineString(start);
                return self.string(start);
            },
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

    /// Lexes a `"""` string whose first quote at `start` is already
    /// consumed, through the closing `"""`. Checks the line break after
    /// the opening and the escapes; the parser checks the indentation.
    /// Without the line break, the invalid token is the opening `"""`;
    /// unterminated, it runs to EOF.
    fn multilineString(self: *Lexer, start: u32) Token {
        self.index += 2;
        if (self.peek(0) == '\n') {
            self.index += 1;
        } else if (self.peek(0) == '\r' and self.peek(1) == '\n') {
            self.index += 2;
        } else return self.make(.invalid, start);

        var valid = true;
        while (self.peek(0)) |c| {
            switch (c) {
                '"' => {
                    if (self.peek(1) == '"' and self.peek(2) == '"') {
                        self.index += 3;
                        return self.make(if (valid) .string else .invalid, start);
                    }
                    self.index += 1;
                },
                '\\' => {
                    self.index += 1;
                    const e = self.peek(0) orelse break;
                    switch (e) {
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
