//! What the commands that touch the database share: loading the config
//! and the migration files, connecting, setting the timeouts, taking the
//! migration lock, reading the recorded versions and checksums, and
//! running one migration's statements together with its tracking row.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const Env = @import("root.zig").Env;
const check = @import("check.zig");
const config = @import("../utils/config.zig");
const fs = @import("../utils/fs.zig");
const mig = @import("../mig/root.zig");
const sql = @import("../sql/root.zig");
const db = @import("../db/root.zig");
const migrations = @This();

pub const File = struct {
    /// File name inside the migrations directory.
    name: []const u8,
    /// Its `YYYYMMDDHHMMSS` prefix.
    version: []const u8,
};

/// The configured migrations directory and its files.
pub const Project = struct {
    /// Migrations directory, as configured.
    path: []const u8,
    dir: Io.Dir,
    /// Database URL as configured, before `${VAR}` expansion.
    url: ?[]const u8,
    /// `[database] schema`, the schema that holds the tables.
    schema: ?[]const u8,
    timeouts: config.Timeouts,
    /// In version order.
    files: []const File,

    /// Loads `ffmig.toml` and lists the migrations directory. Reports
    /// problems to `err` and returns null. Everything is allocated in
    /// `arena`.
    pub fn load(env: Env, arena: Allocator, err: *Writer) Writer.Error!?Project {
        const cfg = try loadConfig(env, arena, err) orelse return null;
        var dir = env.cwd.openDir(env.io, cfg.path, .{ .iterate = true }) catch |e| {
            try err.print("ffmig: cannot open directory {s}: {t}\n", .{ cfg.path, e });
            return null;
        };
        const files = try listFiles(env.io, arena, dir, cfg.path, err) orelse {
            dir.close(env.io);
            return null;
        };
        return .{ .path = cfg.path, .dir = dir, .url = cfg.url, .schema = cfg.schema, .timeouts = cfg.timeouts, .files = files };
    }

    /// Connects to the project's database (see `connect`) and switches to
    /// its schema, if it names one (see `useSchema`).
    pub fn connect(p: Project, env: Env, arena: Allocator, err: *Writer) Writer.Error!?Connection {
        const conn = try migrations.connect(env, arena, p.url, err) orelse return null;
        if (!try useSchema(arena, conn, p.schema, err)) {
            conn.db.close();
            return null;
        }
        return conn;
    }

    fn listFiles(io: Io, arena: Allocator, dir: Io.Dir, path: []const u8, err: *Writer) Writer.Error!?[]const File {
        const names = fs.listMigrations(io, dir, arena) catch |e| {
            switch (e) {
                error.OutOfMemory => try outOfMemory(err),
                else => try err.print("ffmig: cannot read directory {s}: {t}\n", .{ path, e }),
            }
            return null;
        };
        const files = arena.alloc(File, names.len) catch {
            try outOfMemory(err);
            return null;
        };
        var ok = true;
        for (names, files, 0..) |name, *f, i| {
            const version = fs.migrationVersion(name) orelse {
                try err.print("ffmig: {s}/{s}: file name must be <YYYYMMDDHHMMSS>_<name>.mig\n", .{ path, name });
                ok = false;
                f.* = .{ .name = name, .version = "" };
                continue;
            };
            // Sorted by name, so equal versions are adjacent.
            if (i > 0 and std.mem.eql(u8, files[i - 1].version, version)) {
                try err.print("ffmig: {s}/{s} and {s} have the same version {s}\n", .{ path, files[i - 1].name, name, version });
                ok = false;
            }
            f.* = .{ .name = name, .version = version };
        }
        return if (ok) files else null;
    }

    pub fn close(p: *Project, io: Io) void {
        p.dir.close(io);
    }

    /// `<path>/<name>`, for messages.
    pub fn shown(p: Project, arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
        return std.fs.path.join(arena, &.{ p.path, name });
    }

    /// The file with `version`, if any.
    pub fn find(p: Project, version: []const u8) ?File {
        for (p.files) |f| if (std.mem.eql(u8, f.version, version)) return f;
        return null;
    }

    /// Reads `file` and returns its shown path and source, reporting
    /// failure to `err`.
    fn read(p: Project, io: Io, arena: Allocator, file: File, err: *Writer) Writer.Error!?struct { []const u8, []const u8 } {
        const path = p.shown(arena, file.name) catch {
            try outOfMemory(err);
            return null;
        };
        const source = p.dir.readFileAlloc(io, file.name, arena, .limited(check.max_source_size)) catch |e| {
            try err.print("ffmig: cannot read {s}: {t}\n", .{ path, e });
            return null;
        };
        return .{ path, source };
    }

    /// Reads, parses and lowers `file`, and checks that `dialect` can run
    /// it both ways, reporting errors like `ffmig check`.
    pub fn parse(p: Project, io: Io, arena: Allocator, file: File, dialect: sql.Dialect, err: *Writer) Writer.Error!?Parsed {
        const path, const source = try p.read(io, arena, file, err) orelse return null;
        var diag: mig.Diagnostic = .{};
        const migration = mig.parseMigration(arena, source, &diag) catch |e| {
            switch (e) {
                error.OutOfMemory => try outOfMemory(err),
                error.InvalidSyntax, error.InvalidMigration => try check.report(err, path, source, diag.span, "{s}", .{diag.message}),
            }
            return null;
        };
        if (!try supported(dialect, migration, path, source, err)) return null;
        return .{ .file = file, .path = path, .source = source, .checksum = checksum(source), .migration = migration };
    }

    /// Whether `file` has changed since it was applied as `row`: false
    /// when `row` has no checksum to compare with. Reports a file that
    /// cannot be read to `err` and returns null.
    pub fn changed(p: Project, io: Io, arena: Allocator, file: File, row: Applied, err: *Writer) Writer.Error!?bool {
        const recorded = row.checksum orelse return false;
        _, const source = try p.read(io, arena, file, err) orelse return null;
        return !std.mem.eql(u8, &checksum(source), recorded);
    }
};

