const std = @import("std");
const mig = @import("ffmig").mig;
const ast = mig.ast;
const reverse = mig.reverse;
const Diagnostic = mig.Diagnostic;

const testing = std.testing;

/// Parses `source` and prints its plan.
fn expectPlan(source: []const u8, expected: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostic = .{};
    const migration = try mig.parseMigration(arena, source, &diag);
    const p = try reverse.plan(arena, migration, &diag);

    var actual: std.Io.Writer.Allocating = .init(arena);
    try mig.print.plan(&actual.writer, migration, p);
    try testing.expectEqualStrings(expected, actual.written());
}

/// Expects `source` to be irreversible at `op`, the offending operation's
/// full text.
fn expectIrreversible(source: []const u8, op: []const u8, message: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostic = .{};
    const migration = try mig.parseMigration(arena, source, &diag);
    try testing.expectError(error.Irreversible, reverse.plan(arena, migration, &diag));
    try testing.expectEqualStrings(message, diag.message);
    const start = std.mem.indexOf(u8, source, op).?;
    try testing.expectEqual(mig.token.Span{ .start = @intCast(start), .end = @intCast(start + op.len) }, diag.span);
}

test "create_table and drop_table with columns invert each other" {
    try expectPlan(
        \\migration M { change {
        \\  create_table :users, id: :uuid { string :name, null: false }
        \\  drop_table :posts { text :body }
        \\} }
    ,
        \\migration M
        \\  up
        \\    create_table users id=uuid
        \\      column name string not_null
        \\    drop_table posts id=bigint
        \\      column body text null
        \\  down
        \\    create_table posts id=bigint
        \\      column body text null
        \\    drop_table users id=uuid
        \\      column name string not_null
        \\
    );
}

test "add_column and typed remove_column invert each other" {
    try expectPlan(
        \\migration M { change {
        \\  add_column :users, :role, :integer, null: false, default: 0
        \\  remove_column :users, :bio, :string, limit: 80
        \\} }
    ,
        \\migration M
        \\  up
        \\    add_column users
        \\      column role integer not_null default=0
        \\    remove_column users bio
        \\      column bio string null limit=80
        \\  down
        \\    add_column users
        \\      column bio string null limit=80
        \\    remove_column users role
        \\      column role integer not_null default=0
        \\
    );
}

test "rename_column swaps its names" {
    try expectPlan(
        \\migration M { change { rename_column :users, :login, :username } }
    ,
        \\migration M
        \\  up
        \\    rename_column users login username
        \\  down
        \\    rename_column users username login
        \\
    );
}

test "alter operations invert each other" {
    try expectPlan(
        \\migration M { change {
        \\  rename_table :posts, :articles
        \\  change_column :users, :name, :string, limit: 255, from: :string, from_limit: 100
        \\  change_column_null :users, :role, false, default: 0
        \\  change_column_null :users, :bio, true
        \\  change_column_default :users, :role, from: nil, to: :now
        \\  rename_index :users, "a", "b"
        \\  add_foreign_key :posts, :users, column: :author_id, on_delete: :cascade, name: "fk"
        \\  remove_foreign_key :posts, :users, column: :editor_id
        \\} }
    ,
        \\migration M
        \\  up
        \\    rename_table posts articles
        \\    change_column users name string limit=255 from=string from_limit=100
        \\    change_column_null users role not_null default=0
        \\    change_column_null users bio null
        \\    change_column_default users role from=nil to=:now
        \\    rename_index users "a" "b"
        \\    add_foreign_key posts users column=author_id on_delete=cascade name="fk"
        \\    remove_foreign_key posts users column=editor_id
        \\  down
        \\    add_foreign_key posts users column=editor_id
        \\    remove_foreign_key posts users column=author_id on_delete=cascade name="fk"
        \\    rename_index users "b" "a"
        \\    change_column_default users role from=:now to=nil
        \\    change_column_null users bio not_null
        \\    change_column_null users role null
        \\    change_column users name string limit=100 from=string from_limit=255
        \\    rename_table articles posts
        \\
    );
}

test "the plan keeps transaction: false" {
    try expectPlan(
        \\migration M, transaction: false { change { rename_column :users, :login, :username } }
    ,
        \\migration M transaction=false
        \\  up
        \\    rename_column users login username
        \\  down
        \\    rename_column users username login
        \\
    );
}

