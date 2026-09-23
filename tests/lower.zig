const std = @import("std");
const Allocator = std.mem.Allocator;
const mig = @import("ffmig").mig;
const ast = mig.ast;
const parser = mig.parser;
const lower = mig.lower.lower;
const Span = mig.token.Span;
const Diagnostic = mig.Diagnostic;

const testing = std.testing;

fn lowerSource(arena: Allocator, source: []const u8, diag: *Diagnostic) !ast.Migration {
    return lower(arena, try parser.parse(arena, source, diag), diag);
}

/// From the first occurrence of `first` through the end of the next
/// occurrence of `last`.
fn spanOf(source: []const u8, first: []const u8, last: []const u8) Span {
    const start = std.mem.indexOf(u8, source, first).?;
    const end = std.mem.indexOfPos(u8, source, start, last).? + last.len;
    return .{ .start = @intCast(start), .end = @intCast(end) };
}

fn spanOfText(source: []const u8, text: []const u8) Span {
    return spanOf(source, text, text);
}

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

test "the worked example lowers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const migration = try lowerSource(arena.allocator(), worked_example, &diag);

    const src = worked_example;
    var columns = [_]ast.Column{
        .{ .name = "name", .type = .string, .span = spanOfText(src, "string :name") },
        .{ .name = "email", .type = .string, .null = false, .limit = 255, .span = spanOfText(src, "string :email, null: false, limit: 255") },
        .{ .name = "role", .type = .integer, .null = false, .default = .{ .literal = .{ .integer = 0 } }, .span = spanOfText(src, "integer :role, null: false, default: 0") },
        .{ .name = "active", .type = .boolean, .default = .{ .literal = .{ .boolean = true } }, .span = spanOfText(src, "boolean :active, default: true") },
        .{ .name = "balance", .type = .decimal, .precision = 10, .scale = 2, .default = .{ .literal = .{ .integer = 0 } }, .span = spanOfText(src, "decimal :balance, precision: 10, scale: 2, default: 0") },
        .{ .name = "settings", .type = .json, .default = .{ .literal = .{ .string = "{}" } }, .span = spanOfText(src, "json :settings, default: \"{}\"") },
        .{ .name = "confirmed_at", .type = .datetime, .default = .{ .named = .now }, .span = spanOfText(src, "datetime :confirmed_at, default: :now") },
        .{ .name = "created_at", .type = .datetime, .null = false, .span = spanOfText(src, "timestamps") },
        .{ .name = "updated_at", .type = .datetime, .null = false, .span = spanOfText(src, "timestamps") },
    };
    var ops = [_]ast.Operation{
        .{
            .kind = .{ .create_table = .{ .table = "users_profile", .id = .uuid, .columns = &columns } },
            .span = spanOf(src, "create_table", "timestamps\n    }"),
        },
        .{
            .kind = .{ .add_index = .{ .table = "users_profile", .column = "email", .unique = true } },
            .span = spanOfText(src, "add_index :users_profile, :email, unique: true"),
        },
    };
    const expected: ast.Migration = .{ .name = "CreateUsersProfile", .body = .{ .change = &ops } };
    try testing.expectEqualDeep(expected, migration);
}

test "every operation lowers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const source =
        \\migration M { change {
        \\  drop_table :a
        \\  drop_table :b, id: false { string :id }
        \\  remove_column :t, :c
        \\  remove_column :t, :c, :string, limit: 5
        \\  rename_column :t, :a, :b
        \\  add_index :t, :c, name: "t_c"
        \\  remove_index :t, name: "t_c"
        \\  remove_index :t, :c, unique: true
        \\} }
    ;
    const ops = (try lowerSource(arena.allocator(), source, &diag)).body.change;
    try testing.expectEqual(8, ops.len);

    try testing.expectEqualStrings("a", ops[0].kind.drop_table.table);
    try testing.expectEqual(.bigint, ops[0].kind.drop_table.id);
    try testing.expectEqual(null, ops[0].kind.drop_table.columns);

    try testing.expectEqual(.none, ops[1].kind.drop_table.id);
    try testing.expectEqualStrings("id", ops[1].kind.drop_table.columns.?[0].name);

    try testing.expectEqualStrings("c", ops[2].kind.remove_column.name);
    try testing.expectEqual(null, ops[2].kind.remove_column.column);
    const removed = ops[3].kind.remove_column.column.?;
    try testing.expectEqual(.string, removed.type);
    try testing.expectEqual(5, removed.limit);

    try testing.expectEqualDeep(ast.RenameColumn{ .table = "t", .from = "a", .to = "b" }, ops[4].kind.rename_column);
    try testing.expectEqualDeep(ast.AddIndex{ .table = "t", .column = "c", .name = "t_c" }, ops[5].kind.add_index);
    try testing.expectEqualDeep(ast.RemoveIndex{ .table = "t", .column = null, .name = "t_c" }, ops[6].kind.remove_index);
    try testing.expectEqualDeep(ast.RemoveIndex{ .table = "t", .column = "c", .unique = true, .name = null }, ops[7].kind.remove_index);
    try testing.expectEqualStrings("drop_table :a", ops[0].span.slice(source));
}