/// Whether `dialect` can run every operation of `m`, in either
/// direction. Reports the first one it cannot like `ffmig check`. The
/// operations a `change` derives for `down` are always supported.
pub fn supported(dialect: sql.Dialect, m: mig.ast.Migration, path: []const u8, source: []const u8, err: *Writer) Writer.Error!bool {
    const sections: [2][]const mig.ast.Operation = switch (m.body) {
        .change => |ops| .{ ops, &.{} },
        .up_down => |b| .{ b.up, b.down },
    };
    for (sections) |ops| for (ops) |op| {
        const message = sql.unsupported(dialect, op) orelse continue;
        try check.report(err, path, source, op.span, "{s}", .{message});
        return false;
    };
    return true;
}

/// SHA-256 of a migration file, in lowercase hex.
pub const Checksum = [64]u8;

/// The checksum recorded for a migration when it is applied, so that
/// `status` and `migrate` can tell when its file was edited afterwards.
/// It hashes the source, not the parsed migration, so that a new ffmig
/// reading the same file differently flags nothing. `\r\n` counts as
/// `\n`, so a checkout with Windows line endings flags nothing either.
pub fn checksum(source: []const u8) Checksum {
    var h: std.crypto.hash.sha2.Sha256 = .init(.{});
    var rest = source;
    while (std.mem.indexOf(u8, rest, "\r\n")) |i| {
        h.update(rest[0..i]);
        rest = rest[i + 1 ..];
    }
    h.update(rest);
    return std.fmt.bytesToHex(h.finalResult(), .lower);
}

/// Loads the config file (`ffmig.toml` or `--config`), reporting
/// problems to `err` and returning null. Its `path` comes back relative
/// to `env.cwd`, not to the config file.
pub fn loadConfig(env: Env, arena: Allocator, err: *Writer) Writer.Error!?config.Config {
    var diag: config.Diagnostics = .{};
    var cfg = config.load(env.io, env.cwd, env.config, arena, &diag) catch |e| {
        switch (e) {
            error.FileNotFound => try err.print("ffmig: {s} not found; run 'ffmig init' first\n", .{env.config}),
            error.InvalidSyntax => try err.print("ffmig: {s}:{d}: invalid syntax\n", .{ env.config, diag.line }),
            error.InvalidTimeout => try err.print("ffmig: {s}:{d}: {s} must be a duration such as \"5s\" or \"500ms\", or \"0\" for no limit\n", .{ env.config, diag.line, diag.key }),
            else => try err.print("ffmig: cannot read {s}: {t}\n", .{ env.config, e }),
        }
        return null;
    };
    cfg.path = config.resolvePath(arena, env.config, cfg.path) catch {
        try outOfMemory(err);
        return null;
    };
    return cfg;
}

