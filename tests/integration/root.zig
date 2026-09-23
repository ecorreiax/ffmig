//! Integration tests: `ffmig` commands, run through the CLI router, against
//! a real PostgreSQL server. `make integration` starts a throwaway server
//! and passes its socket directory in `FFMIG_TEST_PGHOST`; each test gets
//! a fresh database on it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const ffmig = @import("ffmig");
const config = ffmig.config;
const db = ffmig.db;

const testing = std.testing;

/// A fresh database and a project directory whose `ffmig.toml` reads its
/// URL from `${DATABASE_URL}`.
const Fixture = struct {
    /// On the heap: the connections keep its allocator, so it must not move.
    arena_state: *std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    environ: std.process.Environ.Map,
    /// Direct connection, for checking what the commands did.
    conn: db.Db,

    /// `name` names the database; it must be unique among the tests.
    fn init(name: []const u8, files: []const [2][]const u8) !Fixture {
        const host = testing.environ.getPosix("FFMIG_TEST_PGHOST") orelse {
            std.debug.print("FFMIG_TEST_PGHOST is not set; run the integration tests with 'make integration'\n", .{});
            return error.NoTestServer;
        };

        const arena_state = try testing.allocator.create(std.heap.ArenaAllocator);
        errdefer testing.allocator.destroy(arena_state);
        arena_state.* = .init(testing.allocator);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();

        var admin = try connect(arena, host, "postgres");
        defer admin.close();
        try exec(admin, try std.fmt.allocPrint(arena, "CREATE DATABASE \"{s}\"", .{name}));

        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{
            .sub_path = config.file_name,
            .data = "[migration]\npath = \"db\"\n\n[database]\nurl = \"${DATABASE_URL}\"\n",
        });
        try tmp.dir.createDirPath(testing.io, "db");
        for (files) |f| {
            const path = try std.fs.path.join(arena, &.{ "db", f[0] });
            try tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = f[1] });
        }

        var environ: std.process.Environ.Map = .init(arena);
        try environ.put("DATABASE_URL", try url(arena, host, name));

        return .{
            .arena_state = arena_state,
            .tmp = tmp,
            .environ = environ,
            .conn = try connect(arena, host, name),
        };
    }

    fn deinit(f: *Fixture) void {
        f.conn.close();
        f.tmp.cleanup();
        f.arena_state.deinit();
        testing.allocator.destroy(f.arena_state);
    }

    /// Runs `ffmig <args>` in the project directory and checks its exit
    /// code and output.
    fn expectRun(f: *Fixture, args: []const []const u8, code: u8, stdout: []const u8, stderr: []const u8) !void {
        var out: Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var err: Writer.Allocating = .init(testing.allocator);
        defer err.deinit();

        const env: ffmig.commands.Env = .{ .io = testing.io, .cwd = f.tmp.dir, .gpa = testing.allocator, .environ = &f.environ };
        const actual = try ffmig.cli.run(env, args, &out.writer, &err.writer);
        try testing.expectEqualStrings(stderr, err.written());
        try testing.expectEqualStrings(stdout, out.written());
        try testing.expectEqual(code, actual);
    }

    /// Checks the first column of `statement`'s rows, joined with commas.
    fn expectQuery(f: *Fixture, statement: []const u8, expected: []const u8) !void {
        const arena = f.arena_state.allocator();
        var diag: db.Diagnostic = .{};
        const rows = f.conn.query(arena, statement, &diag) catch |e| {
            std.debug.print("{s}\n", .{diag.message});
            return e;
        };
        try testing.expectEqualStrings(expected, try std.mem.join(arena, ",", rows));
    }

    fn expectColumns(f: *Fixture, table: []const u8, expected: []const u8) !void {
        const statement = try std.fmt.allocPrint(f.arena_state.allocator(),
            \\SELECT column_name FROM information_schema.columns
            \\WHERE table_schema = 'public' AND table_name = '{s}' ORDER BY ordinal_position
        , .{table});
        try f.expectQuery(statement, expected);
    }

    fn expectVersions(f: *Fixture, expected: []const u8) !void {
        try f.expectQuery("SELECT version FROM schema_migrations ORDER BY version", expected);
    }
};

