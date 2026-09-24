//! `migrate`, `rollback` and `status` against a fake database that records
//! every statement.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const ffmig = @import("ffmig");
const commands = ffmig.commands;
const migrations = commands.migrations;
const config = ffmig.config;
const db = ffmig.db;
const Env = commands.Env;

const testing = std.testing;

/// Returns `applied` for the version query and logs every other statement.
/// Fails every statement that contains one of `fail_on`. The migration
/// lock is free unless `busy` is set, which refuses that many attempts to
/// take it.
const FakeDb = struct {
    applied: []const []const u8 = &.{},
    /// The checksums of `applied`, in the same order; null past its end.
    checksums: []const ?[]const u8 = &.{},
    /// `applied_at` of every row, in seconds.
    applied_at: ?[]const u8 = "1767225600",
    /// Whether the tracking table lacks `checksum` and `applied_at`.
    old_table: bool = false,
    fail_on: []const []const u8 = &.{},
    busy: usize = 0,
    log: Writer.Allocating,

    fn init(applied: []const []const u8) FakeDb {
        return .{ .applied = applied, .log = .init(testing.allocator) };
    }

    fn deinit(f: *FakeDb) void {
        f.log.deinit();
    }

    fn connection(f: *FakeDb) migrations.Connection {
        return .{ .db = .{ .ptr = f, .vtable = &vtable }, .dialect = .postgres };
    }

    const vtable: db.Db.VTable = .{ .exec = exec, .query = query, .server = server, .close = close };

    fn exec(ptr: *anyopaque, statement: []const u8, diag: *db.Diagnostic) db.Error!void {
        const f: *FakeDb = @ptrCast(@alignCast(ptr));
        for (f.fail_on) |s| if (std.mem.indexOf(u8, statement, s) != null) {
            diag.message = if (std.mem.eql(u8, statement, "ROLLBACK")) "no connection to the server" else "boom";
            return error.DatabaseError;
        };
        f.log.writer.print("{s};\n", .{statement}) catch return error.OutOfMemory;
    }

    fn query(ptr: *anyopaque, arena: Allocator, statement: []const u8, _: *db.Diagnostic) db.Error![]const db.Row {
        const f: *FakeDb = @ptrCast(@alignCast(ptr));
        std.debug.assert(std.mem.startsWith(u8, statement, "SELECT"));
        const one: []const db.Row = &.{&.{"1"}};
        if (std.mem.indexOf(u8, statement, "pg_try_advisory_lock") != null) {
            f.log.writer.print("{s};\n", .{statement}) catch return error.OutOfMemory;
            if (f.busy == 0) return one;
            f.busy -= 1;
            return &.{};
        }
        if (std.mem.indexOf(u8, statement, "pg_attribute") != null) return if (f.old_table) &.{} else one;
        const rows = try arena.alloc(db.Row, f.applied.len);
        for (rows, f.applied, 0..) |*row, version, i| {
            const sum = if (i < f.checksums.len) f.checksums[i] else null;
            row.* = try arena.dupe(?[]const u8, &.{ version, sum, f.applied_at });
        }
        return rows;
    }

    fn server(_: *anyopaque) db.Db.Server {
        return .{ .host = "localhost", .port = "5432" };
    }

    fn close(_: *anyopaque) void {}
};

const Result = struct {
    code: u8,
    out: Writer.Allocating,
    err: Writer.Allocating,

    fn deinit(r: *Result) void {
        r.out.deinit();
        r.err.deinit();
    }
};

const Command = union(enum) {
    migrate: commands.migrate.Options,
    rollback: commands.rollback.Options,
    status,
};

/// Runs `command` in `dir` with `fake` in place of a connection.
fn runIn(dir: Io.Dir, fake: *FakeDb, command: Command) !Result {
    var r: Result = .{ .code = undefined, .out = .init(testing.allocator), .err = .init(testing.allocator) };
    errdefer r.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const env: Env = .{ .io = testing.io, .cwd = dir, .gpa = testing.allocator };
    var project = (try migrations.Project.load(env, arena, &r.err.writer)).?;
    defer project.close(testing.io);
    const conn = fake.connection();
    const out = &r.out.writer;
    const err = &r.err.writer;
    r.code = switch (command) {
        .migrate => |o| try commands.migrate.migrate(env, arena, project, conn, o, out, err),
        .rollback => |o| try commands.rollback.rollback(env, arena, project, conn, o, out, err),
        .status => try commands.status.status(testing.io, arena, project, conn, out, err),
    };
    return r;
}

