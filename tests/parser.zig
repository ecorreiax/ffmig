const std = @import("std");
const Allocator = std.mem.Allocator;
const mig = @import("ffmig").mig;
const syntax = mig.syntax;
const Diagnostic = mig.Diagnostic;
const parse = mig.parser.parse;

const testing = std.testing;

const worked_example =
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

fn expectSymbol(expected: []const u8, value: syntax.Value) !void {
    try testing.expectEqualStrings(expected, value.kind.symbol);
}

test "the worked example parses" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const file = try parse(arena.allocator(), worked_example, &diag);

    try testing.expectEqualStrings("CreateUsersProfile", file.name);
    try testing.expectEqualStrings("CreateUsersProfile", file.name_span.slice(worked_example));
    try testing.expectEqualStrings("migration", worked_example[file.span.start..][0..9]);
    try testing.expectEqual(worked_example.len - 1, file.span.end);
    try testing.expectEqual(1, file.sections.len);

    const change = file.sections[0];
    try testing.expectEqual(.change, change.kind);
    try testing.expectEqual(2, change.calls.len);

    const create = change.calls[0];
    try testing.expectEqualStrings("create_table", create.name);
    try testing.expectEqual(1, create.args.len);
    try expectSymbol("users_profile", create.args[0]);
    try testing.expectEqualStrings(":users_profile", create.args[0].span.slice(worked_example));
    try testing.expectEqual(1, create.options.len);
    try testing.expectEqualStrings("id", create.options[0].key);
    try expectSymbol("uuid", create.options[0].value);

    const columns = create.block.?;
    try testing.expectEqual(8, columns.len);
    const email = columns[1];
    try testing.expectEqualStrings("string", email.name);
    try expectSymbol("email", email.args[0]);
    try testing.expectEqual(2, email.options.len);
    try testing.expectEqualStrings("null", email.options[0].key);
    try testing.expectEqual(false, email.options[0].value.kind.boolean);
    try testing.expectEqualStrings("limit", email.options[1].key);
    try testing.expectEqual(255, email.options[1].value.kind.integer);
    try testing.expectEqualStrings("string :email, null: false, limit: 255", email.span.slice(worked_example));
    try testing.expectEqualStrings("{}", columns[5].options[0].value.kind.string);
    try expectSymbol("now", columns[6].options[0].value);

    const timestamps = columns[7];
    try testing.expectEqualStrings("timestamps", timestamps.name);
    try testing.expectEqual(0, timestamps.args.len);
    try testing.expectEqual(0, timestamps.options.len);
    try testing.expectEqual(null, timestamps.block);

    const index = change.calls[1];
    try testing.expectEqualStrings("add_index", index.name);
    try testing.expectEqual(2, index.args.len);
    try testing.expectEqual(true, index.options[0].value.kind.boolean);
    try testing.expectEqual(null, index.block);
    try testing.expect(std.mem.startsWith(u8, create.span.slice(worked_example), "create_table"));
    try testing.expect(std.mem.endsWith(u8, create.span.slice(worked_example), "timestamps\n    }"));
}

test "empty blocks and any sequence of sections" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};

    var file = try parse(arena.allocator(), "migration M { change { create_table :t {} } }", &diag);
    const block = file.sections[0].calls[0].block.?;
    try testing.expectEqual(0, block.len);

    file = try parse(arena.allocator(), "migration M { up { } down { } }", &diag);
    try testing.expectEqual(2, file.sections.len);
    try testing.expectEqual(.up, file.sections[0].kind);
    try testing.expectEqual(.down, file.sections[1].kind);
    try testing.expectEqualStrings("down { }", file.sections[1].span.slice("migration M { up { } down { } }"));

    file = try parse(arena.allocator(), "migration M { change {} up {} change {} }", &diag);
    try testing.expectEqual(3, file.sections.len);
}

test "nested blocks parse" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const file = try parse(arena.allocator(), "migration M { change { a { b { c :x } } } }", &diag);
    const c = file.sections[0].calls[0].block.?[0].block.?[0];
    try testing.expectEqualStrings("c", c.name);
    try expectSymbol("x", c.args[0]);
}

test "values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const source =
        \\migration M { change {
        \\  f "plain", "a\"b\\c\nd\te", -9223372036854775808, 9223372036854775807, nil, k: :up, change: false
        \\} }
    ;
    const call = (try parse(arena.allocator(), source, &diag)).sections[0].calls[0];
    try testing.expectEqual(5, call.args.len);
    const plain = call.args[0].kind.string;
    try testing.expectEqualStrings("plain", plain);
    try testing.expect(plain.ptr == source[std.mem.indexOf(u8, source, "plain").?..].ptr);
    try testing.expectEqualStrings("a\"b\\c\nd\te", call.args[1].kind.string);
    try testing.expectEqual(std.math.minInt(i64), call.args[2].kind.integer);
    try testing.expectEqual(std.math.maxInt(i64), call.args[3].kind.integer);
    try testing.expectEqual(.nil, std.meta.activeTag(call.args[4].kind));
    try expectSymbol("up", call.options[0].value);
    try testing.expectEqualStrings("change", call.options[1].key);
    try testing.expectEqual(false, call.options[1].value.kind.boolean);
}