/// Connects over the Unix socket in `host`. The explicit host keeps the
/// tests off any server that `PGHOST` or the default socket points at.
fn url(arena: Allocator, host: []const u8, database: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "postgres://ffmig@/{s}?host={s}", .{ database, host });
}

fn connect(arena: Allocator, host: []const u8, database: []const u8) !db.Db {
    var diag: db.Diagnostic = .{};
    return db.connect(arena, .postgres, try url(arena, host, database), &diag) catch |e| {
        std.debug.print("cannot connect: {s}\n", .{diag.message});
        return e;
    };
}

fn exec(conn: db.Db, statement: []const u8) !void {
    var diag: db.Diagnostic = .{};
    conn.exec(statement, &diag) catch |e| {
        std.debug.print("{s}\n", .{diag.message});
        return e;
    };
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

test "migrate, status and rollback" {
    var f: Fixture = try .init("migrate_status_rollback", &.{ create_users, add_role });
    defer f.deinit();

    try f.expectRun(&.{"status"}, 0,
        \\down  db/20260101000000_create_users.mig
        \\down  db/20260102000000_add_role.mig
        \\
    , "");

    try f.expectRun(&.{"migrate"}, 0,
        \\Migrated db/20260101000000_create_users.mig
        \\Migrated db/20260102000000_add_role.mig
        \\
    , "");
    try f.expectColumns("users", "id,email,role");
    try f.expectQuery("SELECT indexname FROM pg_indexes WHERE tablename = 'users' ORDER BY indexname", "index_users_on_role,users_pkey");
    try f.expectVersions("20260101000000,20260102000000");

    try f.expectRun(&.{"status"}, 0,
        \\up    db/20260101000000_create_users.mig
        \\up    db/20260102000000_add_role.mig
        \\
    , "");
    try f.expectRun(&.{"migrate"}, 0, "Nothing to migrate\n", "");

    try f.expectRun(&.{"rollback"}, 0, "Rolled back db/20260102000000_add_role.mig\n", "");
    try f.expectColumns("users", "id,email");
    try f.expectQuery("SELECT indexname FROM pg_indexes WHERE tablename = 'users' ORDER BY indexname", "users_pkey");
    try f.expectVersions("20260101000000");

    try f.expectRun(&.{"migrate"}, 0, "Migrated db/20260102000000_add_role.mig\n", "");
    try f.expectRun(&.{ "rollback", "--step", "2" }, 0,
        \\Rolled back db/20260102000000_add_role.mig
        \\Rolled back db/20260101000000_create_users.mig
        \\
    , "");
    try f.expectColumns("users", "");
    try f.expectVersions("");
    try f.expectRun(&.{"rollback"}, 0, "Nothing to roll back\n", "");
}

test "a failing migration rolls back only itself" {
    const bad = [2][]const u8{
        "20260102000000_bad.mig",
        \\migration Bad {
        \\  change {
        \\    add_column :users, :role, :integer
        \\    add_index :users, :missing
        \\  }
        \\}
        \\
    };
    var f: Fixture = try .init("failing_migration", &.{ create_users, bad });
    defer f.deinit();

    try f.expectRun(&.{"migrate"}, 1, "Migrated db/20260101000000_create_users.mig\n",
        \\ffmig: db/20260102000000_bad.mig: column "missing" does not exist
        \\while running:
        \\CREATE INDEX "index_users_on_missing" ON "users" ("missing");
        \\
    );
    // The column added before the failing statement is gone too.
    try f.expectColumns("users", "id,email");
    try f.expectVersions("20260101000000");
    try f.expectRun(&.{"status"}, 0,
        \\up    db/20260101000000_create_users.mig
        \\down  db/20260102000000_bad.mig
        \\
    , "");
}