/// A migration file after parsing, with what error reports need.
pub const Parsed = struct {
    file: File,
    /// `<migrations dir>/<name>`.
    path: []const u8,
    source: []const u8,
    checksum: Checksum,
    migration: mig.ast.Migration,

    /// The operations that migrating runs.
    pub fn up(p: Parsed) []const mig.ast.Operation {
        return switch (p.migration.body) {
            .change => |ops| ops,
            .up_down => |b| b.up,
        };
    }

    /// The tracking statement that records it as applied.
    pub fn insert(p: *const Parsed) sql.Tracking {
        return .{ .insert = .{ .version = p.file.version, .checksum = &p.checksum } };
    }
};

/// A row of the tracking table.
pub const Applied = struct {
    version: []const u8,
    /// Null for rows written before ffmig recorded checksums.
    checksum: ?[]const u8,
    /// Seconds since 1970, UTC. Null for rows written before ffmig
    /// recorded it.
    applied_at: ?i64,
};

/// Files whose version is not in `applied`, in file order. `applied` must
/// be sorted, as `readApplied` returns it.
pub fn pending(arena: Allocator, files: []const File, applied: []const Applied) Allocator.Error![]const File {
    var result: std.ArrayList(File) = .empty;
    for (files) |f| {
        if (std.sort.binarySearch(Applied, applied, f.version, orderVersion) == null) try result.append(arena, f);
    }
    return result.items;
}

fn orderVersion(key: []const u8, item: Applied) std.math.Order {
    return std.mem.order(u8, key, item.version);
}

pub const Connection = struct { db: db.Db, dialect: db.Dialect };

/// Picks the database URL and connects. Reports problems to `err` and
/// returns null. Never prints the URL, which may hold a password.
pub fn connect(env: Env, arena: Allocator, configured: ?[]const u8, err: *Writer) Writer.Error!?Connection {
    const resolved = try resolveUrl(env, arena, configured, err) orelse return null;
    return open(arena, resolved, err);
}

/// The environment variable that overrides the config's database URL.
pub const url_variable = "FFMIG_DATABASE_URL";

/// A database URL after `${VAR}` expansion, with the dialect its scheme
/// selects.
pub const Url = struct {
    url: []const u8,
    dialect: db.Dialect,
    /// Where the URL came from, for messages: `--url`, the variable or
    /// the config file.
    from: []const u8,
};

/// The first half of `connect`: picks the URL, from `--url`, else a
/// non-empty `FFMIG_DATABASE_URL`, else `configured` (the config's) with
/// its `${VAR}`s expanded, and picks its dialect. The overrides are
/// taken as given.
pub fn resolveUrl(env: Env, arena: Allocator, configured: ?[]const u8, err: *Writer) Writer.Error!?Url {
    const empty: std.process.Environ.Map = .init(arena);
    const environ = env.environ orelse &empty;
    const url: []const u8, const from: []const u8 = if (env.url) |u|
        .{ u, "--url" }
    else if (nonEmpty(environ.get(url_variable))) |u|
        .{ u, url_variable }
    else from_config: {
        const raw = configured orelse {
            try err.print("ffmig: no database url; set [database] url in {s} or {s}, or pass --url\n", .{ env.config, url_variable });
            return null;
        };
        var missing: []const u8 = "";
        const expanded = config.expandEnv(arena, raw, environ, &missing) catch |e| {
            switch (e) {
                error.OutOfMemory => try outOfMemory(err),
                error.UndefinedVariable => try err.print("ffmig: {s} is not set (used by the database url in {s})\n", .{ missing, env.config }),
                error.InvalidSyntax => try err.print("ffmig: database url in {s}: unterminated or empty ${{...}}\n", .{env.config}),
            }
            return null;
        };
        if (expanded.len == 0) {
            try err.print("ffmig: the database url in {s} is empty\n", .{env.config});
            return null;
        }
        break :from_config .{ expanded, env.config };
    };
    const dialect = db.dialectFor(url) orelse {
        const scheme_end = std.mem.indexOf(u8, url, "://") orelse 0;
        if (scheme_end == 0) {
            try err.writeAll("ffmig: the database url must start with a scheme such as postgres://\n");
        } else {
            try err.print("ffmig: unsupported database '{s}'; supported: postgres\n", .{url[0..scheme_end]});
        }
        return null;
    };
    return .{ .url = url, .dialect = dialect, .from = from };
}

fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const v = s orelse return null;
    return if (v.len == 0) null else v;
}

/// The second half of `connect`.
pub fn open(arena: Allocator, url: Url, err: *Writer) Writer.Error!?Connection {
    var diag: db.Diagnostic = .{};
    const conn = db.connect(arena, url.dialect, url.url, &diag) catch |e| {
        try dbError(e, err, "cannot connect to the database", diag);
        return null;
    };
    return .{ .db = conn, .dialect = url.dialect };
}

/// Makes `schema` the one that holds the tables for the rest of the
/// session, after checking that it exists: ffmig never creates it.
/// Does nothing when `schema` is null. Reports failure to `err` and
/// returns false.
pub fn useSchema(arena: Allocator, conn: Connection, schema: ?[]const u8, err: *Writer) Writer.Error!bool {
    const name = schema orelse return true;
    var exists: Writer.Allocating = .init(arena);
    var use: Writer.Allocating = .init(arena);
    sql.writeSchema(conn.dialect, .{ .exists = name }, &exists.writer) catch return oomFalse(err);
    sql.writeSchema(conn.dialect, .{ .use = name }, &use.writer) catch return oomFalse(err);
    var diag: db.Diagnostic = .{};
    const rows = conn.db.query(arena, exists.written(), &diag) catch |e| {
        try dbError(e, err, "cannot look up the schema", diag);
        return false;
    };
    if (rows.len == 0) {
        try err.print("ffmig: schema '{s}' (the [database] schema) does not exist; create it first\n", .{name});
        return false;
    }
    conn.db.exec(use.written(), &diag) catch |e| {
        try dbError(e, err, "cannot switch to the schema", diag);
        return false;
    };
    return true;
}

fn oomFalse(err: *Writer) Writer.Error!bool {
    try outOfMemory(err);
    return false;
}

/// Sets the configured timeouts for the rest of the session. Reports
/// failure to `err` and returns false.
pub fn setTimeouts(arena: Allocator, conn: Connection, timeouts: config.Timeouts, err: *Writer) Writer.Error!bool {
    if (timeouts.lock) |ms| if (!try setTimeout(arena, conn, .{ .lock = ms }, err)) return false;
    if (timeouts.statement) |ms| if (!try setTimeout(arena, conn, .{ .statement = ms }, err)) return false;
    return true;
}

fn setTimeout(arena: Allocator, conn: Connection, t: sql.Timeout, err: *Writer) Writer.Error!bool {
    var statement: Writer.Allocating = .init(arena);
    sql.writeTimeout(conn.dialect, t, &statement.writer) catch {
        try outOfMemory(err);
        return false;
    };
    var diag: db.Diagnostic = .{};
    conn.db.exec(statement.written(), &diag) catch |e| {
        const context = switch (t) {
            .lock => "cannot set lock_timeout",
            .statement => "cannot set statement_timeout",
        };
        try dbError(e, err, context, diag);
        return false;
    };
    return true;
}

/// Seconds that `migrate` and `rollback` wait for the lock by default.
pub const default_lock_wait = 60;

/// How often `lock` asks again while another run holds the lock.
const lock_poll: Io.Duration = .fromMilliseconds(500);

/// Parses a `--lock-wait` value: whole seconds, 0 for no wait.
pub fn parseLockWait(arg: []const u8) ?u32 {
    return std.fmt.parseInt(u32, arg, 10) catch null;
}

