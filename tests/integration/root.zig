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

    /// Rewrites `ffmig.toml` with `extra` added to its `[migration]`
    /// section.
    fn configure(f: *Fixture, extra: []const u8) !void {
        const data = try std.mem.concat(f.arena_state.allocator(), u8, &.{
            "[migration]\npath = \"db\"\n",
            extra,
            "\n[database]\nurl = \"${DATABASE_URL}\"\n",
        });
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = config.file_name, .data = data });
    }

    fn deinit(f: *Fixture) void {
        f.conn.close();
        f.tmp.cleanup();
        f.arena_state.deinit();
        testing.allocator.destroy(f.arena_state);
    }

    /// Runs `ffmig <args>` in the project directory. Safe to call from
    /// several threads at once: each run makes its own connection.
    fn run(f: *const Fixture, args: []const []const u8) !Output {
        var o: Output = .{ .code = undefined, .out = .init(testing.allocator), .err = .init(testing.allocator) };
        errdefer o.deinit();
        const env: ffmig.commands.Env = .{ .io = testing.io, .cwd = f.tmp.dir, .gpa = testing.allocator, .environ = &f.environ };
        o.code = try ffmig.cli.run(env, args, &o.out.writer, &o.err.writer);
        return o;
    }

    /// Runs `ffmig <args>` in the project directory and checks its exit
    /// code and output.
    fn expectRun(f: *Fixture, args: []const []const u8, code: u8, stdout: []const u8, stderr: []const u8) !void {
        var o = try f.run(args);
        defer o.deinit();
        try o.expect(code, stdout, stderr);
    }

    /// Checks `statement`'s rows: columns joined with spaces, `NULL` for
    /// null, and rows joined with commas.
    fn expectQuery(f: *Fixture, statement: []const u8, expected: []const u8) !void {
        const arena = f.arena_state.allocator();
        var diag: db.Diagnostic = .{};
        const rows = f.conn.query(arena, statement, &diag) catch |e| {
            std.debug.print("{s}\n", .{diag.message});
            return e;
        };
        var joined: Writer.Allocating = .init(arena);
        for (rows, 0..) |row, i| {
            if (i > 0) try joined.writer.writeByte(',');
            for (row, 0..) |value, j| {
                if (j > 0) try joined.writer.writeByte(' ');
                try joined.writer.writeAll(value orelse "NULL");
            }
        }
        try testing.expectEqualStrings(expected, joined.written());
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

/// What one `ffmig` run returned and printed.
const Output = struct {
    code: u8,
    out: Writer.Allocating,
    err: Writer.Allocating,

    fn deinit(o: *Output) void {
        o.out.deinit();
        o.err.deinit();
    }

    /// `stdout` spells the times that `status` prints as `applied_time`.
    fn expect(o: *Output, code: u8, stdout: []const u8, stderr: []const u8) !void {
        try testing.expectEqualStrings(stderr, o.err.written());
        maskTimes(o.out.written());
        try testing.expectEqualStrings(stdout, o.out.written());
        try testing.expectEqual(code, o.code);
    }
};

/// What `maskTimes` turns the time on an `up` line of `status` into.
const applied_time = "YYYY-MM-DD HH:MM:SS UTC";

/// Replaces the times on `status` lines, which depend on when the test
/// ran, with `applied_time`.
fn maskTimes(out: []u8) void {
    const prefix = "up    ";
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix) or line.len < prefix.len + applied_time.len) continue;
        const time = line[prefix.len..][0..applied_time.len];
        if (!std.ascii.isDigit(time[0]) or !std.mem.endsWith(u8, time, " UTC")) continue;
        const start = @intFromPtr(time.ptr) - @intFromPtr(out.ptr);
        @memcpy(out[start..][0..applied_time.len], applied_time);
    }
}

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
        \\down                           db/20260101000000_create_users.mig
        \\down                           db/20260102000000_add_role.mig
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
        \\up    YYYY-MM-DD HH:MM:SS UTC  db/20260101000000_create_users.mig
        \\up    YYYY-MM-DD HH:MM:SS UTC  db/20260102000000_add_role.mig
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

test "--url and FFMIG_DATABASE_URL beat the config" {
    var f: Fixture = try .init("url_overrides", &.{create_users});
    defer f.deinit();
    const real = f.environ.get("DATABASE_URL").?;
    // A config whose own url cannot resolve, at another path.
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "other.toml", .data = "[migration]\npath = \"db\"\n\n[database]\nurl = \"${NOT_SET}\"\n" });

    try f.expectRun(&.{ "status", "--config", "other.toml" }, 1, "", "ffmig: NOT_SET is not set (used by the database url in other.toml)\n");
    try f.expectRun(&.{ "status", "--config", "other.toml", "--url", real }, 0,
        \\down                           db/20260101000000_create_users.mig
        \\
    , "");
    const url_flag = try std.mem.concat(f.arena_state.allocator(), u8, &.{ "--url=", real });
    try f.expectRun(&.{ "migrate", url_flag, "--config=other.toml" }, 0, "Migrated db/20260101000000_create_users.mig\n", "");
    try f.expectRun(&.{ "create", "--config", "other.toml", "--url", real }, 0, "Database url_overrides already exists\n", "");

    try f.environ.put("FFMIG_DATABASE_URL", real);
    try f.expectRun(&.{ "status", "--config", "other.toml" }, 0,
        \\up    YYYY-MM-DD HH:MM:SS UTC  db/20260101000000_create_users.mig
        \\
    , "");
}