fn setup(files: []const [2][]const u8) !testing.TmpDir {
    return setupWith("", files);
}

/// `setup` with `extra` added to the `[migration]` section.
fn setupWith(extra: []const u8, files: []const [2][]const u8) !testing.TmpDir {
    var tmp = testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const cfg = try std.mem.concat(testing.allocator, u8, &.{ "[migration]\npath = \"db\"\n", extra });
    defer testing.allocator.free(cfg);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = config.file_name, .data = cfg });
    try tmp.dir.createDirPath(testing.io, "db");
    for (files) |f| {
        const path = try std.fs.path.join(testing.allocator, &.{ "db", f[0] });
        defer testing.allocator.free(path);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = f[1] });
    }
    return tmp;
}

const create_users = [2][]const u8{
    "20260101000000_create_users.mig",
    \\migration CreateUsers {
    \\  change {
    \\    create_table :users {
    \\      string :email, null: false
    \\    }
    \\  }
    \\}
    \\
};

const add_role = [2][]const u8{
    "20260102000000_add_role.mig",
    \\migration AddRole {
    \\  change {
    \\    add_column :users, :role, :integer
    \\    add_index :users, :role
    \\  }
    \\}
    \\
};

const drop_legacy = [2][]const u8{
    "20260103000000_drop_legacy.mig",
    \\migration DropLegacy {
    \\  up {
    \\    drop_table :legacy
    \\  }
    \\  down {
    \\    create_table :legacy, id: false {
    \\      text :data
    \\    }
    \\  }
    \\}
    \\
};

const lock = "SELECT 1 WHERE pg_try_advisory_lock(439805110631);\n";
const unlock = "SELECT pg_advisory_unlock(439805110631);\n";
const tracking_create = "CREATE TABLE IF NOT EXISTS \"schema_migrations\" (\"version\" varchar PRIMARY KEY, \"checksum\" varchar, \"applied_at\" timestamptz DEFAULT CURRENT_TIMESTAMP);\n";

// `shasum -a 256` of the files above.
const create_users_sum = "55c09ebe26609cd2d89d7efb64e9611ac8e043cb52d4404c156a5ea6160fad28";
const add_role_sum = "91ad7ffee54b6319dd2d0a72873756fe80e1aedde38889bb24d9ad7b5e406c73";
const drop_legacy_sum = "7455cbe88c5d070cf90326d7f632eaf3ef28f64cdafb9657d84a41f278db0fb0";
const add_slug_sum = "d6ebe881d31d1ae849cd89b6e2fd4812326d2c01ae6cbc17adf8cc9b4166266d";

test "pending keeps unrecorded files in order" {
    const files = [_]migrations.File{
        .{ .name = "a", .version = "20260101000000" },
        .{ .name = "b", .version = "20260102000000" },
        .{ .name = "c", .version = "20260103000000" },
    };
    const cases = [_]struct { applied: []const []const u8, expected: []const u8 }{
        .{ .applied = &.{}, .expected = "abc" },
        .{ .applied = &.{"20260102000000"}, .expected = "ac" },
        .{ .applied = &.{ "20260101000000", "20260102000000", "20260103000000" }, .expected = "" },
        // Recorded versions without a file are ignored.
        .{ .applied = &.{ "20250101000000", "20260101000000", "20270101000000" }, .expected = "bc" },
    };
    for (cases) |c| {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const applied = try arena_state.allocator().alloc(migrations.Applied, c.applied.len);
        for (applied, c.applied) |*a, v| a.* = .{ .version = v, .checksum = null, .applied_at = null };
        const pending = try migrations.pending(arena_state.allocator(), &files, applied);
        var names: [3]u8 = undefined;
        for (pending, 0..) |f, i| names[i] = f.name[0];
        try testing.expectEqualStrings(c.expected, names[0..pending.len]);
    }
}

