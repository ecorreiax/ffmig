//! The `.mig` language front end. See `docs/mig.md` for the specification.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const token = @import("token.zig");
pub const Lexer = @import("lexer.zig").Lexer;
pub const ast = @import("ast.zig");
pub const print = @import("print.zig");
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

/// Golden cases: each `<case>.mig` has a `<case>.ast` with the expected
/// `print` output or a `<case>.err` with the expected `line:col: message`.
/// Read at test time; `build.zig` runs the tests from the project root.
const golden_dir = "tests/mig";

test "golden cases in tests/mig" {
    const io = testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, golden_dir, .{ .iterate = true });
    defer dir.close(io);

    var cases: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".mig")) continue;
        errdefer std.debug.print("golden case: {s}/{s}\n", .{ golden_dir, entry.name });
        try expectGolden(dir, entry.name);
        cases += 1;
    }
    try testing.expect(cases > 0);
}

fn expectGolden(dir: std.Io.Dir, mig_name: []const u8) !void {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source = try dir.readFileAlloc(io, mig_name, arena, .unlimited);
    var actual: std.Io.Writer.Allocating = .init(arena);
    var diag: Diagnostic = .{};
    var ext: []const u8 = ".ast";
    if (parseMigration(arena, source, &diag)) |migration| {
        try print.migration(&actual.writer, migration);
    } else |err| switch (err) {
        error.InvalidSyntax, error.InvalidMigration => {
            const pos = token.lineCol(source, diag.span.start);
            try actual.writer.print("{d}:{d}: {s}\n", .{ pos.line, pos.col, diag.message });
            ext = ".err";
        },
        error.OutOfMemory => return err,
    }

    const stem = mig_name[0 .. mig_name.len - ".mig".len];
    const expected_name = try std.mem.concat(arena, u8, &.{ stem, ext });
    const expected = dir.readFileAlloc(io, expected_name, arena, .unlimited) catch |err| {
        std.debug.print("cannot read {s}/{s}: {t}; actual output:\n{s}", .{ golden_dir, expected_name, err, actual.written() });
        return err;
    };
    try testing.expectEqualStrings(expected, actual.written());
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("lexer.zig");
    _ = parser;
    _ = lower;
}
