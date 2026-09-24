//! What `create`, `drop`, `protect` and `unprotect` share: finding the
//! database that the database url names and connecting to the maintenance
//! database to act on it, since `create` and `drop` cannot run while
//! connected to the database itself.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Env = @import("root.zig").Env;
const migrations = @import("migrations.zig");
const sql = @import("../sql/root.zig");
const db = @import("../db/root.zig");

pub const Target = struct {
    /// The database the configured URL names.
    name: []const u8,
    /// To the maintenance database on the same server.
    conn: migrations.Connection,
};

/// Loads the config and connects to the maintenance database. Reports
/// problems to `err` and returns null.
pub fn connect(env: Env, arena: Allocator, err: *Writer) Writer.Error!?Target {
    const cfg = try migrations.loadConfig(env, arena, err) orelse return null;
    const url = try migrations.resolveUrl(env, arena, cfg.url, err) orelse return null;
    const admin = db.admin(arena, url.dialect, url.url) catch |e| {
        switch (e) {
            error.OutOfMemory => try migrations.outOfMemory(err),
            error.NoDatabaseName => try err.print("ffmig: the database url from {s} must name a database in its path, e.g. postgres://localhost/app_dev\n", .{url.from}),
        }
        return null;
    };
    const conn = try migrations.open(arena, .{ .url = admin.url, .dialect = url.dialect, .from = url.from }, err) orelse return null;
    return .{ .name = admin.database, .conn = conn };
}

/// Whether an `exists` or `protected` statement finds a row, or null
/// after reporting an error.
pub fn check(arena: Allocator, conn: migrations.Connection, d: sql.Database, err: *Writer) Writer.Error!?bool {
    var diag: db.Diagnostic = .{};
    const statement = write(arena, conn.dialect, d) catch {
        try migrations.outOfMemory(err);
        return null;
    };
    const rows = conn.db.query(arena, statement, &diag) catch |e| {
        try migrations.dbError(e, err, "cannot look up the database", diag);
        return null;
    };
    return rows.len != 0;
}

/// Runs a statement that changes a database. Reports a failure and returns false.
pub fn exec(arena: Allocator, conn: migrations.Connection, d: sql.Database, err: *Writer) Writer.Error!bool {
    var diag: db.Diagnostic = .{};
    const statement = write(arena, conn.dialect, d) catch {
        try migrations.outOfMemory(err);
        return false;
    };
    conn.db.exec(statement, &diag) catch |e| {
        switch (e) {
            error.OutOfMemory => try migrations.outOfMemory(err),
            error.DatabaseError => try err.print("ffmig: cannot {t} the database: {s}\n", .{ d, diag.message }),
        }
        return false;
    };
    return true;
}

fn write(arena: Allocator, dialect: db.Dialect, d: sql.Database) Allocator.Error![]const u8 {
    var w: Writer.Allocating = .init(arena);
    sql.writeDatabase(dialect, d, &w.writer) catch return error.OutOfMemory;
    return w.written();
}
