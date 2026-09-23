//! What the commands that touch the database share: loading the config
//! and the migration files, connecting, reading the recorded versions,
//! and running one migration's statements together with its tracking row.

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
        return .{ .path = cfg.path, .dir = dir, .url = cfg.url, .files = files };
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

    /// Reads, parses and lowers `file`, reporting errors like `ffmig check`.
    pub fn parse(p: Project, io: Io, arena: Allocator, file: File, err: *Writer) Writer.Error!?Parsed {
        const path = p.shown(arena, file.name) catch {
            try outOfMemory(err);
            return null;
        };
        const source = p.dir.readFileAlloc(io, file.name, arena, .limited(check.max_source_size)) catch |e| {
            try err.print("ffmig: cannot read {s}: {t}\n", .{ path, e });
            return null;
        };
        var diag: mig.Diagnostic = .{};
        const migration = mig.parseMigration(arena, source, &diag) catch |e| {
            switch (e) {
                error.OutOfMemory => try outOfMemory(err),
                error.InvalidSyntax, error.InvalidMigration => try check.report(err, path, source, diag.span, "{s}", .{diag.message}),
            }
            return null;
        };
        return .{ .file = file, .path = path, .source = source, .migration = migration };
    }
};

/// Loads `ffmig.toml`, reporting problems to `err` and returning null.
pub fn loadConfig(env: Env, arena: Allocator, err: *Writer) Writer.Error!?config.Config {
    var diag: config.Diagnostics = .{};
    return config.load(env.io, env.cwd, arena, &diag) catch |e| {
        switch (e) {
            error.FileNotFound => try err.print("ffmig: {s} not found; run 'ffmig init' first\n", .{config.file_name}),
            error.InvalidSyntax => try err.print("ffmig: {s}:{d}: invalid syntax\n", .{ config.file_name, diag.line }),
            else => try err.print("ffmig: cannot read {s}: {t}\n", .{ config.file_name, e }),
        }
        return null;
    };
}

/// A migration file after parsing, with what error reports need.
pub const Parsed = struct {
    file: File,
    /// `<migrations dir>/<name>`.
    path: []const u8,
    source: []const u8,
    migration: mig.ast.Migration,
};

/// Files whose version is not in `applied`, in file order. `applied` must
/// be sorted, as `appliedVersions` returns it.
pub fn pending(arena: Allocator, files: []const File, applied: []const []const u8) Allocator.Error![]const File {
    var result: std.ArrayList(File) = .empty;
    for (files) |f| {
        if (std.sort.binarySearch([]const u8, applied, f.version, orderVersion) == null) try result.append(arena, f);
    }
    return result.items;
}

fn orderVersion(key: []const u8, item: []const u8) std.math.Order {
    return std.mem.order(u8, key, item);
}

pub const Connection = struct { db: db.Db, dialect: db.Dialect };

/// Expands `${VAR}`s in `url` from the environment and connects. Reports
/// problems to `err` and returns null. Never prints the URL, which may
/// hold a password.
pub fn connect(env: Env, arena: Allocator, url: ?[]const u8, err: *Writer) Writer.Error!?Connection {
    const resolved = try resolveUrl(env, arena, url, err) orelse return null;
    return open(arena, resolved, err);
}

/// A database URL after `${VAR}` expansion, with the dialect its scheme
/// selects.
pub const Url = struct { url: []const u8, dialect: db.Dialect };

/// The first half of `connect`: expands `url` and picks its dialect.
pub fn resolveUrl(env: Env, arena: Allocator, url: ?[]const u8, err: *Writer) Writer.Error!?Url {
    const raw = url orelse {
        try err.print("ffmig: no database url in {s}; set [database] url\n", .{config.file_name});
        return null;
    };
    const empty: std.process.Environ.Map = .init(arena);
    var missing: []const u8 = "";
    const expanded = config.expandEnv(arena, raw, env.environ orelse &empty, &missing) catch |e| {
        switch (e) {
            error.OutOfMemory => try outOfMemory(err),
            error.UndefinedVariable => try err.print("ffmig: {s} is not set (used by the database url in {s})\n", .{ missing, config.file_name }),
            error.InvalidSyntax => try err.print("ffmig: database url in {s}: unterminated or empty ${{...}}\n", .{config.file_name}),
        }
        return null;
    };
    if (expanded.len == 0) {
        try err.print("ffmig: the database url in {s} is empty\n", .{config.file_name});
        return null;
    }
    const dialect = db.dialectFor(expanded) orelse {
        const scheme_end = std.mem.indexOf(u8, expanded, "://") orelse 0;
        if (scheme_end == 0) {
            try err.writeAll("ffmig: the database url must start with a scheme such as postgres://\n");
        } else {
            try err.print("ffmig: unsupported database '{s}'; supported: postgres\n", .{expanded[0..scheme_end]});
        }
        return null;
    };
    return .{ .url = expanded, .dialect = dialect };
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

/// Creates the tracking table if it is missing and returns the recorded
/// versions, sorted.
pub fn appliedVersions(arena: Allocator, conn: Connection, err: *Writer) Writer.Error!?[]const []const u8 {
    var diag: db.Diagnostic = .{};
    const create = trackingSql(arena, conn.dialect, .create) catch return oomNull(err);
    const select = trackingSql(arena, conn.dialect, .select) catch return oomNull(err);
    conn.db.exec(create, &diag) catch |e| {
        try dbError(e, err, "cannot create " ++ sql.tracking_table, diag);
        return null;
    };
    const versions = conn.db.query(arena, select, &diag) catch |e| {
        try dbError(e, err, "cannot read " ++ sql.tracking_table, diag);
        return null;
    };
    // The database's collation may not sort like bytes do.
    std.mem.sortUnstable([]const u8, @constCast(versions), {}, lessThan);
    return versions;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Runs `ops` and then the `tracking` statement, inside one transaction
/// when the dialect's DDL is transactional. On failure, reports the
/// statement and the database's message, rolls back, and returns false.
pub fn apply(
    arena: Allocator,
    conn: Connection,
    path: []const u8,
    ops: []const mig.ast.Operation,
    tracking: sql.Tracking,
    err: *Writer,
) Writer.Error!bool {
    const transactional = sql.capabilities(conn.dialect).transactional_ddl;
    var diag: db.Diagnostic = .{};
    if (transactional) conn.db.exec("BEGIN", &diag) catch |e| {
        try dbError(e, err, path, diag);
        return false;
    };

    var statement: Writer.Allocating = .init(arena);
    for (0..ops.len + 1) |i| {
        statement.clearRetainingCapacity();
        const w = &statement.writer;
        const written = if (i < ops.len) sql.writeStatement(conn.dialect, ops[i], w) else sql.writeTracking(conn.dialect, tracking, w);
        written catch {
            try outOfMemory(err);
            return false;
        };
        conn.db.exec(statement.written(), &diag) catch |e| {
            try dbError(e, err, path, diag);
            try err.print("while running:\n{s};\n", .{statement.written()});
            if (transactional) conn.db.exec("ROLLBACK", &diag) catch {};
            return false;
        };
    }

    if (transactional) conn.db.exec("COMMIT", &diag) catch |e| {
        try dbError(e, err, path, diag);
        return false;
    };
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

fn oomNull(err: *Writer) Writer.Error!?[]const []const u8 {
    try outOfMemory(err);
    return null;
}

pub fn outOfMemory(err: *Writer) Writer.Error!void {
    try err.writeAll("ffmig: out of memory\n");
}