test "references add a foreign key and an index, and roll back" {
    const create_posts = [2][]const u8{
        "20260102000000_create_posts.mig",
        \\migration CreatePosts {
        \\  change {
        \\    create_table :posts {
        \\      references :user, null: false, on_delete: :cascade
        \\      references :parent, to: :posts
        \\      references :editor, to: :users, index: :unique
        \\    }
        \\    add_reference :users, :best_post, to: :posts, on_delete: :nullify
        \\  }
        \\}
        \\
    };
    var f: Fixture = try .init("references", &.{ create_users, create_posts });
    defer f.deinit();

    try f.expectRun(&.{"migrate"}, 0,
        \\Migrated db/20260101000000_create_users.mig
        \\Migrated db/20260102000000_create_posts.mig
        \\
    , "");
    const constraints =
        \\SELECT conname || ' ' || pg_get_constraintdef(oid) FROM pg_constraint
        \\WHERE contype = 'f' ORDER BY conname
    ;
    try f.expectQuery(constraints, "fk_posts_on_editor_id FOREIGN KEY (editor_id) REFERENCES users(id)," ++
        "fk_posts_on_parent_id FOREIGN KEY (parent_id) REFERENCES posts(id)," ++
        "fk_posts_on_user_id FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE," ++
        "fk_users_on_best_post_id FOREIGN KEY (best_post_id) REFERENCES posts(id) ON DELETE SET NULL");
    const indexes = "SELECT indexname FROM pg_indexes WHERE tablename IN ('posts', 'users') ORDER BY indexname";
    try f.expectQuery(indexes, "index_posts_on_editor_id,index_posts_on_parent_id,index_posts_on_user_id,index_users_on_best_post_id,posts_pkey,users_pkey");

    try f.expectQuery(
        "SELECT indexdef FROM pg_indexes WHERE indexname = 'index_posts_on_editor_id'",
        "CREATE UNIQUE INDEX index_posts_on_editor_id ON public.posts USING btree (editor_id)",
    );

    // The foreign keys act: deleting the user deletes their post.
    try exec(f.conn, "INSERT INTO users (id, email) VALUES (1, 'a@b.c')");
    try exec(f.conn, "INSERT INTO posts (id, user_id) VALUES (1, 1)");
    try exec(f.conn, "UPDATE users SET best_post_id = 1");
    try exec(f.conn, "DELETE FROM users");
    try f.expectQuery("SELECT count(*)::text FROM posts", "0");

    try f.expectRun(&.{"rollback"}, 0, "Rolled back db/20260102000000_create_posts.mig\n", "");
    try f.expectColumns("users", "id,email");
    try f.expectColumns("posts", "");
    try f.expectQuery(constraints, "");
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
        \\up    YYYY-MM-DD HH:MM:SS UTC  db/20260101000000_create_users.mig
        \\down                           db/20260102000000_bad.mig
        \\
    , "");
}

test "create, migrate, protect and drop" {
    const host = testing.environ.getPosix("FFMIG_TEST_PGHOST") orelse return error.NoTestServer;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = config.file_name,
        .data = "[migration]\npath = \"db\"\n\n[database]\nurl = \"${DATABASE_URL}\"\n",
    });
    try tmp.dir.createDirPath(testing.io, "db");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "db/" ++ create_users[0], .data = create_users[1] });

    var environ: std.process.Environ.Map = .init(arena);
    // A name that needs quoting.
    try environ.put("DATABASE_URL", try url(arena, host, "create%20drop"));
    const env: ffmig.commands.Env = .{ .io = testing.io, .cwd = tmp.dir, .gpa = testing.allocator, .environ = &environ };

    var admin = try connect(arena, host, "postgres");
    defer admin.close();
    const exists = "SELECT datname FROM pg_database WHERE datname = 'create drop'";

    const Step = struct { args: []const []const u8, code: u8 = 0, stdout: []const u8 = "", stderr: []const u8 = "", rows: usize };
    const steps = [_]Step{
        .{ .args = &.{"drop"}, .stdout = "Database create drop does not exist\n", .rows = 0 },
        .{ .args = &.{"create"}, .stdout = "Created database create drop\n", .rows = 1 },
        .{ .args = &.{"create"}, .stdout = "Database create drop already exists\n", .rows = 1 },
        .{ .args = &.{"migrate"}, .stdout = "Migrated db/20260101000000_create_users.mig\n", .rows = 1 },
        // No terminal to confirm on.
        .{ .args = &.{"drop"}, .code = 1, .stderr = try std.fmt.allocPrint(arena, "ffmig: dropping database create drop on {s}:5432 needs confirmation; run it in a terminal or pass --force\n", .{host}), .rows = 1 },
        .{ .args = &.{"protect"}, .stdout = "Protected database create drop\n", .rows = 1 },
        .{ .args = &.{ "drop", "--force" }, .code = 1, .stderr = "ffmig: database create drop is protected; run 'ffmig unprotect' first to drop it\n", .rows = 1 },
        // Still recorded: the refused drops touched nothing.
        .{ .args = &.{"status"}, .stdout = "up    " ++ applied_time ++ "  db/20260101000000_create_users.mig\n", .rows = 1 },
        .{ .args = &.{"unprotect"}, .stdout = "Unprotected database create drop\n", .rows = 1 },
        .{ .args = &.{ "drop", "--force" }, .stdout = "Dropped database create drop\n", .rows = 0 },
        .{ .args = &.{"create"}, .stdout = "Created database create drop\n", .rows = 1 },
        // A fresh database: nothing recorded in schema_migrations.
        .{ .args = &.{"status"}, .stdout = "down                           db/20260101000000_create_users.mig\n", .rows = 1 },
        .{ .args = &.{ "drop", "--force" }, .stdout = "Dropped database create drop\n", .rows = 0 },
    };
    for (steps) |s| {
        var out: Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var err: Writer.Allocating = .init(testing.allocator);
        defer err.deinit();
        const code = try ffmig.cli.run(env, s.args, &out.writer, &err.writer);
        try testing.expectEqualStrings(s.stderr, err.written());
        maskTimes(out.written());
        try testing.expectEqualStrings(s.stdout, out.written());
        try testing.expectEqual(s.code, code);
        var diag: db.Diagnostic = .{};
        try testing.expectEqual(s.rows, (try admin.query(arena, exists, &diag)).len);
    }
}

