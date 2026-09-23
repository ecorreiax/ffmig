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
/// Fails the first statement that contains `fail_on`.
const FakeDb = struct {
    applied: []const []const u8 = &.{},
    fail_on: ?[]const u8 = null,
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

    const vtable: db.Db.VTable = .{ .exec = exec, .query = query, .close = close };

    fn exec(ptr: *anyopaque, statement: []const u8, diag: *db.Diagnostic) db.Error!void {
        const f: *FakeDb = @ptrCast(@alignCast(ptr));
        if (f.fail_on) |s| if (std.mem.indexOf(u8, statement, s) != null) {
            diag.message = "boom";
            return error.DatabaseError;
        };
        f.log.writer.print("{s};\n", .{statement}) catch return error.OutOfMemory;
    }

    fn query(ptr: *anyopaque, arena: Allocator, statement: []const u8, _: *db.Diagnostic) db.Error![]const []const u8 {
        const f: *FakeDb = @ptrCast(@alignCast(ptr));
        std.debug.assert(std.mem.startsWith(u8, statement, "SELECT"));
        // Callers may sort the result in place.
        return arena.dupe([]const u8, f.applied);
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

const Command = union(enum) { migrate, rollback: usize, status };

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
        .migrate => try commands.migrate.migrate(env, arena, project, conn, out, err),
        .rollback => |step| try commands.rollback.rollback(env, arena, project, conn, step, out, err),
        .status => try commands.status.status(arena, project, conn, out, err),
    };
    return r;
}

fn setup(files: []const [2][]const u8) !testing.TmpDir {
    var tmp = testing.tmpDir(.{});
    errdefer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = config.file_name, .data = "[migration]\npath = \"db\"\n" });
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

const tracking_create = "CREATE TABLE IF NOT EXISTS \"schema_migrations\" (\"version\" varchar PRIMARY KEY);\n";

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
        const pending = try migrations.pending(arena_state.allocator(), &files, c.applied);
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

    var r = try runIn(tmp.dir, &fake, .migrate);
    defer r.deinit();
    try testing.expectEqualStrings("", r.err.written());
    try testing.expectEqual(0, r.code);
    try testing.expectEqualStrings(
        \\Migrated db/20260102000000_add_role.mig
        \\Migrated db/20260103000000_drop_legacy.mig
        \\
    , r.out.written());
    try testing.expectEqualStrings(tracking_create ++
        \\BEGIN;
        \\ALTER TABLE "users" ADD COLUMN "role" integer;
        \\CREATE INDEX "index_users_on_role" ON "users" ("role");
        \\INSERT INTO "schema_migrations" ("version") VALUES ('20260102000000');
        \\COMMIT;
        \\BEGIN;
        \\DROP TABLE "legacy";
        \\INSERT INTO "schema_migrations" ("version") VALUES ('20260103000000');
        \\COMMIT;
        \\
    , fake.log.written());
}

test "migrate with nothing pending" {
    var tmp = try setup(&.{create_users});
    defer tmp.cleanup();
    var fake: FakeDb = .init(&.{"20260101000000"});
    defer fake.deinit();

    var r = try runIn(tmp.dir, &fake, .migrate);
    defer r.deinit();
    try testing.expectEqual(0, r.code);
    try testing.expectEqualStrings("Nothing to migrate\n", r.out.written());
    try testing.expectEqualStrings(tracking_create, fake.log.written());
}

test "migrate checks every pending file before running any" {
    const broken = [2][]const u8{ "20260104000000_broken.mig", "migration Broken { change { add_idx :t, :c } }\n" };
    const also_broken = [2][]const u8{ "20260105000000_also_broken.mig", "migration AlsoBroken {\n" };
    var tmp = try setup(&.{ create_users, broken, add_role, also_broken });
    defer tmp.cleanup();
    var fake: FakeDb = .init(&.{});
    defer fake.deinit();

    var r = try runIn(tmp.dir, &fake, .migrate);
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
    try testing.expectEqualStrings(tracking_create, fake.log.written());
}