test "migrate runs each pending migration in its own transaction" {
    var tmp = try setup(&.{ create_users, add_role, drop_legacy });
    defer tmp.cleanup();
    var fake: FakeDb = .init(&.{"20260101000000"});
    defer fake.deinit();

    var r = try runIn(tmp.dir, &fake, .{ .migrate = .{} });
    defer r.deinit();
    try testing.expectEqualStrings("", r.err.written());
    try testing.expectEqual(0, r.code);
    try testing.expectEqualStrings(
        \\Migrated db/20260102000000_add_role.mig
        \\Migrated db/20260103000000_drop_legacy.mig
        \\
    , r.out.written());
    try testing.expectEqualStrings(lock ++ tracking_create ++
        \\BEGIN;
        \\ALTER TABLE "users" ADD COLUMN "role" integer;
        \\CREATE INDEX "index_users_on_role" ON "users" ("role");
        \\INSERT INTO "schema_migrations" ("version", "checksum") VALUES ('20260102000000', '
    ++ add_role_sum ++
        \\');
        \\COMMIT;
        \\BEGIN;
        \\DROP TABLE "legacy";
        \\INSERT INTO "schema_migrations" ("version", "checksum") VALUES ('20260103000000', '
    ++ drop_legacy_sum ++
        \\');
        \\COMMIT;
        \\
    ++ unlock, fake.log.written());
}

test "migrate with nothing pending" {
    var tmp = try setup(&.{create_users});
    defer tmp.cleanup();
    var fake: FakeDb = .init(&.{"20260101000000"});
    defer fake.deinit();

    var r = try runIn(tmp.dir, &fake, .{ .migrate = .{} });
    defer r.deinit();
    try testing.expectEqual(0, r.code);
    try testing.expectEqualStrings("Nothing to migrate\n", r.out.written());
    try testing.expectEqualStrings(lock ++ tracking_create ++ unlock, fake.log.written());
}

test "migrate waits for another run to release the lock" {
    var tmp = try setup(&.{create_users});
    defer tmp.cleanup();
    var fake: FakeDb = .init(&.{"20260101000000"});
    defer fake.deinit();
    fake.busy = 1;

    var r = try runIn(tmp.dir, &fake, .{ .migrate = .{ .lock_wait = 5 } });
    defer r.deinit();
    try testing.expectEqual(0, r.code);
    try testing.expectEqualStrings("Waiting for another ffmig run to finish...\n", r.err.written());
    try testing.expectEqualStrings("Nothing to migrate\n", r.out.written());
    try testing.expectEqualStrings(lock ++ lock ++ tracking_create ++ unlock, fake.log.written());
}

test "migrate and rollback give up when the lock stays taken" {
    var tmp = try setup(&.{create_users});
    defer tmp.cleanup();
    const cases = .{
        .{ Command{ .migrate = .{ .lock_wait = 0 } }, "ffmig: nothing was migrated\n" },
        .{ Command{ .rollback = .{ .lock_wait = 0 } }, "ffmig: nothing was rolled back\n" },
    };
    inline for (cases) |c| {
        var fake: FakeDb = .init(&.{});
        defer fake.deinit();
        fake.busy = 1;

        var r = try runIn(tmp.dir, &fake, c[0]);
        defer r.deinit();
        try testing.expectEqual(1, r.code);
        try testing.expectEqualStrings("", r.out.written());
        try testing.expectEqualStrings("ffmig: another ffmig run holds the lock on this database; gave up after 0s (see --lock-wait)\n" ++ c[1], r.err.written());
        // Nothing read or run, and nothing to release.
        try testing.expectEqualStrings(lock, fake.log.written());
    }
}

test "migrate checks every pending file before running any" {
    const broken = [2][]const u8{ "20260104000000_broken.mig", "migration Broken { change { add_idx :t, :c } }\n" };
    const also_broken = [2][]const u8{ "20260105000000_also_broken.mig", "migration AlsoBroken {\n" };
    var tmp = try setup(&.{ create_users, broken, add_role, also_broken });
    defer tmp.cleanup();
    var fake: FakeDb = .init(&.{});
    defer fake.deinit();

    var r = try runIn(tmp.dir, &fake, .{ .migrate = .{} });
    defer r.deinit();
    try testing.expectEqual(1, r.code);
    try testing.expectEqualStrings("", r.out.written());
    try testing.expectEqualStrings(
        \\db/20260104000000_broken.mig:1:29: unknown operation 'add_idx'
        \\migration Broken { change { add_idx :t, :c } }
        \\                            ^~~~~~~
        \\db/20260105000000_also_broken.mig:2:1: expected 'change', 'up' or 'down', found end of file
        \\
        \\^
        \\ffmig: nothing was migrated
        \\
    , r.err.written());
    try testing.expectEqualStrings(lock ++ tracking_create ++ unlock, fake.log.written());
}

test "migrate stops at a failing statement and rolls its migration back" {
    var tmp = try setup(&.{ create_users, add_role, drop_legacy });
    defer tmp.cleanup();
    var fake: FakeDb = .init(&.{});
    defer fake.deinit();
    fake.fail_on = &.{"CREATE INDEX"};

    var r = try runIn(tmp.dir, &fake, .{ .migrate = .{} });
    defer r.deinit();
    try testing.expectEqual(1, r.code);
    try testing.expectEqualStrings("Migrated db/20260101000000_create_users.mig\n", r.out.written());
    try testing.expectEqualStrings(
        \\ffmig: db/20260102000000_add_role.mig: boom
        \\while running:
        \\CREATE INDEX "index_users_on_role" ON "users" ("role");
        \\
    , r.err.written());
    try testing.expectEqualStrings(lock ++ tracking_create ++
        \\BEGIN;
        \\CREATE TABLE "users" (
        \\  "id" bigserial PRIMARY KEY,
        \\  "email" varchar NOT NULL
        \\);
        \\INSERT INTO "schema_migrations" ("version", "checksum") VALUES ('20260101000000', '
    ++ create_users_sum ++
        \\');
        \\COMMIT;
        \\BEGIN;
        \\ALTER TABLE "users" ADD COLUMN "role" integer;
        \\ROLLBACK;
        \\
    ++ unlock, fake.log.written());
}

test "a failed rollback is reported after the error" {
    var tmp = try setup(&.{ create_users, add_role });
    defer tmp.cleanup();
    var fake: FakeDb = .init(&.{"20260101000000"});
    defer fake.deinit();
    fake.fail_on = &.{ "CREATE INDEX", "ROLLBACK" };

    var r = try runIn(tmp.dir, &fake, .{ .migrate = .{} });
    defer r.deinit();
    try testing.expectEqual(1, r.code);
    try testing.expectEqualStrings("", r.out.written());
    try testing.expectEqualStrings(
        \\ffmig: db/20260102000000_add_role.mig: boom
        \\while running:
        \\CREATE INDEX "index_users_on_role" ON "users" ("role");
        \\ffmig: rollback failed: no connection to the server
        \\
    , r.err.written());
}

const add_slug = [2][]const u8{
    "20260104000000_add_slug.mig",
    \\migration AddSlug, transaction: false {
    \\  change {
    \\    add_column :users, :slug, :string
    \\    add_index :users, :slug, unique: true
    \\  }
    \\}
    \\
};

test "transaction: false runs the migration without BEGIN and COMMIT, both ways" {
    var tmp = try setup(&.{ create_users, add_slug });
    defer tmp.cleanup();
    var fake: FakeDb = .init(&.{"20260101000000"});
    defer fake.deinit();

    var r = try runIn(tmp.dir, &fake, .{ .migrate = .{} });
    defer r.deinit();
    try testing.expectEqualStrings("", r.err.written());
    try testing.expectEqual(0, r.code);
    try testing.expectEqualStrings(lock ++ tracking_create ++
        \\ALTER TABLE "users" ADD COLUMN "slug" varchar;
        \\CREATE UNIQUE INDEX "index_users_on_slug" ON "users" ("slug");
        \\INSERT INTO "schema_migrations" ("version", "checksum") VALUES ('20260104000000', '
    ++ add_slug_sum ++
        \\');
        \\
    ++ unlock, fake.log.written());

    var rollback_fake: FakeDb = .init(&.{ "20260101000000", "20260104000000" });
    defer rollback_fake.deinit();
    var rr = try runIn(tmp.dir, &rollback_fake, .{ .rollback = .{} });
    defer rr.deinit();
    try testing.expectEqual(0, rr.code);
    try testing.expectEqualStrings(lock ++ tracking_create ++
        \\DROP INDEX "index_users_on_slug";
        \\ALTER TABLE "users" DROP COLUMN "slug";
        \\DELETE FROM "schema_migrations" WHERE "version" = '20260104000000';
        \\
    ++ unlock, rollback_fake.log.written());
}

test "transaction: false says that a failure keeps the statements before it" {
    var tmp = try setup(&.{ create_users, add_slug });
    defer tmp.cleanup();
    var fake: FakeDb = .init(&.{"20260101000000"});
    defer fake.deinit();
    fake.fail_on = &.{"CREATE UNIQUE INDEX"};

    var r = try runIn(tmp.dir, &fake, .{ .migrate = .{} });
    defer r.deinit();
    try testing.expectEqual(1, r.code);
    try testing.expectEqualStrings(
        \\ffmig: db/20260104000000_add_slug.mig: boom
        \\while running:
        \\CREATE UNIQUE INDEX "index_users_on_slug" ON "users" ("slug");
        \\ffmig: db/20260104000000_add_slug.mig runs without a transaction, so the statements before this one were not undone
        \\
    , r.err.written());
    // No ROLLBACK, and no tracking row.
    try testing.expectEqualStrings(lock ++ tracking_create ++
        \\ALTER TABLE "users" ADD COLUMN "slug" varchar;
        \\
    ++ unlock, fake.log.written());

    // Failing on the first statement leaves nothing behind to mention.
    var first: FakeDb = .init(&.{"20260101000000"});
    defer first.deinit();
    first.fail_on = &.{"ADD COLUMN"};
    var rf = try runIn(tmp.dir, &first, .{ .migrate = .{} });
    defer rf.deinit();
    try testing.expectEqual(1, rf.code);
    try testing.expectEqualStrings(
        \\ffmig: db/20260104000000_add_slug.mig: boom
        \\while running:
        \\ALTER TABLE "users" ADD COLUMN "slug" varchar;
        \\
    , rf.err.written());
}

test "migrate and rollback set the configured timeouts before anything else" {
    var tmp = try setupWith("lock_timeout = \"5s\"\nstatement_timeout = \"0\"\n", &.{create_users});
    defer tmp.cleanup();
    const timeouts = "SET lock_timeout = '5000ms';\nSET statement_timeout = '0ms';\n";
    inline for (.{ Command{ .migrate = .{} }, Command{ .rollback = .{} } }) |command| {
        var fake: FakeDb = .init(&.{"20260101000000"});
        defer fake.deinit();
        var r = try runIn(tmp.dir, &fake, command);
        defer r.deinit();
        try testing.expectEqual(0, r.code);
        try testing.expect(std.mem.startsWith(u8, fake.log.written(), timeouts ++ lock));
    }

    // A timeout the server refuses stops the run.
    var fake: FakeDb = .init(&.{});
    defer fake.deinit();
    fake.fail_on = &.{"statement_timeout"};
    var r = try runIn(tmp.dir, &fake, .{ .migrate = .{} });
    defer r.deinit();
    try testing.expectEqual(1, r.code);
    try testing.expectEqualStrings(
        \\ffmig: cannot set statement_timeout: boom
        \\ffmig: nothing was migrated
        \\
    , r.err.written());
    try testing.expectEqualStrings("SET lock_timeout = '5000ms';\n", fake.log.written());
}

test "project load reports a timeout that is not a duration" {
    var tmp = try setupWith("lock_timeout = \"5\"\n", &.{});
    defer tmp.cleanup();
    var err: Writer.Allocating = .init(testing.allocator);
    defer err.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const env: Env = .{ .io = testing.io, .cwd = tmp.dir, .gpa = testing.allocator };
    try testing.expectEqual(null, try migrations.Project.load(env, arena_state.allocator(), &err.writer));
    try testing.expectEqualStrings(
        \\ffmig: ffmig.toml:3: lock_timeout must be a duration such as "5s" or "500ms", or "0" for no limit
        \\
    , err.written());
}

test "rollback undoes the newest migrations with their down plans" {
    var tmp = try setup(&.{ create_users, add_role, drop_legacy });
    defer tmp.cleanup();
    var fake: FakeDb = .init(&.{ "20260103000000", "20260101000000", "20260102000000" });
    defer fake.deinit();

    var r = try runIn(tmp.dir, &fake, .{ .rollback = .{ .step = 2 } });
    defer r.deinit();
    try testing.expectEqualStrings("", r.err.written());
    try testing.expectEqual(0, r.code);
    try testing.expectEqualStrings(
        \\Rolled back db/20260103000000_drop_legacy.mig
        \\Rolled back db/20260102000000_add_role.mig
        \\
    , r.out.written());
    try testing.expectEqualStrings(lock ++ tracking_create ++
        \\BEGIN;
        \\CREATE TABLE "legacy" (
        \\  "data" text
        \\);
        \\DELETE FROM "schema_migrations" WHERE "version" = '20260103000000';
        \\COMMIT;
        \\BEGIN;
        \\DROP INDEX "index_users_on_role";
        \\ALTER TABLE "users" DROP COLUMN "role";
        \\DELETE FROM "schema_migrations" WHERE "version" = '20260102000000';
        \\COMMIT;
        \\
    ++ unlock, fake.log.written());
}

test "rollback stops on an irreversible change before touching the database" {
    const drop_users = [2][]const u8{ "20260104000000_drop_users.mig", "migration DropUsers { change { drop_table :users } }\n" };
    var tmp = try setup(&.{ create_users, drop_users });
    defer tmp.cleanup();
    var fake: FakeDb = .init(&.{ "20260101000000", "20260104000000" });
    defer fake.deinit();

    var r = try runIn(tmp.dir, &fake, .{ .rollback = .{ .step = 5 } });
    defer r.deinit();
    try testing.expectEqual(1, r.code);
    try testing.expectEqualStrings("", r.out.written());
    try testing.expectEqualStrings(
        \\db/20260104000000_drop_users.mig:1:32: drop_table without a column block is irreversible; use 'up' / 'down' blocks to make it reversible
        \\migration DropUsers { change { drop_table :users } }
        \\                               ^~~~~~~~~~~~~~~~~
        \\ffmig: nothing was rolled back
        \\
    , r.err.written());
    try testing.expectEqualStrings(lock ++ tracking_create ++ unlock, fake.log.written());
}

test "rollback needs the file of each migration it undoes" {
    var tmp = try setup(&.{create_users});
    defer tmp.cleanup();
    var fake: FakeDb = .init(&.{ "20260101000000", "20260109000000" });
    defer fake.deinit();

    var r = try runIn(tmp.dir, &fake, .{ .rollback = .{ .step = 1 } });
    defer r.deinit();
    try testing.expectEqual(1, r.code);
    try testing.expectEqualStrings(
        \\ffmig: no file in db for applied migration 20260109000000
        \\ffmig: nothing was rolled back
        \\
    , r.err.written());
    try testing.expectEqualStrings(lock ++ tracking_create ++ unlock, fake.log.written());
}

test "rollback with nothing applied" {
    var tmp = try setup(&.{create_users});
    defer tmp.cleanup();
    var fake: FakeDb = .init(&.{});
    defer fake.deinit();

    var r = try runIn(tmp.dir, &fake, .{ .rollback = .{ .step = 1 } });
    defer r.deinit();
    try testing.expectEqual(0, r.code);
    try testing.expectEqualStrings("Nothing to roll back\n", r.out.written());
}

test "status lists files as up or down, and recorded versions without a file" {
    var tmp = try setup(&.{ create_users, add_role, drop_legacy });
    defer tmp.cleanup();
    var fake: FakeDb = .init(&.{ "20260102000000", "20260101000000", "20260109000000" });
    defer fake.deinit();
    fake.checksums = &.{ "0000", create_users_sum, "1111" };

    var r = try runIn(tmp.dir, &fake, .status);
    defer r.deinit();
    try testing.expectEqualStrings("", r.err.written());
    try testing.expectEqual(0, r.code);
    try testing.expectEqualStrings(
        \\up    2026-01-01 00:00:00 UTC  db/20260101000000_create_users.mig
        \\up    2026-01-01 00:00:00 UTC  db/20260102000000_add_role.mig (changed)
        \\down                           db/20260103000000_drop_legacy.mig
        \\up    2026-01-01 00:00:00 UTC  20260109000000 (no file)
        \\
    , r.out.written());
}

test "status upgrades a tracking table from before checksums" {
    var tmp = try setup(&.{ create_users, add_role });
    defer tmp.cleanup();
    var fake: FakeDb = .init(&.{"20260101000000"});
    defer fake.deinit();
    fake.old_table = true;
    fake.applied_at = null;

    var r = try runIn(tmp.dir, &fake, .status);
    defer r.deinit();
    try testing.expectEqual(0, r.code);
    // Neither a time nor a checksum to compare with.
    try testing.expectEqualStrings(
        \\up                             db/20260101000000_create_users.mig
        \\down                           db/20260102000000_add_role.mig
        \\
    , r.out.written());
    try testing.expectEqualStrings(tracking_create ++
        \\ALTER TABLE "schema_migrations" ADD COLUMN IF NOT EXISTS "checksum" varchar, ADD COLUMN IF NOT EXISTS "applied_at" timestamptz, ALTER COLUMN "applied_at" SET DEFAULT CURRENT_TIMESTAMP;
        \\
    , fake.log.written());
}

test "status does not flag a file checked out with CRLF line endings" {
    const crlf = try std.mem.replaceOwned(u8, testing.allocator, create_users[1], "\n", "\r\n");
    defer testing.allocator.free(crlf);
    var tmp = try setup(&.{.{ create_users[0], crlf }});
    defer tmp.cleanup();
    var fake: FakeDb = .init(&.{"20260101000000"});
    defer fake.deinit();
    fake.checksums = &.{create_users_sum};

    var r = try runIn(tmp.dir, &fake, .status);
    defer r.deinit();
    try testing.expectEqualStrings("up    2026-01-01 00:00:00 UTC  db/20260101000000_create_users.mig\n", r.out.written());
}

test "checksum is the SHA-256 of the source with CRLF read as LF" {
    try testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &migrations.checksum("abc"));
    try testing.expectEqualStrings(&migrations.checksum("a\nb\n"), &migrations.checksum("a\r\nb\r\n"));
    // A lone CR is content.
    try testing.expect(!std.mem.eql(u8, &migrations.checksum("a\nb"), &migrations.checksum("a\rb")));
    try testing.expect(!std.mem.eql(u8, &migrations.checksum("a\n"), &migrations.checksum("a\r\r\n")));
}

test "migrate warns about applied files that changed, and --strict refuses them" {
    var tmp = try setup(&.{ create_users, add_role, drop_legacy });
    defer tmp.cleanup();
    const warning = "db/20260101000000_create_users.mig has changed since it was applied; its changes will not run\n";

    var fake: FakeDb = .init(&.{ "20260101000000", "20260102000000" });
    defer fake.deinit();
    // add_role has no checksum to compare with.
    fake.checksums = &.{ "0000", null };
    var r = try runIn(tmp.dir, &fake, .{ .migrate = .{} });
    defer r.deinit();
    try testing.expectEqual(0, r.code);
    try testing.expectEqualStrings("ffmig: warning: " ++ warning, r.err.written());
    try testing.expectEqualStrings("Migrated db/20260103000000_drop_legacy.mig\n", r.out.written());

    var strict: FakeDb = .init(&.{ "20260101000000", "20260102000000" });
    defer strict.deinit();
    strict.checksums = &.{ "0000", null };
    var rs = try runIn(tmp.dir, &strict, .{ .migrate = .{ .strict = true } });
    defer rs.deinit();
    try testing.expectEqual(1, rs.code);
    try testing.expectEqualStrings("ffmig: " ++ warning ++ "ffmig: nothing was migrated\n", rs.err.written());
    try testing.expectEqualStrings("", rs.out.written());
    try testing.expectEqualStrings(lock ++ tracking_create ++ unlock, strict.log.written());

    // Unchanged files pass --strict.
    var clean: FakeDb = .init(&.{ "20260101000000", "20260102000000", "20260103000000" });
    defer clean.deinit();
    clean.checksums = &.{ create_users_sum, add_role_sum, drop_legacy_sum };
    var rc = try runIn(tmp.dir, &clean, .{ .migrate = .{ .strict = true } });
    defer rc.deinit();
    try testing.expectEqual(0, rc.code);
    try testing.expectEqualStrings("", rc.err.written());
    try testing.expectEqualStrings("Nothing to migrate\n", rc.out.written());
}

test "migrate notes a pending file older than the last applied one and runs it" {
    var tmp = try setup(&.{ create_users, add_role, drop_legacy });
    defer tmp.cleanup();
    var fake: FakeDb = .init(&.{ "20260102000000", "20260103000000" });
    defer fake.deinit();

    var r = try runIn(tmp.dir, &fake, .{ .migrate = .{} });
    defer r.deinit();
    try testing.expectEqual(0, r.code);
    try testing.expectEqualStrings("ffmig: note: db/20260101000000_create_users.mig is older than the last applied migration 20260103000000\n", r.err.written());
    try testing.expectEqualStrings("Migrated db/20260101000000_create_users.mig\n", r.out.written());
}

test "project load rejects bad file names and duplicate versions" {
    var tmp = try setup(&.{
        create_users,
        .{ "20260101000000_create_users_again.mig", "" },
        .{ "create_posts.mig", "" },
    });
    defer tmp.cleanup();

    var err: Writer.Allocating = .init(testing.allocator);
    defer err.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const env: Env = .{ .io = testing.io, .cwd = tmp.dir, .gpa = testing.allocator };
    try testing.expectEqual(null, try migrations.Project.load(env, arena_state.allocator(), &err.writer));
    try testing.expectEqualStrings(
        \\ffmig: db/20260101000000_create_users.mig and 20260101000000_create_users_again.mig have the same version 20260101000000
        \\ffmig: db/create_posts.mig: file name must be <YYYYMMDDHHMMSS>_<name>.mig
        \\
    , err.written());
}

fn expectConnectError(url: ?[]const u8, environ: ?*const std.process.Environ.Map, expected: []const u8) !void {
    var err: Writer.Allocating = .init(testing.allocator);
    defer err.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const env: Env = .{ .io = testing.io, .cwd = std.Io.Dir.cwd(), .gpa = testing.allocator, .environ = environ };
    try testing.expectEqual(null, try migrations.connect(env, arena_state.allocator(), url, &err.writer));
    try testing.expectEqualStrings(expected, err.written());
}

test "connect reports url problems without connecting" {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("MYSQL_URL", "mysql://localhost/app");
    try environ.put("EMPTY", "");

    try expectConnectError(null, &environ, "ffmig: no database url in ffmig.toml; set [database] url\n");
    try expectConnectError("${DATABASE_URL}", &environ, "ffmig: DATABASE_URL is not set (used by the database url in ffmig.toml)\n");
    try expectConnectError("${DATABASE_URL}", null, "ffmig: DATABASE_URL is not set (used by the database url in ffmig.toml)\n");
    try expectConnectError("${EMPTY}", &environ, "ffmig: the database url in ffmig.toml is empty\n");
    try expectConnectError("${MYSQL_URL}", &environ, "ffmig: unsupported database 'mysql'; supported: postgres\n");
    try expectConnectError("localhost/app", &environ, "ffmig: the database url must start with a scheme such as postgres://\n");
}

test "url scheme picks the dialect" {
    try testing.expectEqual(.postgres, db.dialectFor("postgres://localhost/app").?);
    try testing.expectEqual(.postgres, db.dialectFor("postgresql://u:p@host:5432/app").?);
    try testing.expectEqual(.postgres, db.dialectFor("POSTGRES://localhost").?);
    try testing.expectEqual(null, db.dialectFor("sqlite://app.db"));
    try testing.expectEqual(null, db.dialectFor("postgres:/nope"));
}

test "migrate and rollback accept their flags" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const env: Env = .{ .io = testing.io, .cwd = tmp.dir, .gpa = testing.allocator };
    const cases = .{
        .{ commands.migrate, &[_][]const u8{ "--lock-wait", "0" } },
        .{ commands.migrate, &[_][]const u8{"--strict"} },
        .{ commands.migrate, &[_][]const u8{ "--strict", "--lock-wait", "0" } },
        .{ commands.migrate, &[_][]const u8{ "--lock-wait", "0", "--strict" } },
        .{ commands.rollback, &[_][]const u8{ "--lock-wait", "5", "--step", "2" } },
        .{ commands.rollback, &[_][]const u8{ "--step", "2", "--lock-wait", "120" } },
    };
    inline for (cases) |c| {
        var out: Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var err: Writer.Allocating = .init(testing.allocator);
        defer err.deinit();
        // Past argument parsing: no ffmig.toml in the empty directory.
        try testing.expectEqual(1, try c[0].run(env, c[1], &out.writer, &err.writer));
        try testing.expectEqualStrings("ffmig: ffmig.toml not found; run 'ffmig init' first\n", err.written());
    }
}

test "rollback and migrate reject extra arguments" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const env: Env = .{ .io = testing.io, .cwd = tmp.dir, .gpa = testing.allocator };
    const cases = .{
        .{ commands.migrate, &[_][]const u8{"x"} },
        .{ commands.status, &[_][]const u8{"--all"} },
        .{ commands.rollback, &[_][]const u8{"--step"} },
        .{ commands.rollback, &[_][]const u8{ "--step", "0" } },
        .{ commands.rollback, &[_][]const u8{ "--step", "two" } },
        .{ commands.rollback, &[_][]const u8{"3"} },
        .{ commands.migrate, &[_][]const u8{"--lock-wait"} },
        .{ commands.migrate, &[_][]const u8{ "--lock-wait", "-1" } },
        .{ commands.migrate, &[_][]const u8{ "--lock-wait", "1s" } },
        .{ commands.migrate, &[_][]const u8{ "--strict", "true" } },
        .{ commands.migrate, &[_][]const u8{ "--lock-wait", "--strict" } },
        .{ commands.rollback, &[_][]const u8{"--strict"} },
        .{ commands.rollback, &[_][]const u8{ "--step", "2", "--lock-wait" } },
        .{ commands.rollback, &[_][]const u8{ "--lock-wait", "5", "--step", "0" } },
    };
    inline for (cases) |c| {
        var out: Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var err: Writer.Allocating = .init(testing.allocator);
        defer err.deinit();
        try testing.expectEqual(1, try c[0].run(env, c[1], &out.writer, &err.writer));
        try testing.expectEqualStrings(c[0].usage, err.written());
    }
}