/// Takes the lock that keeps two runs on one database apart, waiting up
/// to `wait` seconds for another run to release it. Polls instead of
/// blocking, so the wait is bounded, says once that it is waiting, and
/// does not depend on the session's `lock_timeout`. Reports failure to
/// `err` and returns false. Does nothing for dialects without
/// `advisory_lock`. The caller releases the lock with `unlock`.
pub fn lock(io: Io, arena: Allocator, conn: Connection, wait: u32, err: *Writer) Writer.Error!bool {
    if (!sql.capabilities(conn.dialect).advisory_lock) return true;
    const statement = lockSql(arena, conn.dialect, .try_lock) catch {
        try outOfMemory(err);
        return false;
    };
    const deadline: Io.Clock.Timestamp = .fromNow(io, .{ .raw = .fromSeconds(wait), .clock = .awake });
    var waiting = false;
    while (true) {
        var diag: db.Diagnostic = .{};
        const rows = conn.db.query(arena, statement, &diag) catch |e| {
            try dbError(e, err, "cannot take the migration lock", diag);
            return false;
        };
        if (rows.len != 0) return true;
        const left = deadline.durationFromNow(io).raw;
        if (left.nanoseconds <= 0) break;
        if (!waiting) {
            waiting = true;
            try err.writeAll("Waiting for another ffmig run to finish...\n");
            try err.flush();
        }
        io.sleep(if (left.nanoseconds < lock_poll.nanoseconds) left else lock_poll, .awake) catch break;
    }
    try err.print("ffmig: another ffmig run holds the lock on this database; gave up after {d}s (see --lock-wait)\n", .{wait});
    return false;
}

/// Releases the lock that `lock` took. Failures are ignored: the lock
/// goes away with the connection anyway.
pub fn unlock(arena: Allocator, conn: Connection) void {
    if (!sql.capabilities(conn.dialect).advisory_lock) return;
    const statement = lockSql(arena, conn.dialect, .unlock) catch return;
    var diag: db.Diagnostic = .{};
    conn.db.exec(statement, &diag) catch {};
}

fn lockSql(arena: Allocator, dialect: db.Dialect, l: sql.Lock) Allocator.Error![]const u8 {
    var w: Writer.Allocating = .init(arena);
    sql.writeLock(dialect, l, &w.writer) catch return error.OutOfMemory;
    return w.written();
}

/// Creates the tracking table if it is missing, adds the columns that an
/// older ffmig did not create, and returns the recorded rows, sorted by
/// version.
pub fn readApplied(arena: Allocator, conn: Connection, err: *Writer) Writer.Error!?[]const Applied {
    var diag: db.Diagnostic = .{};
    const create = trackingSql(arena, conn.dialect, .create) catch return oomNull(err);
    const current = trackingSql(arena, conn.dialect, .current) catch return oomNull(err);
    const upgrade = trackingSql(arena, conn.dialect, .upgrade) catch return oomNull(err);
    const select = trackingSql(arena, conn.dialect, .select) catch return oomNull(err);
    conn.db.exec(create, &diag) catch |e| {
        try dbError(e, err, "cannot create " ++ sql.tracking_table, diag);
        return null;
    };
    const found = conn.db.query(arena, current, &diag) catch |e| {
        try dbError(e, err, "cannot read " ++ sql.tracking_table, diag);
        return null;
    };
    if (found.len == 0) conn.db.exec(upgrade, &diag) catch |e| {
        try dbError(e, err, "cannot upgrade " ++ sql.tracking_table, diag);
        return null;
    };
    const rows = conn.db.query(arena, select, &diag) catch |e| {
        try dbError(e, err, "cannot read " ++ sql.tracking_table, diag);
        return null;
    };
    const applied = arena.alloc(Applied, rows.len) catch return oomNull(err);
    for (rows, applied) |row, *a| a.* = .{
        // The primary key.
        .version = row[0].?,
        .checksum = row[1],
        .applied_at = if (row[2]) |at| std.fmt.parseInt(i64, at, 10) catch null else null,
    };
    // The database's collation may not sort like bytes do.
    std.mem.sortUnstable(Applied, applied, {}, lessThan);
    return applied;
}

fn lessThan(_: void, a: Applied, b: Applied) bool {
    return std.mem.lessThan(u8, a.version, b.version);
}

/// One statement of a migration as `apply` sends it, without its `;`.
pub const Statement = struct {
    text: []const u8,
    /// Whether a script must put the `;` on a line of its own (see
    /// `sql.semicolonOnOwnLine`).
    own_line: bool = false,
};

/// What `apply` sends for a migration, without `BEGIN` and `COMMIT`: the
/// statements of `ops` (see `sql.Statements`), then `tracking`. Both
/// `apply` and `show` use it, so a dry run prints what a real run sends.
pub fn statements(
    arena: Allocator,
    dialect: sql.Dialect,
    ops: []const mig.ast.Operation,
    tracking: sql.Tracking,
) Allocator.Error![]const Statement {
    var list: std.ArrayList(Statement) = .empty;
    var it: sql.Statements = .{ .ops = ops };
    while (it.next()) |op| {
        var w: Writer.Allocating = .init(arena);
        sql.writeStatement(dialect, op, &w.writer) catch return error.OutOfMemory;
        try list.append(arena, .{ .text = w.written(), .own_line = sql.semicolonOnOwnLine(op) });
    }
    try list.append(arena, .{ .text = try trackingSql(arena, dialect, tracking) });
    return list.items;
}

