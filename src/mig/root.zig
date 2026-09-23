//! The `.mig` language front end. See `docs/mig.md` for the specification.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const token = @import("token.zig");
pub const Lexer = @import("lexer.zig").Lexer;
pub const ast = @import("ast.zig");
pub const print = @import("print.zig");
pub const syntax = @import("syntax.zig");
pub const parser = @import("parser.zig");
pub const lower = @import("lower.zig");
pub const reverse = @import("reverse.zig");

pub const Diagnostic = parser.Diagnostic;
pub const Error = parser.Error || lower.Error;

/// Parses and lowers one `.mig` file. On `error.InvalidSyntax` or
/// `error.InvalidMigration`, `diag` holds the message and span. Everything
/// returned is allocated in `arena` or is a slice of `source`.
pub fn parseMigration(arena: Allocator, source: []const u8, diag: *Diagnostic) Error!ast.Migration {
    const file = try parser.parse(arena, source, diag);
    return lower.lower(arena, file, diag);
}