/// The advisory lock statements `migrate` and `rollback` use, for holding
/// the lock from another connection.
const take_lock = "SELECT pg_advisory_lock(439805110631)";
const release_lock = "SELECT pg_advisory_unlock(439805110631)";

test "migrate gives up while another run holds the lock" {
    var f: Fixture = try .init("lock_held", &.{ create_users, add_role });
    defer f.deinit();
    try exec(f.conn, take_lock);

    try f.expectRun(&.{ "migrate", "--lock-wait", "1" }, 1, "",
        \\Waiting for another ffmig run to finish...
        \\ffmig: another ffmig run holds the lock on this database; gave up after 1s (see --lock-wait)
        \\ffmig: nothing was migrated
        \\
    );
    try f.expectRun(&.{ "rollback", "--lock-wait", "0" }, 1, "",
        \\ffmig: another ffmig run holds the lock on this database; gave up after 0s (see --lock-wait)
        \\ffmig: nothing was rolled back
        \\
    );
    // Not even the tracking table was created.
    try f.expectQuery("SELECT count(*)::text FROM pg_tables WHERE tablename = 'schema_migrations'", "0");

    try exec(f.conn, release_lock);
    // The same key held in another database does not get in the way.
    const host = testing.environ.getPosix("FFMIG_TEST_PGHOST").?;
    var other = try connect(f.arena_state.allocator(), host, "postgres");
    defer other.close();
    try exec(other, take_lock);
    try f.expectRun(&.{ "migrate", "--lock-wait", "0" }, 0,
        \\Migrated db/20260101000000_create_users.mig
        \\Migrated db/20260102000000_add_role.mig
        \\
    , "");
    try f.expectVersions("20260101000000,20260102000000");
}

