const std = @import("std");
const Writer = std.Io.Writer;
const ffmig = @import("ffmig");
const mig = ffmig.mig;
const sql = ffmig.sql;
const ast = mig.ast;
const Diagnostic = mig.Diagnostic;

const testing = std.testing;

/// Parses the `change` migration `source` and writes its SQL for `dialect`.
fn expectSql(dialect: sql.Dialect, source: []const u8, expected: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostic = .{};
    const migration = try mig.parseMigration(arena, source, &diag);

    var actual: Writer.Allocating = .init(arena);
    try sql.write(dialect, migration.body.change, &actual.writer);
    try testing.expectEqualStrings(expected, actual.written());
}

test "postgres quotes every identifier, including reserved words" {
    try expectSql(.postgres,
        \\migration M { change {
        \\  add_column :select, :from, :string
        \\  rename_column :select, :from, :to
        \\  add_index :select, :to, name: "a\"b"
        \\  remove_index :select, name: "a\"b"
        \\} }
    ,
        \\ALTER TABLE "select" ADD COLUMN "from" varchar;
        \\ALTER TABLE "select" RENAME COLUMN "from" TO "to";
        \\CREATE INDEX "a""b" ON "select" ("to");
        \\DROP INDEX "a""b";
        \\
    );
}

test "postgres doubles quotes in identifiers and default index names" {
    const op: ast.Operation = .{ .span = .{ .start = 0, .end = 0 }, .kind = .{
        .add_index = .{ .table = "we\"ird", .column = "\"", .unique = true },
    } };
    var actual: Writer.Allocating = .init(testing.allocator);
    defer actual.deinit();
    try sql.write(.postgres, &.{op}, &actual.writer);
    try testing.expectEqualStrings(
        \\CREATE UNIQUE INDEX "index_we""ird_on_""" ON "we""ird" ("""");
        \\
    , actual.written());
}

test "postgres escapes string literals by doubling single quotes" {
    try expectSql(
        .postgres,
        \\migration M { change {
        \\  add_column :users, :bio, :text, default: "it's a \"b\\c\"\n"
        \\} }
    ,
        "ALTER TABLE \"users\" ADD COLUMN \"bio\" text DEFAULT 'it''s a \"b\\c\"\n';\n",
    );
}

test "postgres writes an empty table without id as ()" {
    try expectSql(.postgres, "migration M { change { create_table :t, id: false { } } }",
        \\CREATE TABLE "t" ();
        \\
    );
}

test "postgres rename_table escapes the names in its DO block" {
    // Lowering only makes identifier-like names; a hand-built one still
    // reads back as the same name.
    const op: ast.Operation = .{ .span = .{ .start = 0, .end = 0 }, .kind = .{
        .rename_table = .{ .from = "it's", .to = "a\"b" },
    } };
    var actual: Writer.Allocating = .init(testing.allocator);
    defer actual.deinit();
    try sql.write(.postgres, &.{op}, &actual.writer);
    const out = actual.written();
    try testing.expect(std.mem.startsWith(u8, out, "ALTER TABLE \"it's\" RENAME TO \"a\"\"b\";\nDO $$\n"));
    try testing.expect(std.mem.endsWith(u8, out, "\n$$;\n"));
    for ([_][]const u8{
        "quote_ident('a\"b')::regclass",
        "'index_a\"b_on_' || substr(c.relname, char_length('index_it''s_on_') + 1)",
        "c.relname = 'it''s_pkey'",
        "starts_with(conname, 'fk_it''s_on_')",
        "s.relname = 'it''s_id_seq'",
    }) |part| {
        errdefer std.debug.print("missing: {s}\n", .{part});
        try testing.expect(std.mem.indexOf(u8, out, part) != null);
    }
}

test "execute runs on every dialect unless it names one" {
    const span: mig.token.Span = .{ .start = 0, .end = 0 };
    inline for (comptime std.enums.values(sql.Dialect)) |dialect| {
        const any: ast.Operation = .{ .span = span, .kind = .{ .execute = .{ .sql = "SELECT 1" } } };
        try testing.expectEqual(null, sql.unsupported(dialect, any));
    }
    const only: ast.Operation = .{ .span = span, .kind = .{ .execute = .{ .sql = "SELECT 1", .dialect = .postgres } } };
    try testing.expectEqual(null, sql.unsupported(.postgres, only));
    const other: ast.Operation = .{ .span = span, .kind = .{ .drop_table = .{ .table = "t", .columns = null } } };
    try testing.expectEqual(null, sql.unsupported(.postgres, other));
}

test "capabilities" {
    try testing.expect(sql.capabilities(.postgres).transactional_ddl);
    try testing.expect(sql.capabilities(.postgres).advisory_lock);
}

test "postgres lock statements" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try sql.writeLock(.postgres, .try_lock, &out.writer);
    try out.writer.writeAll(";\n");
    try sql.writeLock(.postgres, .unlock, &out.writer);
    // The key is "ffmig" in ASCII.
    try testing.expectEqualStrings(
        \\SELECT 1 WHERE pg_try_advisory_lock(439805110631);
        \\SELECT pg_advisory_unlock(439805110631)
    , out.written());
}

test "postgres timeout statements" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try sql.writeTimeout(.postgres, .{ .lock = 5000 }, &out.writer);
    try out.writer.writeAll(";\n");
    try sql.writeTimeout(.postgres, .{ .statement = 0 }, &out.writer);
    try testing.expectEqualStrings(
        \\SET lock_timeout = '5000ms';
        \\SET statement_timeout = '0ms'
    , out.written());
}

/// Golden cases: each `<case>.mig` has a `<case>.<dialect>.sql` per
/// dialect with the SQL for its `up` plan, then for its `down` plan (or
/// the reason it has none). Read at test time from the project root.
fn expectTracking(t: sql.Tracking, expected: []const u8) !void {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try sql.writeTracking(.postgres, t, &out.writer);
    try testing.expectEqualStrings(expected, out.written());
}

test "postgres tracking table statements" {
    try expectTracking(.create,
        \\CREATE TABLE IF NOT EXISTS "schema_migrations" ("version" varchar PRIMARY KEY, "checksum" varchar, "applied_at" timestamptz DEFAULT CURRENT_TIMESTAMP)
    );
    try expectTracking(.current,
        \\SELECT 1 FROM pg_attribute WHERE attrelid = to_regclass('schema_migrations') AND NOT attisdropped AND attname IN ('checksum', 'applied_at') HAVING count(*) = 2
    );
    try expectTracking(.upgrade,
        \\ALTER TABLE "schema_migrations" ADD COLUMN IF NOT EXISTS "checksum" varchar, ADD COLUMN IF NOT EXISTS "applied_at" timestamptz, ALTER COLUMN "applied_at" SET DEFAULT CURRENT_TIMESTAMP
    );
    try expectTracking(.select,
        \\SELECT "version", "checksum", floor(extract(epoch FROM "applied_at"))::bigint FROM "schema_migrations" ORDER BY "version"
    );
    try expectTracking(.{ .insert = .{ .version = "20260923140512", .checksum = "ab12" } },
        \\INSERT INTO "schema_migrations" ("version", "checksum") VALUES ('20260923140512', 'ab12')
    );
    try expectTracking(.{ .delete = "it's" }, "DELETE FROM \"schema_migrations\" WHERE \"version\" = 'it''s'");
}

const golden_dir = "tests/sql";

test "golden cases in tests/sql" {
    const io = testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, golden_dir, .{ .iterate = true });
    defer dir.close(io);

    var cases: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".mig")) continue;
        inline for (comptime std.enums.values(sql.Dialect)) |dialect| {
            errdefer std.debug.print("golden case: {s}/{s} ({t})\n", .{ golden_dir, entry.name, dialect });
            try expectGolden(dir, entry.name, dialect);
        }
        cases += 1;
    }
    try testing.expect(cases > 0);
}

fn expectGolden(dir: std.Io.Dir, mig_name: []const u8, dialect: sql.Dialect) !void {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source = try dir.readFileAlloc(io, mig_name, arena, .unlimited);
    var diag: Diagnostic = .{};
    const migration = try mig.parseMigration(arena, source, &diag);

    var actual: Writer.Allocating = .init(arena);
    const w = &actual.writer;
    try w.writeAll("-- up\n");
    try sql.write(dialect, switch (migration.body) {
        .change => |ops| ops,
        .up_down => |b| b.up,
    }, w);
    try w.writeAll("-- down\n");
    if (mig.reverse.plan(arena, migration, &diag)) |p| {
        try sql.write(dialect, p.down, w);
    } else |err| switch (err) {
        error.Irreversible => try w.print("-- {s}\n", .{diag.message}),
        error.OutOfMemory => return err,
    }

    const stem = mig_name[0 .. mig_name.len - ".mig".len];
    const expected_name = try std.fmt.allocPrint(arena, "{s}.{t}.sql", .{ stem, dialect });
    const expected = dir.readFileAlloc(io, expected_name, arena, .unlimited) catch |err| {
        std.debug.print("cannot read {s}/{s}: {t}; actual output:\n{s}", .{ golden_dir, expected_name, err, actual.written() });
        return err;
    };
    try testing.expectEqualStrings(expected, actual.written());
}

fn expectDatabase(d: sql.Database, expected: []const u8) !void {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try sql.writeDatabase(.postgres, d, &out.writer);
    try testing.expectEqualStrings(expected, out.written());
}

test "postgres database statements" {
    try expectDatabase(.{ .create = "app_dev" }, "CREATE DATABASE \"app_dev\"");
    try expectDatabase(.{ .drop = "my\"db" }, "DROP DATABASE \"my\"\"db\"");
    try expectDatabase(.{ .exists = "it's" }, "SELECT 1 FROM pg_database WHERE datname = 'it''s'");
    try expectDatabase(.{ .protect = "app" }, "ALTER DATABASE \"app\" SET ffmig.protected = on");
    try expectDatabase(.{ .unprotect = "app" }, "ALTER DATABASE \"app\" RESET ffmig.protected");
    try expectDatabase(.{ .protected = "it's" },
        \\SELECT 1 FROM pg_db_role_setting s JOIN pg_database d ON d.oid = s.setdatabase
        \\WHERE s.setrole = 0 AND 'ffmig.protected=on' = ANY (s.setconfig) AND d.datname = 'it''s'
    );
}
