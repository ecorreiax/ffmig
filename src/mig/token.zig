//! Tokens produced by the lexer. See "Lexical rules" in `MIG.md`.

const std = @import("std");

/// Byte offsets into the source, `end` exclusive.
pub const Span = struct {
    start: u32,
    end: u32,

    pub fn slice(s: Span, source: []const u8) []const u8 {
        return source[s.start..s.end];
    }
};

pub const Tag = enum {
    /// `create_table`, `string`, `CreateUsersProfile`
    ident,
    /// `null:` (span excludes the colon)
    label,
    /// `:users` (span excludes the colon)
    symbol,
    integer,
    /// `0.5`, `-12.25`: digits on both sides of the `.`.
    decimal,
    /// Span includes the quotes, `"""` for a multi-line string;
    /// unescaping happens in the parser.
    string,
    kw_true,
    kw_false,
    kw_nil,
    l_brace,
    r_brace,
    l_bracket,
    r_bracket,
    comma,
    eof,
    /// Unterminated string, bad escape, `"""` not followed by a line
    /// break, lone `:` or unexpected byte.
    invalid,
};

pub const Token = struct {
    tag: Tag,
    span: Span,
};

pub const keywords = std.StaticStringMap(Tag).initComptime(.{
    .{ "true", .kw_true },
    .{ "false", .kw_false },
    .{ "nil", .kw_nil },
});

/// 1-based line and column (in bytes) of `offset`.
pub const LineCol = struct { line: u32, col: u32 };

pub fn lineCol(source: []const u8, offset: u32) LineCol {
    const before = source[0..@min(offset, source.len)];
    const line_start = if (std.mem.lastIndexOfScalar(u8, before, '\n')) |i| i + 1 else 0;
    return .{
        .line = @intCast(std.mem.count(u8, before, "\n") + 1),
        .col = @intCast(before.len - line_start + 1),
    };
}