test "duplicate options are kept" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const file = try parse(arena.allocator(), "migration M { change { f unique: true, unique: false } }", &diag);
    try testing.expectEqual(2, file.sections[0].calls[0].options.len);
}

test "syntax errors" {
    // Source, message, and a snippet that starts where the span starts
    // (its first occurrence in the source).
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "create_table :t {}", "expected 'migration', found 'create_table'", "create_table" },
        .{ "", "expected 'migration', found end of file", "" },
        .{ "migration {", "expected a migration name, found '{'", "{" },
        .{ "migration M change", "expected '{' after migration name, found 'change'", "change" },
        .{ "migration M { create_table :t {} }", "expected 'change', 'up' or 'down', found 'create_table'", "create_table" },
        .{ "migration M { }", "expected 'change', 'up' or 'down', found '}'", "}" },
        .{ "migration M { change {} :x }", "expected 'change', 'up' or 'down', found ':x'", ":x" },
        .{ "migration M { change add }", "expected '{' after 'change', found 'add'", "add" },
        .{ "migration M {\n  change {\n    add_column :t, :c, :string\n", "expected '}' to close 'change' block opened here", "change" },
        .{ "migration M { change { create_table :t { string :a } ", "expected '}' to close 'change' block opened here", "change" },
        .{ "migration M { change { create_table :t { string :a", "expected '}' to close 'create_table' block opened here", "create_table" },
        .{ "migration M { change { } ", "expected '}' to close 'migration' block opened here", "migration" },
        .{ "migration M { change { } } x", "expected end of file after the migration, found 'x'", "x" },
        .{ "migration M { change { } } :x", "expected end of file after the migration, found ':x'", ":x" },
        .{ "migration M { change { add_index :users, unique: true, :email } }", "positional argument after option 'unique:'", ":email" },
        .{ "migration M { change { add_column :t, :c, null: true, 5 } }", "positional argument after option 'null:'", "5" },
        .{ "migration M { change { add_column :t, default: } }", "expected a value after 'default:', found '}'", "} }" },
        .{ "migration M { change { add_column :t, default: x: 1 } }", "expected a value after 'default:', found 'x:'", "x:" },
        .{ "migration M { change { add_index :users, :email,\n add_index :a, :b } }", "expected an argument after ',', found 'add_index'", "add_index :a" },
        .{ "migration M { change { add_index :users :email } }", "expected ',' or a new line, found ':email'", ":email" },
        .{ "migration M { change { add_index :t, [:a, :b] } }", "'[' is reserved for multi-column indexes", "[" },
        .{ "migration M { change { , } }", "expected a statement or '}', found ','", ", }" },
        .{ "migration M { change { f 9223372036854775808 } }", "integer '9223372036854775808' does not fit in 64 bits", "92" },
        .{ "migration M { change { f -9223372036854775809 } }", "integer '-9223372036854775809' does not fit in 64 bits", "-92" },
        // Lexical errors.
        .{ "migration M { change { x \"abc } }", "unterminated string", "\"abc" },
        .{ "migration M { change { x \"a\\\"", "unterminated string", "\"a" },
        .{ "migration M { change { x \"a\\qb\" } }", "unknown escape '\\q' in string", "\\q" },
        .{ "migration M { change { x : y } }", "expected a name after ':'", ": y" },
        .{ "migration M { change { x 0abc } }", "invalid number '0abc'", "0abc" },
        .{ "migration M { change { x - 1 } }", "expected a digit after '-'", "- 1" },
        .{ "migration M { change { x = 1 } }", "unexpected character '='", "=" },
        .{ "migration M { change { x \xc3\xa9 } }", "unexpected character '\xc3\xa9'", "\xc3" },
        .{ "migration M { change { x \x00 } }", "unexpected byte 0x00", "\x00" },
        .{ "migration@", "unexpected character '@'", "@" },
    };
    for (cases) |c| {
        errdefer std.debug.print("source: {s}\n", .{c[0]});
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var diag: Diagnostic = .{};
        try testing.expectError(error.InvalidSyntax, parse(arena.allocator(), c[0], &diag));
        try testing.expectEqualStrings(c[1], diag.message);
        try testing.expectEqual(std.mem.indexOf(u8, c[0], c[2]).?, diag.span.start);
    }
}

test "deep nesting is an error, not a stack overflow" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const source = "migration M { change { " ++ "a { " ** 100;
    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidSyntax, parse(arena.allocator(), source, &diag));
    try testing.expectEqualStrings("blocks are nested too deeply", diag.message);
}

test "out of memory is reported, not turned into a syntax error" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var diag: Diagnostic = .{};
            _ = try parse(arena.allocator(), worked_example, &diag);
        }
    }.run, .{});
}