test "concurrent migrates apply each migration once" {
    var f: Fixture = try .init("lock_concurrent", &.{ create_users, add_role });
    defer f.deinit();

    // A run that starts while the lock is held waits, then migrates.
    try exec(f.conn, take_lock);
    var waiting = try testing.io.concurrent(Fixture.run, .{ &f, &.{"migrate"} });
    // Release once it has tried the lock at least once.
    while (true) {
        var diag: db.Diagnostic = .{};
        const rows = try f.conn.query(f.arena_state.allocator(),
            \\SELECT 1 FROM pg_stat_activity WHERE datname = current_database()
            \\AND pid <> pg_backend_pid() AND query LIKE '%pg_try_advisory_lock%'
        , &diag);
        if (rows.len != 0) break;
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    try exec(f.conn, release_lock);
    var o = try waiting.await(testing.io);
    defer o.deinit();
    try o.expect(0,
        \\Migrated db/20260101000000_create_users.mig
        \\Migrated db/20260102000000_add_role.mig
        \\
    , "Waiting for another ffmig run to finish...\n");
    try f.expectVersions("20260101000000,20260102000000");

    // Two runs started at once: whichever takes the lock second sees
    // what the first applied.
    try f.expectRun(&.{"rollback"}, 0, "Rolled back db/20260102000000_add_role.mig\n", "");
    var a = try testing.io.concurrent(Fixture.run, .{ &f, &.{"migrate"} });
    var b = try testing.io.concurrent(Fixture.run, .{ &f, &.{"migrate"} });
    var ra = try a.await(testing.io);
    defer ra.deinit();
    var rb = try b.await(testing.io);
    defer rb.deinit();
    try testing.expectEqual(0, ra.code);
    try testing.expectEqual(0, rb.code);
    const migrated = "Migrated db/20260102000000_add_role.mig\n";
    const nothing = "Nothing to migrate\n";
    const first_won = std.mem.eql(u8, ra.out.written(), migrated) and std.mem.eql(u8, rb.out.written(), nothing);
    const second_won = std.mem.eql(u8, rb.out.written(), migrated) and std.mem.eql(u8, ra.out.written(), nothing);
    try testing.expect(first_won != second_won);
    try f.expectVersions("20260101000000,20260102000000");
}

test "transaction: false keeps what ran before a failure" {
    const bad = [2][]const u8{
        "20260102000000_bad.mig",
        \\migration Bad, transaction: false {
        \\  change {
        \\    add_column :users, :role, :integer
        \\    add_index :users, :missing
        \\  }
        \\}
        \\
    };
    var f: Fixture = try .init("no_transaction", &.{ create_users, bad });
    defer f.deinit();

    try f.expectRun(&.{"migrate"}, 1, "Migrated db/20260101000000_create_users.mig\n",
        \\ffmig: db/20260102000000_bad.mig: column "missing" does not exist
        \\while running:
        \\CREATE INDEX "index_users_on_missing" ON "users" ("missing");
        \\ffmig: db/20260102000000_bad.mig runs without a transaction, so the statements before this one were not undone
        \\
    );
    // Unlike "a failing migration rolls back only itself", the column stays.
    try f.expectColumns("users", "id,email,role");
    try f.expectVersions("20260101000000");
}

test "transaction: false migrates and rolls back" {
    const add_slug = [2][]const u8{
        "20260102000000_add_slug.mig",
        \\migration AddSlug, transaction: false {
        \\  change {
        \\    add_column :users, :slug, :string
        \\    add_index :users, :slug, unique: true
        \\  }
        \\}
        \\
    };
    var f: Fixture = try .init("no_transaction_ok", &.{ create_users, add_slug });
    defer f.deinit();

    try f.expectRun(&.{"migrate"}, 0,
        \\Migrated db/20260101000000_create_users.mig
        \\Migrated db/20260102000000_add_slug.mig
        \\
    , "");
    try f.expectColumns("users", "id,email,slug");
    try f.expectVersions("20260101000000,20260102000000");
    try f.expectRun(&.{"rollback"}, 0, "Rolled back db/20260102000000_add_slug.mig\n", "");
    try f.expectColumns("users", "id,email");
    try f.expectVersions("20260101000000");
}

test "lock_timeout and statement_timeout stop a blocked migration" {
    var f: Fixture = try .init("timeouts", &.{create_users});
    defer f.deinit();
    try f.expectRun(&.{"migrate"}, 0, "Migrated db/20260101000000_create_users.mig\n", "");

    // Another session holds a lock that add_role's ALTER TABLE waits for.
    try exec(f.conn, "BEGIN");
    try exec(f.conn, "LOCK TABLE users IN ACCESS EXCLUSIVE MODE");
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "db/" ++ add_role[0], .data = add_role[1] });

    const blocked =
        \\while running:
        \\ALTER TABLE "users" ADD COLUMN "role" integer;
        \\
    ;
    try f.configure("lock_timeout = \"100ms\"\n");
    try f.expectRun(&.{"migrate"}, 1, "", "ffmig: db/20260102000000_add_role.mig: canceling statement due to lock timeout\n" ++ blocked);
    try f.configure("statement_timeout = \"100ms\"\n");
    try f.expectRun(&.{"migrate"}, 1, "", "ffmig: db/20260102000000_add_role.mig: canceling statement due to statement timeout\n" ++ blocked);
    try f.expectColumns("users", "id,email");
    try f.expectVersions("20260101000000");

    // Once the lock is gone, the same settings let it through.
    try exec(f.conn, "COMMIT");
    try f.expectRun(&.{"migrate"}, 0, "Migrated db/20260102000000_add_role.mig\n", "");
    try f.expectColumns("users", "id,email,role");

    try f.configure("lock_timeout = \"soon\"\n");
    try f.expectRun(&.{"rollback"}, 1, "",
        \\ffmig: ffmig.toml:3: lock_timeout must be a duration such as "5s" or "500ms", or "0" for no limit
        \\
    );
}

test "a one-column schema_migrations is upgraded in place" {
    var f: Fixture = try .init("tracking_upgrade", &.{ create_users, add_role });
    defer f.deinit();
    // What an ffmig without checksums left behind.
    try exec(f.conn, "CREATE TABLE schema_migrations (version varchar PRIMARY KEY)");
    try exec(f.conn, "INSERT INTO schema_migrations VALUES ('20260101000000')");
    try exec(f.conn, "CREATE TABLE users (id bigserial PRIMARY KEY, email varchar NOT NULL)");

    // No time or checksum for the old row, and nothing made up for it.
    try f.expectRun(&.{"status"}, 0,
        \\up                             db/20260101000000_create_users.mig
        \\down                           db/20260102000000_add_role.mig
        \\
    , "");
    try f.expectColumns("schema_migrations", "version,checksum,applied_at");
    try f.expectQuery("SELECT version, checksum, applied_at FROM schema_migrations", "20260101000000 NULL NULL");

    try f.expectRun(&.{"migrate"}, 0, "Migrated db/20260102000000_add_role.mig\n", "");
    try f.expectQuery(
        "SELECT version, checksum, (applied_at > now() - interval '1 minute')::text FROM schema_migrations ORDER BY version",
        "20260101000000 NULL NULL,20260102000000 91ad7ffee54b6319dd2d0a72873756fe80e1aedde38889bb24d9ad7b5e406c73 true",
    );
    try f.expectRun(&.{"status"}, 0,
        \\up                             db/20260101000000_create_users.mig
        \\up    YYYY-MM-DD HH:MM:SS UTC  db/20260102000000_add_role.mig
        \\
    , "");

    // Editing an applied file.
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "db/" ++ add_role[0], .data = "# role for users\n" ++ add_role[1] });
    try f.expectRun(&.{"status"}, 0,
        \\up                             db/20260101000000_create_users.mig
        \\up    YYYY-MM-DD HH:MM:SS UTC  db/20260102000000_add_role.mig (changed)
        \\
    , "");
    const changed = "db/20260102000000_add_role.mig has changed since it was applied; its changes will not run\n";
    try f.expectRun(&.{"migrate"}, 0, "Nothing to migrate\n", "ffmig: warning: " ++ changed);
    try f.expectRun(&.{ "migrate", "--strict" }, 1, "", "ffmig: " ++ changed ++ "ffmig: nothing was migrated\n");

    // A file older than the newest applied one still runs.
    const create_teams = [2][]const u8{ "20260101120000_create_teams.mig", "migration CreateTeams { change { create_table :teams { } } }\n" };
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "db/" ++ create_teams[0], .data = create_teams[1] });
    try f.expectRun(&.{"migrate"}, 0, "Migrated db/20260101120000_create_teams.mig\n", "ffmig: warning: " ++ changed ++
        "ffmig: note: db/20260101120000_create_teams.mig is older than the last applied migration 20260102000000\n");
    try f.expectVersions("20260101000000,20260101120000,20260102000000");
    try f.expectRun(&.{"rollback"}, 0, "Rolled back db/20260102000000_add_role.mig\n", "");
}

