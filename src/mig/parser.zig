//! Recursive descent parser for `.mig` source. Builds the generic call tree
//! in `syntax.zig` following "Grammar" in `docs/mig.md`; it knows nothing
//! about which operations exist. Stops at the first error.

const std = @import("std");
const Allocator = std.mem.Allocator;
const syntax = @import("syntax.zig");
const token = @import("token.zig");
const Lexer = @import("lexer.zig").Lexer;
const Span = token.Span;
const Tag = token.Tag;
const Token = token.Token;

pub const Error = error{ InvalidSyntax, OutOfMemory };

pub const Diagnostic = struct {
    span: Span = .{ .start = 0, .end = 0 },
    message: []const u8 = "",
};

/// Blocks deeper than this are rejected instead of risking a stack overflow.
/// The language only uses two levels (section, table block).
const max_depth = 32;

/// Parses a whole file. Everything returned, including `diag.message`, is
/// allocated in `arena`; identifiers are slices of `source`.
pub fn parse(arena: Allocator, source: []const u8, diag: *Diagnostic) Error!syntax.File {
    var p: Parser = .{
        .arena = arena,
        .source = source,
        .lexer = .init(source),
        .current = undefined,
        .diag = diag,
    };
    p.current = p.lexer.next();
    if (p.current.tag == .invalid) return p.invalidToken();
    return p.parseFile();
}