test "migrate stops at a failing statement and rolls its migration back" {
    var tmp = try setup(&.{ create_users, add_role, drop_legacy });
    defer tmp.cleanup();
    var fake: FakeDb = .init(&.{});
    defer fake.deinit();
    fake.fail_on = "CREATE INDEX";

    var r = try runIn(tmp.dir, &fake, .migrate);
    defer r.deinit();
    try testing.expectEqual(1, r.code);
    try testing.expectEqualStrings("Migrated db/20260101000000_create_users.mig\n", r.out.written());
    try testing.expectEqualStrings(
        \\ffmig: db/20260102000000_add_role.mig: boom
        \\while running:
        \\CREATE INDEX "index_users_on_role" ON "users" ("role");
        \\
    , r.err.written());
    try testing.expectEqualStrings(tracking_create ++
        \\BEGIN;
        \\CREATE TABLE "users" (
        \\  "id" bigserial PRIMARY KEY,
        \\  "email" varchar NOT NULL
        \\);
        \\INSERT INTO "schema_migrations" ("version") VALUES ('20260101000000');
        \\COMMIT;
        \\BEGIN;
        \\ALTER TABLE "users" ADD COLUMN "role" integer;
        \\ROLLBACK;
        \\
    , fake.log.written());
}

test "rollback undoes the newest migrations with their down plans" {
    var tmp = try setup(&.{ create_users, add_role, drop_legacy });
    defer tmp.cleanup();
    var fake: FakeDb = .init(&.{ "20260103000000", "20260101000000", "20260102000000" });
    defer fake.deinit();

    var r = try runIn(tmp.dir, &fake, .{ .rollback = 2 });
    defer r.deinit();
    try testing.expectEqualStrings("", r.err.written());
    try testing.expectEqual(0, r.code);
    try testing.expectEqualStrings(
        \\Rolled back db/20260103000000_drop_legacy.mig
        \\Rolled back db/20260102000000_add_role.mig
        \\
    , r.out.written());
    try testing.expectEqualStrings(tracking_create ++
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
    , fake.log.written());
}

test "rollback stops on an irreversible change before touching the database" {
    const drop_users = [2][]const u8{ "20260104000000_drop_users.mig", "migration DropUsers { change { drop_table :users } }\n" };
    var tmp = try setup(&.{ create_users, drop_users });
    defer tmp.cleanup();
    var fake: FakeDb = .init(&.{ "20260101000000", "20260104000000" });
    defer fake.deinit();

    var r = try runIn(tmp.dir, &fake, .{ .rollback = 5 });
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
    try testing.expectEqualStrings(tracking_create, fake.log.written());
}

test "rollback needs the file of each migration it undoes" {
    var tmp = try setup(&.{create_users});
    defer tmp.cleanup();
    var fake: FakeDb = .init(&.{ "20260101000000", "20260109000000" });
    defer fake.deinit();

    var r = try runIn(tmp.dir, &fake, .{ .rollback = 1 });
    defer r.deinit();
    try testing.expectEqual(1, r.code);
    try testing.expectEqualStrings(
        \\ffmig: no file in db for applied migration 20260109000000
        \\ffmig: nothing was rolled back
        \\
    , r.err.written());
    try testing.expectEqualStrings(tracking_create, fake.log.written());
}

test "rollback with nothing applied" {
    var tmp = try setup(&.{create_users});
    defer tmp.cleanup();
    var fake: FakeDb = .init(&.{});
    defer fake.deinit();

    var r = try runIn(tmp.dir, &fake, .{ .rollback = 1 });
    defer r.deinit();
    try testing.expectEqual(0, r.code);
    try testing.expectEqualStrings("Nothing to roll back\n", r.out.written());
}

test "status lists files as up or down, and recorded versions without a file" {
    var tmp = try setup(&.{ create_users, add_role, drop_legacy });
    defer tmp.cleanup();
    var fake: FakeDb = .init(&.{ "20260102000000", "20260101000000", "20260109000000" });
    defer fake.deinit();

    var r = try runIn(tmp.dir, &fake, .status);
    defer r.deinit();
    try testing.expectEqual(0, r.code);
    try testing.expectEqualStrings(
        \\up    db/20260101000000_create_users.mig
        \\up    db/20260102000000_add_role.mig
        \\down  db/20260103000000_drop_legacy.mig
        \\up    20260109000000 (no file)
        \\
    , r.out.written());
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