test "execute creates an extension, a view and a backfill, and rolls them back" {
    const active_users = [2][]const u8{
        "20260102000000_active_users.mig",
        \\migration ActiveUsers {
        \\  up {
        \\    execute "CREATE EXTENSION IF NOT EXISTS pgcrypto"
        \\    add_column :users, :token, :string
        \\    execute """
        \\      CREATE VIEW active_users AS
        \\        SELECT id, email FROM users WHERE email <> '';
        \\      UPDATE users SET token = encode(digest(email, 'sha256'), 'hex');
        \\      """, dialect: :postgres
        \\  }
        \\  down {
        \\    execute "DROP VIEW active_users;"
        \\    remove_column :users, :token
        \\    execute "DROP EXTENSION pgcrypto"
        \\  }
        \\}
        \\
    };
    var f: Fixture = try .init("execute", &.{create_users});
    defer f.deinit();
    try f.expectRun(&.{"migrate"}, 0, "Migrated db/20260101000000_create_users.mig\n", "");
    try exec(f.conn, "INSERT INTO users (email) VALUES ('a@b.c'), ('')");
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "db/" ++ active_users[0], .data = active_users[1] });

    try f.expectRun(&.{"migrate"}, 0, "Migrated db/20260102000000_active_users.mig\n", "");
    try f.expectQuery("SELECT extname FROM pg_extension WHERE extname = 'pgcrypto'", "pgcrypto");
    try f.expectQuery("SELECT email FROM active_users", "a@b.c");
    try f.expectQuery("SELECT left(token, 8) FROM users WHERE email = 'a@b.c'", "d648b243");

    try f.expectRun(&.{"rollback"}, 0, "Rolled back db/20260102000000_active_users.mig\n", "");
    try f.expectQuery("SELECT extname FROM pg_extension WHERE extname = 'pgcrypto'", "");
    try f.expectQuery("SELECT viewname FROM pg_views WHERE viewname = 'active_users'", "");
    try f.expectColumns("users", "id,email");
    try f.expectVersions("20260101000000");
}

test "CREATE INDEX CONCURRENTLY through execute needs transaction: false" {
    const concurrently =
        \\  up {
        \\    execute "CREATE INDEX CONCURRENTLY index_users_on_email ON users (email)"
        \\  }
        \\  down {
        \\    execute "DROP INDEX CONCURRENTLY index_users_on_email"
        \\  }
        \\}
        \\
    ;
    const name = "db/20260102000000_index_email.mig";
    var f: Fixture = try .init("execute_concurrently", &.{create_users});
    defer f.deinit();
    const indexes = "SELECT indexname FROM pg_indexes WHERE tablename = 'users' ORDER BY indexname";

    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = "migration IndexEmail {\n" ++ concurrently });
    try f.expectRun(&.{"migrate"}, 1, "Migrated db/20260101000000_create_users.mig\n",
        \\ffmig: db/20260102000000_index_email.mig: CREATE INDEX CONCURRENTLY cannot run inside a transaction block
        \\while running:
        \\CREATE INDEX CONCURRENTLY index_users_on_email ON users (email);
        \\
    );
    try f.expectQuery(indexes, "users_pkey");
    try f.expectVersions("20260101000000");

    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = "migration IndexEmail, transaction: false {\n" ++ concurrently });
    try f.expectRun(&.{"migrate"}, 0, "Migrated db/20260102000000_index_email.mig\n", "");
    try f.expectQuery(indexes, "index_users_on_email,users_pkey");
    try f.expectRun(&.{"rollback"}, 0, "Rolled back db/20260102000000_index_email.mig\n", "");
    try f.expectQuery(indexes, "users_pkey");
    try f.expectVersions("20260101000000");
}