test "timestamps adds created_at and updated_at" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const source = "migration M { change { create_table :t { timestamps } } }";
    const columns = (try lowerSource(arena.allocator(), source, &diag)).body.change[0].kind.create_table.columns;
    const span = spanOfText(source, "timestamps");
    try testing.expectEqualDeep(&[_]ast.Column{
        .{ .name = "created_at", .type = .datetime, .null = false, .span = span },
        .{ .name = "updated_at", .type = .datetime, .null = false, .span = span },
    }, columns);
}

test "up and down lower to both lists, in either order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const source =
        \\migration BackfillSlugs {
        \\  down {
        \\    remove_column :posts, :slug
        \\  }
        \\  up {
        \\    add_column :posts, :slug, :string
        \\    drop_table :old
        \\  }
        \\}
    ;
    const migration = try lowerSource(arena.allocator(), source, &diag);
    try testing.expectEqualStrings("BackfillSlugs", migration.name);
    const body = migration.body.up_down;
    try testing.expectEqual(2, body.up.len);
    try testing.expectEqualStrings("slug", body.up[0].kind.add_column.column.name);
    try testing.expectEqual(null, body.up[1].kind.drop_table.columns);
    try testing.expectEqual(1, body.down.len);
    try testing.expectEqualStrings("slug", body.down[0].kind.remove_column.name);
}

test "empty sections" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    try testing.expectEqual(0, (try lowerSource(arena.allocator(), "migration M { change { } }", &diag)).body.change.len);
    const body = (try lowerSource(arena.allocator(), "migration M { up { } down { } }", &diag)).body.up_down;
    try testing.expectEqual(0, body.up.len);
    try testing.expectEqual(0, body.down.len);
    const columns = (try lowerSource(arena.allocator(), "migration M { change { create_table :t {} } }", &diag)).body.change[0].kind.create_table.columns;
    try testing.expectEqual(0, columns.len);
}

test "defaults" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const source =
        \\migration M { change { create_table :t {
        \\  datetime :published_at, default: :now
        \\  date :day, default: :now
        \\  integer :role, null: false
        \\  string :nickname, default: nil
        \\  float :ratio, default: -1
        \\  date :since, default: "not a date"
        \\  uuid :token, default: "00000000-0000-0000-0000-000000000000"
        \\} } }
    ;
    const columns = (try lowerSource(arena.allocator(), source, &diag)).body.change[0].kind.create_table.columns;
    try testing.expectEqualDeep(ast.Default{ .named = .now }, columns[0].default.?);
    try testing.expectEqualDeep(ast.Default{ .named = .now }, columns[1].default.?);
    try testing.expectEqual(false, columns[2].null);
    try testing.expectEqual(null, columns[2].default);
    try testing.expectEqualDeep(ast.Default{ .literal = .nil }, columns[3].default.?);
    try testing.expectEqualDeep(ast.Default{ .literal = .{ .integer = -1 } }, columns[4].default.?);
    try testing.expectEqualDeep(ast.Default{ .literal = .{ .string = "not a date" } }, columns[5].default.?);
    try testing.expectEqualStrings("00000000-0000-0000-0000-000000000000", columns[6].default.?.literal.string);
}

test "option bounds" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const source =
        \\migration M { change { create_table :t {
        \\  string :a, limit: 4294967295
        \\  decimal :b, precision: 255, scale: 255
        \\  decimal :c, precision: 1, scale: 0
        \\} } }
    ;
    const columns = (try lowerSource(arena.allocator(), source, &diag)).body.change[0].kind.create_table.columns;
    try testing.expectEqual(std.math.maxInt(u32), columns[0].limit);
    try testing.expectEqual(255, columns[1].scale);
    try testing.expectEqual(0, columns[2].scale);
}

