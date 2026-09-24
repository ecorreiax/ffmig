//! `create`, `drop`, `protect` and `unprotect`: splitting the database
//! url, and the commands against a fake database that records every
//! statement.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const ffmig = @import("ffmig");
const commands = ffmig.commands;
const migrations = commands.migrations;
const config = ffmig.config;
const db = ffmig.db;
const Env = commands.Env;

const testing = std.testing;

fn expectAdmin(url: []const u8, database: []const u8, admin_url: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const admin = try db.admin(arena_state.allocator(), .postgres, url);
    try testing.expectEqualStrings(database, admin.database);
    try testing.expectEqualStrings(admin_url, admin.url);
}

test "admin points the url at the maintenance database" {
    try expectAdmin("postgres://localhost/app_dev", "app_dev", "postgres://localhost/postgres");
    try expectAdmin("postgresql://u:p@db:5432/app?sslmode=require", "app", "postgresql://u:p@db:5432/postgres?sslmode=require");
    try expectAdmin("postgres://ffmig@/app?host=/tmp/pg", "app", "postgres://ffmig@/postgres?host=/tmp/pg");
    try expectAdmin("postgres:///app#frag", "app", "postgres:///postgres#frag");
    try expectAdmin("postgres://localhost/my%20app", "my app", "postgres://localhost/postgres");
}

test "admin needs a database name in the path" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{
        "postgres://localhost",
        "postgres://localhost/",
        "postgres://localhost?host=/tmp",
        "postgres://localhost/app?dbname=other",
        "postgres://localhost/app?sslmode=disable&dbname=other",
    }) |url| {
        try testing.expectError(error.NoDatabaseName, db.admin(arena, .postgres, url));
    }
}

