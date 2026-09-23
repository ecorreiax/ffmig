const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;
const ffmig = @import("ffmig");
const Env = ffmig.commands.Env;
const sql = ffmig.commands.sql;

const testing = std.testing;

const Result = struct {
    code: u8,
    out: Writer.Allocating,
    err: Writer.Allocating,

    fn deinit(r: *Result) void {
        r.out.deinit();
        r.err.deinit();
    }
};

fn sqlIn(dir: Io.Dir, args: []const []const u8) !Result {
    var r: Result = .{
        .code = undefined,
        .out = .init(testing.allocator),
        .err = .init(testing.allocator),
    };
    const env: Env = .{ .io = testing.io, .cwd = dir, .gpa = testing.allocator };
    r.code = try sql.run(env, args, &r.out.writer, &r.err.writer);
    return r;
}

const add_role =
    \\migration AddRole {
    \\  change {
    \\    add_column :users, :role, :integer, null: false, default: 0
    \\    add_index :users, :role
    \\  }
    \\}
    \\
;

test "sql prints the up plan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.mig", .data = add_role });

    var r = try sqlIn(tmp.dir, &.{"a.mig"});
    defer r.deinit();
    try testing.expectEqual(0, r.code);
    try testing.expectEqualStrings(
        \\ALTER TABLE "users" ADD COLUMN "role" integer DEFAULT 0 NOT NULL;
        \\CREATE INDEX "index_users_on_role" ON "users" ("role");
        \\
    , r.out.written());
    try testing.expectEqualStrings("", r.err.written());
}

test "sql --down prints the derived down plan" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.mig", .data = add_role });

    var r = try sqlIn(tmp.dir, &.{ "a.mig", "--down" });
    defer r.deinit();
    try testing.expectEqual(0, r.code);
    try testing.expectEqualStrings(
        \\DROP INDEX "index_users_on_role";
        \\ALTER TABLE "users" DROP COLUMN "role";
        \\
    , r.out.written());
}

test "sql --down fails on an irreversible change" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.mig", .data = "migration M { change { drop_table :users } }\n" });

    var r = try sqlIn(tmp.dir, &.{ "--down", "a.mig" });
    defer r.deinit();
    try testing.expectEqual(1, r.code);
    try testing.expectEqualStrings("", r.out.written());
    try testing.expectEqualStrings(
        \\a.mig:1:24: drop_table without a column block is irreversible; use 'up' / 'down' blocks to make it reversible
        \\migration M { change { drop_table :users } }
        \\                       ^~~~~~~~~~~~~~~~~
        \\
    , r.err.written());
}

test "sql reports parse errors like check" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.mig", .data = "migration M { change { add_idx :t, :c } }\n" });

    var r = try sqlIn(tmp.dir, &.{"a.mig"});
    defer r.deinit();
    try testing.expectEqual(1, r.code);
    try testing.expectEqualStrings(
        \\a.mig:1:24: unknown operation 'add_idx'
        \\migration M { change { add_idx :t, :c } }
        \\                       ^~~~~~~
        \\
    , r.err.written());
}

test "sql needs exactly one file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    inline for (.{ &.{}, &.{ "a.mig", "b.mig" }, &.{ "--nope", "a.mig" } }) |args| {
        var r = try sqlIn(tmp.dir, args);
        defer r.deinit();
        try testing.expectEqual(1, r.code);
        try testing.expectEqualStrings(sql.usage, r.err.written());
    }

    var r = try sqlIn(tmp.dir, &.{"missing.mig"});
    defer r.deinit();
    try testing.expectEqual(1, r.code);
    try testing.expectEqualStrings("ffmig: cannot read missing.mig: FileNotFound\n", r.err.written());
}