/// Writes `file` into the project, then migrates it, rolls it back and
/// migrates it again, checking `query` after each step: `up` while it is
/// applied, `down` once it is rolled back.
fn expectRoundTrip(f: *Fixture, file: [2][]const u8, query: []const u8, up: []const u8, down: []const u8) !void {
    const arena = f.arena_state.allocator();
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fs.path.join(arena, &.{ "db", file[0] }), .data = file[1] });
    const migrated = try std.fmt.allocPrint(arena, "Migrated db/{s}\n", .{file[0]});
    const rolled_back = try std.fmt.allocPrint(arena, "Rolled back db/{s}\n", .{file[0]});
    errdefer std.debug.print("round trip of {s}\n", .{file[0]});
    try f.expectRun(&.{"migrate"}, 0, migrated, "");
    try f.expectQuery(query, up);
    try f.expectRun(&.{"rollback"}, 0, rolled_back, "");
    try f.expectQuery(query, down);
    try f.expectRun(&.{"migrate"}, 0, migrated, "");
    try f.expectQuery(query, up);
}

const create_blog = [2][]const u8{
    "20260101000000_create_blog.mig",
    \\migration CreateBlog {
    \\  change {
    \\    create_table :users {
    \\      string :email, null: false
    \\      string :name, limit: 50
    \\      integer :role
    \\      datetime :seen_at
    \\    }
    \\    create_table :posts {
    \\      references :user
    \\      bigint :editor_id
    \\      string :title
    \\    }
    \\    add_index :posts, :title, name: "posts_title"
    \\  }
    \\}
    \\
};

test "alter operations migrate, roll back and migrate again" {
    var f: Fixture = try .init("alter_operations", &.{create_blog});
    defer f.deinit();
    try f.expectRun(&.{"migrate"}, 0, "Migrated db/20260101000000_create_blog.mig\n", "");
    try exec(f.conn, "INSERT INTO users (email) VALUES ('a@b.c')");

    // Relations and foreign keys named after the table, plus the custom
    // "posts_title", which keeps its name.
    const names =
        \\SELECT relname FROM pg_class WHERE relname ~ '(posts|articles)'
        \\UNION ALL SELECT conname FROM pg_constraint WHERE contype = 'f' ORDER BY 1
    ;
    try expectRoundTrip(&f, .{
        "20260102000000_rename_posts.mig",
        "migration RenamePosts { change { rename_table :posts, :articles } }\n",
    }, names, "articles,articles_id_seq,articles_pkey,fk_articles_on_user_id,index_articles_on_user_id,posts_title", "fk_posts_on_user_id,index_posts_on_user_id,posts,posts_id_seq,posts_pkey,posts_title");
    // The renamed sequence still numbers the rows.
    try exec(f.conn, "INSERT INTO articles (user_id, title) VALUES (1, 'Hello')");
    try f.expectQuery("SELECT id::text FROM articles", "1");

    // Operations that compute default names find the renamed ones.
    try expectRoundTrip(&f, .{
        "20260103000000_remove_user_index.mig",
        "migration RemoveUserIndex { change { remove_index :articles, :user_id } }\n",
    }, "SELECT indexname FROM pg_indexes WHERE tablename = 'articles' ORDER BY 1", "articles_pkey,posts_title", "articles_pkey,index_articles_on_user_id,posts_title");

    const types =
        \\SELECT column_name, data_type || coalesce('(' || character_maximum_length || ')', '')
        \\FROM information_schema.columns WHERE table_name = 'users' AND column_name IN ('name', 'role') ORDER BY 1
    ;
    try expectRoundTrip(&f, .{
        "20260104000000_widen_users.mig",
        \\migration WidenUsers {
        \\  change {
        \\    change_column :users, :name, :string, limit: 255, from: :string, from_limit: 50
        \\    change_column :users, :role, :bigint, from: :integer
        \\  }
        \\}
        \\
    }, types, "name character varying(255),role bigint", "name character varying(50),role integer");

    // Filling the nulls is not undone.
    const role_null =
        \\SELECT is_nullable, (SELECT string_agg(coalesce(role::text, 'null'), ',') FROM users)
        \\FROM information_schema.columns WHERE table_name = 'users' AND column_name = 'role'
    ;
    try f.expectQuery(role_null, "YES null");
    try expectRoundTrip(&f, .{
        "20260105000000_require_role.mig",
        "migration RequireRole { change { change_column_null :users, :role, false, default: 0 } }\n",
    }, role_null, "NO 0", "YES 0");

    const defaults =
        \\SELECT column_name, column_default FROM information_schema.columns
        \\WHERE table_name = 'users' AND column_name IN ('email', 'role', 'seen_at') ORDER BY 1
    ;
    try expectRoundTrip(&f, .{
        "20260106000000_user_defaults.mig",
        \\migration UserDefaults {
        \\  change {
        \\    change_column_default :users, :email, from: nil, to: "it's"
        \\    change_column_default :users, :role, from: nil, to: 1
        \\    change_column_default :users, :seen_at, from: nil, to: :now
        \\  }
        \\}
        \\
    }, defaults, "email 'it''s'::character varying,role 1,seen_at CURRENT_TIMESTAMP", "email NULL,role NULL,seen_at NULL");

    try expectRoundTrip(&f, .{
        "20260107000000_rename_title_index.mig",
        "migration RenameTitleIndex { change { rename_index :articles, \"posts_title\", \"articles_title\" } }\n",
    }, "SELECT indexname FROM pg_indexes WHERE tablename = 'articles' ORDER BY 1", "articles_pkey,articles_title", "articles_pkey,posts_title");

    const foreign_keys =
        \\SELECT conname || ' ' || pg_get_constraintdef(oid) FROM pg_constraint
        \\WHERE conrelid = 'articles'::regclass AND contype = 'f' ORDER BY conname
    ;
    const user_fk = "fk_articles_on_user_id FOREIGN KEY (user_id) REFERENCES users(id)";
    const editor_fk = "fk_articles_on_editor_id FOREIGN KEY (editor_id) REFERENCES users(id) ON DELETE SET NULL";
    try expectRoundTrip(&f, .{
        "20260108000000_add_editor_key.mig",
        "migration AddEditorKey { change { add_foreign_key :articles, :users, column: :editor_id, on_delete: :nullify } }\n",
    }, foreign_keys, editor_fk ++ "," ++ user_fk, user_fk);
    try expectRoundTrip(&f, .{
        "20260109000000_remove_user_key.mig",
        "migration RemoveUserKey { change { remove_foreign_key :articles, :users, column: :user_id } }\n",
    }, foreign_keys, editor_fk, editor_fk ++ "," ++ user_fk);

    // Back to the start, and forward again.
    try f.expectRun(&.{ "rollback", "--step", "8" }, 0,
        \\Rolled back db/20260109000000_remove_user_key.mig
        \\Rolled back db/20260108000000_add_editor_key.mig
        \\Rolled back db/20260107000000_rename_title_index.mig
        \\Rolled back db/20260106000000_user_defaults.mig
        \\Rolled back db/20260105000000_require_role.mig
        \\Rolled back db/20260104000000_widen_users.mig
        \\Rolled back db/20260103000000_remove_user_index.mig
        \\Rolled back db/20260102000000_rename_posts.mig
        \\
    , "");
    try f.expectQuery(names, "fk_posts_on_user_id,index_posts_on_user_id,posts,posts_id_seq,posts_pkey,posts_title");
    try f.expectQuery(types, "name character varying(50),role integer");
    try f.expectQuery(defaults, "email NULL,role NULL,seen_at NULL");
    try f.expectVersions("20260101000000");
    var o = try f.run(&.{"migrate"});
    defer o.deinit();
    try testing.expectEqual(0, o.code);
    try f.expectVersions("20260101000000,20260102000000,20260103000000,20260104000000,20260105000000,20260106000000,20260107000000,20260108000000,20260109000000");
    try f.expectQuery(foreign_keys, editor_fk);
}