test "add_index and remove_index with a column invert each other exactly" {
    try expectPlan(
        \\migration M { change {
        \\  add_index :users, :email, unique: true, name: "by_email"
        \\  remove_index :users, :role
        \\  remove_index :posts, :slug, unique: true
        \\} }
    ,
        \\migration M
        \\  up
        \\    add_index users email unique name="by_email"
        \\    remove_index users role
        \\    remove_index posts slug unique
        \\  down
        \\    add_index posts slug unique
        \\    add_index users role
        \\    remove_index users email unique name="by_email"
        \\
    );
}

test "down undoes operations in reverse order" {
    try expectPlan(
        \\migration M { change {
        \\  create_table :a { string :c }
        \\  add_index :a, :c
        \\} }
    ,
        \\migration M
        \\  up
        \\    create_table a id=bigint
        \\      column c string null
        \\    add_index a c
        \\  down
        \\    remove_index a c
        \\    drop_table a id=bigint
        \\      column c string null
        \\
    );
}

test "irreversible operations report their span" {
    try expectIrreversible(
        "migration M { change { add_column :t, :c, :text\n  drop_table :users } }",
        "drop_table :users",
        "drop_table without a column block is irreversible",
    );
    try expectIrreversible(
        "migration M { change { remove_column :users, :bio } }",
        "remove_column :users, :bio",
        "remove_column without a type is irreversible",
    );
    try expectIrreversible(
        "migration M { change { remove_index :users, name: \"by_email\" } }",
        "remove_index :users, name: \"by_email\"",
        "remove_index without a column is irreversible",
    );
    try expectIrreversible(
        "migration M { change { change_column :users, :bio, :text } }",
        "change_column :users, :bio, :text",
        "change_column without 'from:' is irreversible",
    );
    try expectIrreversible(
        "migration M { change { change_column_default :users, :role, to: 1 } }",
        "change_column_default :users, :role, to: 1",
        "change_column_default without 'from:' is irreversible",
    );
    try expectIrreversible(
        "migration M { change { remove_foreign_key :posts, name: \"fk\" } }",
        "remove_foreign_key :posts, name: \"fk\"",
        "remove_foreign_key without :to_table or 'column:' is irreversible",
    );
    try expectIrreversible(
        "migration M { change { remove_foreign_key :posts, column: :user_id } }",
        "remove_foreign_key :posts, column: :user_id",
        "remove_foreign_key without :to_table or 'column:' is irreversible",
    );
}

test "up_down passes through untouched, including irreversible operations" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostic = .{};
    const migration = try mig.parseMigration(arena,
        \\migration M {
        \\  up { drop_table :users }
        \\  down { remove_column :users, :bio }
        \\}
    , &diag);
    const p = try reverse.plan(arena, migration, &diag);
    try testing.expectEqual(migration.body.up_down.up.ptr, p.up.ptr);
    try testing.expectEqual(migration.body.up_down.down.ptr, p.down.ptr);
}

test "execute is never inverted" {
    // Lowering rejects it in `change`; a hand-built one is irreversible.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var ops = [_]ast.Operation{.{ .span = .{ .start = 1, .end = 2 }, .kind = .{ .execute = .{ .sql = "SELECT 1" } } }};
    const migration: ast.Migration = .{ .name = "M", .body = .{ .change = &ops } };
    var diag: Diagnostic = .{};
    try testing.expectError(error.Irreversible, reverse.plan(arena_state.allocator(), migration, &diag));
    try testing.expectEqualStrings("execute is irreversible", diag.message);
}

test "reversing down gives back up" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostic = .{};
    const migration = try mig.parseMigration(arena,
        \\migration M { change {
        \\  create_table :users, id: :uuid { string :email, null: false, limit: 255
        \\    timestamps }
        \\  drop_table :legacy, id: false { json :data, default: "{}" }
        \\  add_column :users, :balance, :decimal, precision: 10, scale: 2
        \\  remove_column :users, :seen_at, :datetime, default: :now
        \\  rename_column :users, :login, :username
        \\  add_index :users, :email, unique: true
        \\  remove_index :users, :username, name: "by_username"
        \\  rename_table :posts, :articles
        \\  change_column :users, :age, :bigint, from: :integer
        \\  change_column_null :users, :email, false
        \\  change_column_default :users, :role, from: 0, to: "admin"
        \\  rename_index :users, "a", "b"
        \\  add_foreign_key :articles, :users, column: :author_id, on_delete: :restrict
        \\  remove_foreign_key :articles, :users, column: :editor_id, name: "by_editor"
        \\} }
    , &diag);
    const p = try reverse.plan(arena, migration, &diag);

    const reversed: ast.Migration = .{ .name = migration.name, .body = .{ .change = try arena.dupe(ast.Operation, p.down) } };
    const again = try reverse.plan(arena, reversed, &diag);
    try testing.expectEqualDeep(p.up, again.down);
}