const Parser = struct {
    arena: Allocator,
    source: []const u8,
    lexer: Lexer,
    current: Token,
    /// End of the last consumed token, for node spans.
    prev_end: u32 = 0,
    depth: u32 = 0,
    diag: *Diagnostic,

    fn parseFile(p: *Parser) Error!syntax.File {
        const start = p.current.span;
        if (!p.isIdent("migration")) return p.expected("'migration'", .{});
        try p.advance();

        if (p.current.tag != .ident) return p.expected("a migration name", .{});
        const name = p.current.span;
        try p.advance();
        var args: Args = .{};
        if (p.current.tag == .comma) {
            try p.advance();
            if (!canStartArg(p.current.tag)) return p.expected("an argument after ','", .{});
            args = try p.parseArgs();
        } else if (canStartArg(p.current.tag)) return p.expected("',' after migration name", .{});
        try p.expect(.l_brace, "'{{' after migration name", .{});

        var sections: std.ArrayList(syntax.Section) = .empty;
        while (true) {
            if (sections.items.len > 0) switch (p.current.tag) {
                .r_brace => break,
                .eof => return p.unclosed("migration", start),
                else => {},
            };
            try sections.append(p.arena, try p.parseSection());
        }
        try p.advance(); // }

        if (p.current.tag != .eof) return p.expected("end of file after the migration", .{});
        return .{
            .name = name.slice(p.source),
            .name_span = name,
            .args = args.args,
            .options = args.options,
            .sections = try sections.toOwnedSlice(p.arena),
            .span = .{ .start = start.start, .end = p.prev_end },
        };
    }

    fn parseSection(p: *Parser) Error!syntax.Section {
        const kind_span = p.current.span;
        const kind = if (p.current.tag == .ident)
            std.meta.stringToEnum(syntax.Section.Kind, kind_span.slice(p.source))
        else
            null;
        if (kind == null) return p.expected("'change', 'up' or 'down'", .{});
        try p.advance();
        try p.expect(.l_brace, "'{{' after '{t}'", .{kind.?});
        const calls = try p.parseBlock(kind_span);
        return .{
            .kind = kind.?,
            .kind_span = kind_span,
            .calls = calls,
            .span = .{ .start = kind_span.start, .end = p.prev_end },
        };
    }

    /// Parses `{ call* }` after the `{`, through the closing `}`. `opener` is
    /// the name the block belongs to, reported when the block is never closed.
    fn parseBlock(p: *Parser, opener: Span) Error![]syntax.Call {
        if (p.depth == max_depth) return p.fail(p.current.span, "blocks are nested too deeply", .{});
        p.depth += 1;
        defer p.depth -= 1;

        var calls: std.ArrayList(syntax.Call) = .empty;
        while (true) switch (p.current.tag) {
            .r_brace => break,
            .ident => try calls.append(p.arena, try p.parseCall()),
            .eof => return p.unclosed(opener.slice(p.source), opener),
            else => return p.expected("a statement or '}}'", .{}),
        };
        try p.advance(); // }
        return calls.toOwnedSlice(p.arena);
    }

    /// `IDENT [ args ] [ block ]`
    fn parseCall(p: *Parser) Error!syntax.Call {
        const name = p.current.span;
        try p.advance();

        const args: Args = if (canStartArg(p.current.tag)) try p.parseArgs() else .{};
        // Only a comma continues an argument list, so a value here is a missing comma.
        if (canStartArg(p.current.tag)) return p.expected("',' or a new line", .{});

        var block: ?[]syntax.Call = null;
        if (p.current.tag == .l_brace) {
            try p.advance();
            block = try p.parseBlock(name);
        }
        return .{
            .name = name.slice(p.source),
            .name_span = name,
            .args = args.args,
            .options = args.options,
            .block = block,
            .span = .{ .start = name.start, .end = p.prev_end },
        };
    }

    const Args = struct { args: []syntax.Value = &.{}, options: []syntax.Option = &.{} };

    /// `arg { "," arg }`, starting at a token that satisfies `canStartArg`.
    fn parseArgs(p: *Parser) Error!Args {
        var args: std.ArrayList(syntax.Value) = .empty;
        var options: std.ArrayList(syntax.Option) = .empty;
        while (true) {
            if (p.current.tag == .label) {
                const key = p.current.span;
                try p.advance();
                if (!isValue(p.current.tag)) return p.expected("a value after '{s}:'", .{key.slice(p.source)});
                try options.append(p.arena, .{ .key = key.slice(p.source), .key_span = key, .value = try p.parseValue() });
            } else {
                if (options.getLastOrNull()) |last| {
                    return p.fail(fullSpan(p.current), "positional argument after option '{s}:'", .{last.key});
                }
                try args.append(p.arena, try p.parseValue());
            }
            if (p.current.tag != .comma) break;
            try p.advance();
            if (!canStartArg(p.current.tag)) return p.expected("an argument after ','", .{});
        }
        return .{ .args = try args.toOwnedSlice(p.arena), .options = try options.toOwnedSlice(p.arena) };
    }

    /// Parses the current token, which must satisfy `isValue`.
    fn parseValue(p: *Parser) Error!syntax.Value {
        const tok = p.current;
        const text = tok.span.slice(p.source);
        const kind: syntax.Value.Kind = switch (tok.tag) {
            .symbol => .{ .symbol = text },
            .string => .{ .string = try p.unescape(text) },
            .integer => .{ .integer = std.fmt.parseInt(i64, text, 10) catch
                return p.fail(tok.span, "integer '{s}' does not fit in 64 bits", .{text}) },
            .kw_true => .{ .boolean = true },
            .kw_false => .{ .boolean = false },
            .kw_nil => .nil,
            else => unreachable,
        };
        try p.advance();
        return .{ .kind = kind, .span = fullSpan(tok) };
    }

    /// `quoted` is a valid string token, quotes included. Returns a slice of
    /// the source when there are no escapes to resolve.
    fn unescape(p: *Parser, quoted: []const u8) Error![]const u8 {
        const inner = quoted[1 .. quoted.len - 1];
        if (std.mem.indexOfScalar(u8, inner, '\\') == null) return inner;
        var out: std.ArrayList(u8) = try .initCapacity(p.arena, inner.len);
        var i: usize = 0;
        while (i < inner.len) : (i += 1) {
            if (inner[i] != '\\') {
                out.appendAssumeCapacity(inner[i]);
                continue;
            }
            i += 1;
            out.appendAssumeCapacity(switch (inner[i]) {
                'n' => '\n',
                't' => '\t',
                else => inner[i], // `"` or `\`; the lexer rejects anything else
            });
        }
        return out.items;
    }

    fn advance(p: *Parser) Error!void {
        p.prev_end = p.current.span.end;
        p.current = p.lexer.next();
        if (p.current.tag == .invalid) return p.invalidToken();
    }

    fn expect(p: *Parser, tag: Tag, comptime what: []const u8, args: anytype) Error!void {
        if (p.current.tag != tag) return p.expected(what, args);
        try p.advance();
    }

    fn isIdent(p: *const Parser, text: []const u8) bool {
        return p.current.tag == .ident and std.mem.eql(u8, p.current.span.slice(p.source), text);
    }

    /// Reports `expected <what>, found <current token>` at the current token.
    fn expected(p: *Parser, comptime what: []const u8, args: anytype) Error {
        if (p.current.tag == .l_bracket or p.current.tag == .r_bracket) {
            return p.fail(p.current.span, "'{s}' is reserved for multi-column indexes", .{p.current.span.slice(p.source)});
        }
        return p.fail(fullSpan(p.current), "expected " ++ what ++ ", found {f}", args ++ .{Found{ .source = p.source, .tok = p.current }});
    }

    fn unclosed(p: *Parser, name: []const u8, opener: Span) Error {
        return p.fail(opener, "expected '}}' to close '{s}' block opened here", .{name});
    }

    /// Turns the current `.invalid` token into a diagnostic.
    fn invalidToken(p: *Parser) Error {
        const span = p.current.span;
        const text = span.slice(p.source);
        switch (text[0]) {
            '"' => {
                var i: u32 = 1;
                while (i + 1 < text.len) : (i += 1) {
                    if (text[i] != '\\') continue;
                    switch (text[i + 1]) {
                        '"', '\\', 'n', 't' => i += 1,
                        else => {
                            const len = std.unicode.utf8ByteSequenceLength(text[i + 1]) catch 1;
                            const end = @min(i + 1 + len, @as(u32, @intCast(text.len)));
                            const escape: Span = .{ .start = span.start + i, .end = span.start + end };
                            return p.fail(escape, "unknown escape '{s}' in string", .{escape.slice(p.source)});
                        },
                    }
                }
                return p.fail(span, "unterminated string", .{});
            },
            ':' => return p.fail(span, "expected a name after ':'", .{}),
            '-', '0'...'9' => {
                if (text.len == 1) return p.fail(span, "expected a digit after '-'", .{});
                return p.fail(span, "invalid number '{s}'", .{text});
            },
            else => {
                if (std.unicode.utf8ValidateSlice(text) and (text.len > 1 or std.ascii.isPrint(text[0]))) {
                    return p.fail(span, "unexpected character '{s}'", .{text});
                }
                return p.fail(span, "unexpected byte 0x{x:0>2}", .{text[0]});
            },
        }
    }

    fn fail(p: *Parser, span: Span, comptime fmt: []const u8, args: anytype) Error {
        const message = std.fmt.allocPrint(p.arena, fmt, args) catch |err| return err;
        p.diag.* = .{ .span = span, .message = message };
        return error.InvalidSyntax;
    }
};

fn isValue(tag: Tag) bool {
    return switch (tag) {
        .symbol, .string, .integer, .kw_true, .kw_false, .kw_nil => true,
        else => false,
    };
}

fn canStartArg(tag: Tag) bool {
    return tag == .label or isValue(tag);
}

/// The token's span including the `:` that symbol and label spans leave out.
fn fullSpan(tok: Token) Span {
    return switch (tok.tag) {
        .symbol => .{ .start = tok.span.start - 1, .end = tok.span.end },
        .label => .{ .start = tok.span.start, .end = tok.span.end + 1 },
        else => tok.span,
    };
}

/// Formats a token for "found ..." in diagnostics.
const Found = struct {
    source: []const u8,
    tok: Token,

    pub fn format(f: Found, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (f.tok.tag == .eof) return w.writeAll("end of file");
        try w.print("'{s}'", .{fullSpan(f.tok).slice(f.source)});
    }
};