test "rename_table fails when a renamed index name would be too long" {
    // 47 bytes: `fk_<to>_on_user_id` fits in 63, `index_<to>_on_user_id` does not.
    const long = "a" ** 47;
    var f: Fixture = try .init("rename_table_too_long", &.{create_blog});
    defer f.deinit();
    try f.expectRun(&.{"migrate"}, 0, "Migrated db/20260101000000_create_blog.mig\n", "");

    // Even without a transaction: the rename and its DO block are one
    // statement, which PostgreSQL runs as a whole.
    inline for (.{ "", ", transaction: false" }) |options| {
        try f.tmp.dir.writeFile(testing.io, .{
            .sub_path = "db/20260102000000_rename_posts.mig",
            .data = "migration RenamePosts" ++ options ++ " { change { rename_table :posts, :" ++ long ++ " } }\n",
        });
        var o = try f.run(&.{"migrate"});
        defer o.deinit();
        try testing.expectEqual(1, o.code);
        const message = "ffmig: db/20260102000000_rename_posts.mig: cannot rename index_posts_on_user_id to index_" ++ long ++
            "_on_user_id: longer than 63 bytes\nCONTEXT:  PL/pgSQL function inline_code_block line 25 at RAISE\n" ++
            "while running:\nALTER TABLE \"posts\" RENAME TO \"" ++ long ++ "\";\nDO $$\n";
        try testing.expectStringStartsWith(o.err.written(), message);
        try f.expectQuery("SELECT relname FROM pg_class WHERE relname ~ 'posts' ORDER BY 1", "index_posts_on_user_id,posts,posts_id_seq,posts_pkey,posts_title");
        try f.expectVersions("20260101000000");
    }
}

