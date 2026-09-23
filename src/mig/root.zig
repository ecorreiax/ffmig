//! The `.mig` language front end. See `docs/mig.md` for the specification.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const token = @import("token.zig");
pub const Lexer = @import("lexer.zig").Lexer;
pub const ast = @import("ast.zig");
const parser = @import("parser.zig");
const lower = @import("lower.zig");

pub const Diagnostic = parser.Diagnostic;
pub const Error = parser.Error || lower.Error;

/// Parses and lowers one `.mig` file. On `error.InvalidSyntax` or
/// `error.InvalidMigration`, `diag` holds the message and span. Everything
/// returned is allocated in `arena` or is a slice of `source`.
pub fn parseMigration(arena: Allocator, source: []const u8, diag: *Diagnostic) Error!ast.Migration {
    const file = try parser.parse(arena, source, diag);
    return lower.lower(arena, file, diag);
}

const testing = std.testing;

test parseMigration {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};

    const migration = try parseMigration(arena.allocator(), "migration AddRole { change { add_column :users, :role, :integer } }", &diag);
    try testing.expectEqualStrings("AddRole", migration.name);
    try testing.expectEqual(.integer, migration.body.change[0].kind.add_column.column.type);

    try testing.expectError(error.InvalidSyntax, parseMigration(arena.allocator(), "migration {", &diag));
    try testing.expectError(error.InvalidMigration, parseMigration(arena.allocator(), "migration M { up { } }", &diag));
    try testing.expectEqualStrings("missing 'down' block", diag.message);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("lexer.zig");
    _ = parser;
    _ = lower;
}