/// Answers the existence and protection queries from `exists` and
/// `protected`, and logs every statement. Fails every `exec` when `fail`
/// is set.
const FakeDb = struct {
    exists: bool,
    protected: bool = false,
    fail: bool = false,
    log: Writer.Allocating,

    fn init(exists: bool) FakeDb {
        return .{ .exists = exists, .log = .init(testing.allocator) };
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
        if (f.fail) {
            diag.message = "boom";
            return error.DatabaseError;
        }
        f.log.writer.print("{s};\n", .{statement}) catch return error.OutOfMemory;
    }

    fn query(ptr: *anyopaque, arena: Allocator, statement: []const u8, _: *db.Diagnostic) db.Error![]const db.Row {
        const f: *FakeDb = @ptrCast(@alignCast(ptr));
        const found = if (std.mem.indexOf(u8, statement, "pg_db_role_setting") != null) f.protected else f.exists;
        f.log.writer.print("{s};\n", .{statement[0..@min(statement.len, 40)]}) catch return error.OutOfMemory;
        return arena.dupe(db.Row, if (found) &.{&.{"1"}} else &.{});
    }

    fn server(_: *anyopaque) db.Db.Server {
        return .{ .host = "db.example.com", .port = "5432" };
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
    create,
    /// With what the user types, or null for no terminal.
    drop: struct { force: bool = false, input: ?[]const u8 = null },
    protect,
    unprotect,
};

fn runWith(fake: *FakeDb, command: Command) !Result {
    var r: Result = .{ .code = undefined, .out = .init(testing.allocator), .err = .init(testing.allocator) };
    errdefer r.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const conn = fake.connection();
    const out = &r.out.writer;
    const err = &r.err.writer;
    r.code = switch (command) {
        .create => try commands.create.create(arena, conn, "app_dev", out, err),
        .drop => |d| blk: {
            var in: std.Io.Reader = .fixed(d.input orelse "");
            break :blk try commands.drop.drop(arena, conn, "app_dev", .{ .force = d.force }, if (d.input != null) &in else null, out, err);
        },
        .protect => try commands.protect.setProtected(arena, conn, "app_dev", true, out, err),
        .unprotect => try commands.protect.setProtected(arena, conn, "app_dev", false, out, err),
    };
    return r;
}

// The first 40 bytes of each query, as the fake logs them.
const exists_query = "SELECT 1 FROM pg_database WHERE datname ;\n";
const protected_query = "SELECT 1 FROM pg_db_role_setting s JOIN ;\n";
const prompt = "This drops database app_dev on db.example.com:5432 and everything in it.\n" ++
    "Type the database name to confirm: ";

test "create creates a missing database" {
    var fake: FakeDb = .init(false);
    defer fake.deinit();
    var r = try runWith(&fake, .create);
    defer r.deinit();
    try testing.expectEqual(0, r.code);
    try testing.expectEqualStrings("Created database app_dev\n", r.out.written());
    try testing.expectEqualStrings(exists_query ++ "CREATE DATABASE \"app_dev\";\n", fake.log.written());
}

test "create leaves an existing database alone" {
    var fake: FakeDb = .init(true);
    defer fake.deinit();
    var r = try runWith(&fake, .create);
    defer r.deinit();
    try testing.expectEqual(0, r.code);
    try testing.expectEqualStrings("Database app_dev already exists\n", r.out.written());
    try testing.expectEqualStrings(exists_query, fake.log.written());
}

test "create reports a database error" {
    var fake: FakeDb = .init(false);
    defer fake.deinit();
    fake.fail = true;
    var r = try runWith(&fake, .create);
    defer r.deinit();
    try testing.expectEqual(1, r.code);
    try testing.expectEqualStrings("", r.out.written());
    try testing.expectEqualStrings("ffmig: cannot create the database: boom\n", r.err.written());
}

test "drop drops after the name is typed" {
    var fake: FakeDb = .init(true);
    defer fake.deinit();
    var r = try runWith(&fake, .{ .drop = .{ .input = " app_dev \r\n" } });
    defer r.deinit();
    try testing.expectEqual(0, r.code);
    try testing.expectEqualStrings(prompt, r.err.written());
    try testing.expectEqualStrings("Dropped database app_dev\n", r.out.written());
    try testing.expectEqualStrings(exists_query ++ protected_query ++ "DROP DATABASE \"app_dev\";\n", fake.log.written());
}

test "drop keeps the database when the name does not match" {
    for ([_][]const u8{ "app_prod\n", "y\n", "\n", "" }) |input| {
        var fake: FakeDb = .init(true);
        defer fake.deinit();
        var r = try runWith(&fake, .{ .drop = .{ .input = input } });
        defer r.deinit();
        try testing.expectEqual(1, r.code);
        try testing.expectEqualStrings(prompt ++ "ffmig: the name did not match; nothing was dropped\n", r.err.written());
        try testing.expectEqualStrings(exists_query ++ protected_query, fake.log.written());
    }
}

test "drop without a terminal needs --force" {
    var fake: FakeDb = .init(true);
    defer fake.deinit();
    var r = try runWith(&fake, .{ .drop = .{} });
    defer r.deinit();
    try testing.expectEqual(1, r.code);
    try testing.expectEqualStrings("ffmig: dropping database app_dev on db.example.com:5432 needs confirmation; run it in a terminal or pass --force\n", r.err.written());
    try testing.expectEqualStrings(exists_query ++ protected_query, fake.log.written());
}

test "drop --force does not ask" {
    var fake: FakeDb = .init(true);
    defer fake.deinit();
    var r = try runWith(&fake, .{ .drop = .{ .force = true } });
    defer r.deinit();
    try testing.expectEqual(0, r.code);
    try testing.expectEqualStrings("", r.err.written());
    try testing.expectEqualStrings("Dropped database app_dev\n", r.out.written());
}

test "drop refuses a protected database, even with --force" {
    for ([_]Command{ .{ .drop = .{ .force = true } }, .{ .drop = .{ .input = "app_dev\n" } } }) |command| {
        var fake: FakeDb = .init(true);
        defer fake.deinit();
        fake.protected = true;
        var r = try runWith(&fake, command);
        defer r.deinit();
        try testing.expectEqual(1, r.code);
        try testing.expectEqualStrings("ffmig: database app_dev is protected; run 'ffmig unprotect' first to drop it\n", r.err.written());
        try testing.expectEqualStrings(exists_query ++ protected_query, fake.log.written());
    }
}

test "drop with no database" {
    var fake: FakeDb = .init(false);
    defer fake.deinit();
    var r = try runWith(&fake, .{ .drop = .{} });
    defer r.deinit();
    try testing.expectEqual(0, r.code);
    try testing.expectEqualStrings("Database app_dev does not exist\n", r.out.written());
    try testing.expectEqualStrings(exists_query, fake.log.written());
}

test "protect and unprotect set and reset the mark" {
    var fake: FakeDb = .init(true);
    defer fake.deinit();
    var p = try runWith(&fake, .protect);
    defer p.deinit();
    try testing.expectEqual(0, p.code);
    try testing.expectEqualStrings("Protected database app_dev\n", p.out.written());
    var u = try runWith(&fake, .unprotect);
    defer u.deinit();
    try testing.expectEqual(0, u.code);
    try testing.expectEqualStrings("Unprotected database app_dev\n", u.out.written());
    try testing.expectEqualStrings(exists_query ++ "ALTER DATABASE \"app_dev\" SET ffmig.protected = on;\n" ++
        exists_query ++ "ALTER DATABASE \"app_dev\" RESET ffmig.protected;\n", fake.log.written());
}

test "protect needs an existing database" {
    var fake: FakeDb = .init(false);
    defer fake.deinit();
    var r = try runWith(&fake, .protect);
    defer r.deinit();
    try testing.expectEqual(1, r.code);
    try testing.expectEqualStrings("ffmig: database app_dev does not exist\n", r.err.written());
}

test "commands reject unknown arguments" {
    const env: Env = .{ .io = testing.io, .cwd = std.Io.Dir.cwd(), .gpa = testing.allocator };
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: Writer.Allocating = .init(testing.allocator);
    defer err.deinit();
    try testing.expectEqual(1, try commands.create.run(env, &.{"x"}, &out.writer, &err.writer));
    try testing.expectEqual(1, try commands.drop.run(env, &.{"--yes"}, &out.writer, &err.writer));
    try testing.expectEqual(1, try commands.protect.run(env, &.{"x"}, &out.writer, &err.writer));
    try testing.expectEqual(1, try commands.unprotect.run(env, &.{"x"}, &out.writer, &err.writer));
    try testing.expectEqualStrings(commands.create.usage ++ commands.drop.usage ++ commands.protect.usage ++ commands.unprotect.usage, err.written());
}

test "create needs a database name in the url" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = config.file_name, .data = "[database]\nurl = \"postgres://localhost\"\n" });

    const env: Env = .{ .io = testing.io, .cwd = tmp.dir, .gpa = testing.allocator };
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: Writer.Allocating = .init(testing.allocator);
    defer err.deinit();
    try testing.expectEqual(1, try commands.create.run(env, &.{}, &out.writer, &err.writer));
    try testing.expectEqualStrings("ffmig: the database url in ffmig.toml must name a database in its path, e.g. postgres://localhost/app_dev\n", err.written());
}