test "--to both ways, dry runs, redo and --fake" {
    const create_posts = [2][]const u8{
        "20260103000000_create_posts.mig",
        \\migration CreatePosts {
        \\  change {
        \\    create_table :posts {
        \\      string :title
        \\    }
        \\  }
        \\}
        \\
    };
    var f: Fixture = try .init("targets", &.{ create_users, add_role, create_posts });
    defer f.deinit();

    try f.expectRun(&.{ "migrate", "--to", "20260102000000" }, 0,
        \\Migrated db/20260101000000_create_users.mig
        \\Migrated db/20260102000000_add_role.mig
        \\
    , "");
    try f.expectVersions("20260101000000,20260102000000");
    try f.expectRun(&.{ "migrate", "--to", "20260109000000" }, 1, "",
        \\ffmig: no migration in db has version 20260109000000
        \\ffmig: nothing was migrated
        \\
    );

    // The dry run changes nothing, and what it prints does what migrate
    // would have done.
    var dry = try f.run(&.{ "migrate", "--dry-run" });
    defer dry.deinit();
    try testing.expectEqual(0, dry.code);
    try testing.expect(std.mem.startsWith(u8, dry.out.written(), "-- db/20260103000000_create_posts.mig\nBEGIN;\nCREATE TABLE \"posts\""));
    try f.expectColumns("posts", "");
    try f.expectVersions("20260101000000,20260102000000");
    try exec(f.conn, dry.out.written());
    try f.expectColumns("posts", "id,title");
    try f.expectRun(&.{"status"}, 0,
        \\up    YYYY-MM-DD HH:MM:SS UTC  db/20260101000000_create_users.mig
        \\up    YYYY-MM-DD HH:MM:SS UTC  db/20260102000000_add_role.mig
        \\up    YYYY-MM-DD HH:MM:SS UTC  db/20260103000000_create_posts.mig
        \\
    , "");

    var dry_down = try f.run(&.{ "rollback", "--to", "20260101000000", "--dry-run" });
    defer dry_down.deinit();
    try testing.expectEqual(0, dry_down.code);
    try testing.expect(std.mem.indexOf(u8, dry_down.out.written(), "DROP TABLE \"posts\"") != null);
    try f.expectVersions("20260101000000,20260102000000,20260103000000");

    try f.expectRun(&.{ "rollback", "--to", "20260101000000" }, 0,
        \\Rolled back db/20260103000000_create_posts.mig
        \\Rolled back db/20260102000000_add_role.mig
        \\
    , "");
    try f.expectVersions("20260101000000");
    try f.expectColumns("users", "id,email");
    try f.expectColumns("posts", "");

    try exec(f.conn, "INSERT INTO users (email) VALUES ('a@example.com')");
    try f.expectRun(&.{"redo"}, 0,
        \\Rolled back db/20260101000000_create_users.mig
        \\Migrated db/20260101000000_create_users.mig
        \\
    , "");
    // Dropped and created again.
    try f.expectQuery("SELECT count(*) FROM users", "0");
    try f.expectVersions("20260101000000");

    // Adopting a database whose schema is already there.
    try exec(f.conn, "DROP TABLE schema_migrations");
    try f.expectRun(&.{ "migrate", "--fake", "--to", "20260101000000" }, 0, "Recorded (not run) db/20260101000000_create_users.mig\n", "");
    try f.expectRun(&.{"status"}, 0,
        \\up    YYYY-MM-DD HH:MM:SS UTC  db/20260101000000_create_users.mig
        \\down                           db/20260102000000_add_role.mig
        \\down                           db/20260103000000_create_posts.mig
        \\
    , "");
    try f.expectRun(&.{ "migrate", "--strict" }, 0,
        \\Migrated db/20260102000000_add_role.mig
        \\Migrated db/20260103000000_create_posts.mig
        \\
    , "");
    try f.expectColumns("users", "id,email,role");
}

test "multi-column, partial and concurrent indexes, time zones and new defaults" {
    const create_accounts = [2][]const u8{
        "20260101000000_create_accounts.mig",
        \\migration CreateAccounts {
        \\  change {
        \\    create_table :accounts {
        \\      bigint :org_id
        \\      string :email
        \\      datetime :deleted_at, time_zone: true
        \\      uuid :token, null: false, default: :uuid
        \\      decimal :balance, precision: 10, scale: 2, default: 0.50
        \\    }
        \\    add_index :accounts, [:org_id, :email], unique: true, where: "deleted_at IS NULL"
        \\  }
        \\}
        \\
    };
    const index_token = [2][]const u8{
        "20260102000000_index_token.mig",
        \\migration IndexToken, transaction: false {
        \\  change {
        \\    add_index :accounts, :token, unique: true, algorithm: :concurrently
        \\  }
        \\}
        \\
    };
    var f: Fixture = try .init("indexes_and_types", &.{ create_accounts, index_token });
    defer f.deinit();

    try f.expectRun(&.{"migrate"}, 0,
        \\Migrated db/20260101000000_create_accounts.mig
        \\Migrated db/20260102000000_index_token.mig
        \\
    , "");
    const indexes = "SELECT indexdef FROM pg_indexes WHERE tablename = 'accounts' AND indexname LIKE 'index_%' ORDER BY indexname";
    try f.expectQuery(indexes, "CREATE UNIQUE INDEX index_accounts_on_org_id_and_email ON public.accounts USING btree (org_id, email) WHERE (deleted_at IS NULL)," ++
        "CREATE UNIQUE INDEX index_accounts_on_token ON public.accounts USING btree (token)");
    try f.expectQuery(
        "SELECT data_type FROM information_schema.columns WHERE table_name = 'accounts' AND column_name = 'deleted_at'",
        "timestamp with time zone",
    );
    try exec(f.conn, "INSERT INTO accounts (org_id, email) VALUES (1, 'a'), (1, 'b')");
    try f.expectQuery("SELECT count(DISTINCT token)::text, min(balance)::text FROM accounts", "2 0.50");
    // The partial index leaves deleted rows out.
    try exec(f.conn, "UPDATE accounts SET deleted_at = now()");
    try exec(f.conn, "INSERT INTO accounts (org_id, email) VALUES (1, 'a')");

    try f.expectRun(&.{"rollback"}, 0, "Rolled back db/20260102000000_index_token.mig\n", "");
    try f.expectQuery(indexes, "CREATE UNIQUE INDEX index_accounts_on_org_id_and_email ON public.accounts USING btree (org_id, email) WHERE (deleted_at IS NULL)");
    try f.expectRun(&.{"rollback"}, 0, "Rolled back db/20260101000000_create_accounts.mig\n", "");
    try f.expectColumns("accounts", "");
}