/// Wraps a snippet in `change { }` unless it is a whole migration.
fn wrap(comptime snippet: []const u8) []const u8 {
    if (std.mem.startsWith(u8, snippet, "migration")) return snippet;
    return "migration M {\n  change {\n    " ++ snippet ++ "\n  }\n}\n";
}

test "semantic errors" {
    // Source (see `wrap`), message, and the exact text of the span, which
    // must be the last occurrence of that text in the source.
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        // Migration form.
        .{ "migration M { change { } up { } }", "migration has both 'change' and 'up'", "up" },
        .{ "migration M { down { } change { } }", "migration has both 'change' and 'down'", "change" },
        .{ "migration M { up { } }", "missing 'down' block", "up" },
        .{ "migration M { down { } }", "missing 'up' block", "down" },
        .{ "migration M { change { } change { } }", "'change' block defined twice", "change" },
        .{ "migration M { up { } down { } up { } }", "'up' block defined twice", "up" },
        // Operations and arguments.
        .{ "add_idx :users, :email", "unknown operation 'add_idx'", "add_idx" },
        .{ "string :name", "unknown operation 'string'", "string" },
        .{ "add_column :users, :role", "add_column expects 3 arguments (:table, :column, :type), got 2", "add_column" },
        .{ "create_table :a, :b {}", "create_table expects 1 argument (:table), got 2", "create_table" },
        .{ "remove_column :t", "remove_column expects 2 or 3 arguments (:table, :column [, :type]), got 1", "remove_column" },
        .{ "remove_index :t, :a, :b", "remove_index expects 1 or 2 arguments (:table [, :column]), got 3", "remove_index" },
        .{ "add_column \"users\", :c, :string", "add_column expects :table to be a symbol, found a string", "\"users\"" },
        .{ "rename_column :t, :a, 5", "rename_column expects :to to be a symbol, found an integer", "5" },
        .{ "add_index :t, nil", "add_index expects :column to be a symbol, found nil", "nil" },
        .{ "add_column :t, :c, :strng", "unknown column type 'strng'", ":strng" },
        // Options.
        .{ "add_index :users, :email, uniq: true", "unknown option 'uniq' for add_index", "uniq:" },
        .{ "rename_column :t, :a, :b, unique: true", "unknown option 'unique' for rename_column", "unique:" },
        .{ "create_table :t, id: :uuid, id: false {}", "option 'id:' given twice", "id:" },
        .{ "add_index :t, :c, unique: 1", "'unique:' must be true or false", "1" },
        .{ "add_index :t, :c, name: :n", "'name:' must be a string", ":n" },
        .{ "create_table :t, id: :integer {}", "'id:' must be :bigint, :uuid or false", ":integer" },
        .{ "create_table :t, id: :none {}", "'id:' must be :bigint, :uuid or false", ":none" },
        .{ "create_table :t, id: true {}", "'id:' must be :bigint, :uuid or false", "true" },
        .{ "remove_column :t, :c, null: false", "remove_column takes options only with a :type", "null:" },
        .{ "remove_index :users", "remove_index needs a column or 'name:'", "remove_index" },
        // Blocks.
        .{ "create_table :t", "create_table needs a block of columns", "create_table" },
        .{ "add_column :t, :c, :string { }", "add_column takes no block", "add_column" },
        .{ "add_index :t, :c {}", "add_index takes no block", "add_index" },
        // Table blocks.
        .{ "create_table :t { strng :name }", "unknown column type 'strng'", "strng" },
        .{ "create_table :t { add_index :t, :c }", "add_index is not allowed inside a table block", "add_index" },
        .{ "create_table :t { string :a\n string :a }", "column 'a' defined twice in table 't'", ":a" },
        .{ "create_table :users_profile { string :email\n string :email }", "column 'email' defined twice in table 'users_profile'", ":email" },
        .{ "create_table :t { timestamps\n datetime :created_at }", "column 'created_at' defined twice in table 't'", ":created_at" },
        .{ "create_table :t { datetime :updated_at\n timestamps }", "column 'updated_at' defined twice in table 't'", "timestamps" },
        .{ "create_table :t { integer :id }", "column 'id' defined twice in table 't'", ":id" },
        .{ "drop_table :t, id: :uuid { uuid :id }", "column 'id' defined twice in table 't'", ":id" },
        .{ "create_table :t { string }", "string expects 1 argument (:name), got 0", "string" },
        .{ "create_table :t { string \"a\" }", "string expects :name to be a symbol, found a string", "\"a\"" },
        .{ "create_table :t { string :a, uniq: true }", "unknown option 'uniq' for string", "uniq:" },
        .{ "create_table :t { string :a {} }", "string takes no block", "string" },
        .{ "create_table :t { timestamps :x }", "timestamps takes no arguments", "timestamps" },
        .{ "create_table :t { timestamps null: true }", "timestamps takes no arguments", "timestamps" },
        .{ "create_table :t { timestamps {} }", "timestamps takes no block", "timestamps" },
        // Column options.
        .{ "add_column :t, :c, :string, null: nil", "'null:' must be true or false", "nil" },
        .{ "add_column :t, :c, :integer, limit: 10", "'limit:' is only allowed on string columns", "limit:" },
        .{ "add_column :t, :c, :string, limit: 0", "'limit:' must be an integer from 1 to 4294967295", "0" },
        .{ "add_column :t, :c, :string, limit: 4294967296", "'limit:' must be an integer from 1 to 4294967295", "4294967296" },
        .{ "add_column :t, :c, :string, limit: \"10\"", "'limit:' must be an integer from 1 to 4294967295", "\"10\"" },
        .{ "add_column :t, :c, :float, precision: 10", "'precision:' is only allowed on decimal columns", "precision:" },
        .{ "add_column :t, :c, :integer, scale: 2", "'scale:' is only allowed on decimal columns", "scale:" },
        .{ "add_column :t, :c, :decimal, precision: 256", "'precision:' must be an integer from 1 to 255", "256" },
        .{ "add_column :t, :c, :decimal, precision: 0", "'precision:' must be an integer from 1 to 255", "0" },
        .{ "add_column :t, :c, :decimal, scale: 2", "'scale:' needs 'precision:'", "scale:" },
        .{ "add_column :t, :c, :decimal, precision: 5, scale: 6", "'scale:' must be an integer from 0 to 5", "6" },
        .{ "add_column :t, :c, :decimal, precision: 5, scale: -1", "'scale:' must be an integer from 0 to 5", "-1" },
        // Defaults.
        .{ "add_column :t, :c, :integer, default: \"0\"", "string default is not allowed on integer column 'c'", "\"0\"" },
        .{ "add_column :t, :c, :string, default: 0", "integer default is not allowed on string column 'c'", "0" },
        .{ "add_column :t, :c, :integer, default: true", "boolean default is not allowed on integer column 'c'", "true" },
        .{ "add_column :t, :c, :boolean, default: 1", "integer default is not allowed on boolean column 'c'", "1" },
        .{ "add_column :t, :c, :binary, default: \"x\"", "string default is not allowed on binary column 'c'", "\"x\"" },
        .{ "add_column :t, :c, :date, default: :today", "unknown default ':today'", ":today" },
        .{ "add_column :t, :role, :integer, default: :now", "default ':now' is not allowed on integer column 'role'", ":now" },
        .{ "create_table :t { integer :role, default: :now }", "default ':now' is not allowed on integer column 'role'", ":now" },
        .{ "add_column :t, :c, :integer, null: false, default: nil", "default: nil on non-null column 'c'", "nil" },
        .{ "add_column :t, :c, :integer, default: nil, null: false", "default: nil on non-null column 'c'", "nil" },
    };
    inline for (cases) |c| {
        const source = comptime wrap(c[0]);
        errdefer std.debug.print("source: {s}\n", .{source});
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var diag: Diagnostic = .{};
        try testing.expectError(error.InvalidMigration, lowerSource(arena.allocator(), source, &diag));
        try testing.expectEqualStrings(c[1], diag.message);
        try testing.expectEqualStrings(c[2], diag.span.slice(source));
        try testing.expectEqual(std.mem.lastIndexOf(u8, source, c[2]).?, diag.span.start);
    }
}

test "out of memory is reported, not turned into a semantic error" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var diag: Diagnostic = .{};
            _ = try lowerSource(arena.allocator(), worked_example, &diag);
        }
    }.run, .{});
}