/// Whether `apply` runs a migration inside a transaction: when it asks
/// for one (`transaction:`) and the dialect's DDL is transactional.
fn transactional(dialect: sql.Dialect, transaction: bool) bool {
    return transaction and sql.capabilities(dialect).transactional_ddl;
}

/// Runs `ops` and then the `tracking` statement, inside one transaction
/// when `transaction` is set (the migration's `transaction:`) and the
/// dialect's DDL is transactional. On failure, reports the statement and
/// the database's message, rolls back, and returns false. Without a
/// transaction, the statements that ran before the failing one stay, and
/// the tracking statement does not run.
pub fn apply(
    arena: Allocator,
    conn: Connection,
    path: []const u8,
    ops: []const mig.ast.Operation,
    tracking: sql.Tracking,
    transaction: bool,
    err: *Writer,
) Writer.Error!bool {
    const list = statements(arena, conn.dialect, ops, tracking) catch {
        try outOfMemory(err);
        return false;
    };
    const in_transaction = transactional(conn.dialect, transaction);
    var diag: db.Diagnostic = .{};
    if (in_transaction) conn.db.exec("BEGIN", &diag) catch |e| {
        try dbError(e, err, path, diag);
        return false;
    };

    for (list, 0..) |statement, ran| {
        conn.db.exec(statement.text, &diag) catch |e| {
            try dbError(e, err, path, diag);
            try err.print("while running:\n{s};\n", .{statement.text});
            if (in_transaction) {
                // Reported after the original error: without a working
                // rollback, what the migration changed is unknown.
                var rollback_diag: db.Diagnostic = .{};
                conn.db.exec("ROLLBACK", &rollback_diag) catch |re| try dbError(re, err, "rollback failed", rollback_diag);
            } else if (ran > 0) {
                try err.print("ffmig: {s} runs without a transaction, so the statements before this one were not undone\n", .{path});
            }
            return false;
        };
    }

    if (in_transaction) conn.db.exec("COMMIT", &diag) catch |e| {
        try dbError(e, err, path, diag);
        return false;
    };
    return true;
}

/// Writes to `out` what `apply` would send for the same arguments, as a
/// script under a `-- <path>` header, `BEGIN` and `COMMIT` included. Runs
/// nothing. Reports running out of memory to `err` and returns false.
pub fn show(
    arena: Allocator,
    dialect: sql.Dialect,
    path: []const u8,
    ops: []const mig.ast.Operation,
    tracking: sql.Tracking,
    transaction: bool,
    out: *Writer,
    err: *Writer,
) Writer.Error!bool {
    const list = statements(arena, dialect, ops, tracking) catch {
        try outOfMemory(err);
        return false;
    };
    const in_transaction = transactional(dialect, transaction);
    try out.print("-- {s}\n", .{path});
    if (in_transaction) try out.writeAll("BEGIN;\n");
    for (list) |statement| {
        try out.writeAll(statement.text);
        try out.writeAll(if (statement.own_line) "\n;\n" else ";\n");
    }
    if (in_transaction) try out.writeAll("COMMIT;\n");
    return true;
}

fn trackingSql(arena: Allocator, dialect: db.Dialect, t: sql.Tracking) Allocator.Error![]const u8 {
    var w: Writer.Allocating = .init(arena);
    sql.writeTracking(dialect, t, &w.writer) catch return error.OutOfMemory;
    return w.written();
}

/// Reports a database error prefixed with `context`.
pub fn dbError(e: db.Error, err: *Writer, context: []const u8, diag: db.Diagnostic) Writer.Error!void {
    switch (e) {
        error.OutOfMemory => try outOfMemory(err),
        error.DatabaseError => try err.print("ffmig: {s}: {s}\n", .{ context, diag.message }),
    }
}

fn oomNull(err: *Writer) Writer.Error!?[]const Applied {
    try outOfMemory(err);
    return null;
}

pub fn outOfMemory(err: *Writer) Writer.Error!void {
    try err.writeAll("ffmig: out of memory\n");
}
