//! Database connections. `Db` is the small interface that `migrate`,
//! `rollback` and `status` use; each database has a driver file behind it
//! (`postgres.zig`). The URL scheme picks both the driver and the SQL
//! dialect, so adding a database means adding a `Dialect`, a driver and a
//! scheme below.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sql = @import("../sql/root.zig");

pub const postgres = @import("postgres.zig");
pub const pg_dump = @import("pg_dump.zig");

pub const Dialect = sql.Dialect;

pub const Error = error{ DatabaseError, OutOfMemory };

/// Filled on `error.DatabaseError` with the database's message.
pub const Diagnostic = struct {
    message: []const u8 = "",
};

/// One row of a query result: each column as text, null for SQL `NULL`.
pub const Row = []const ?[]const u8;

pub const Db = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        exec: *const fn (ptr: *anyopaque, statement: []const u8, diag: *Diagnostic) Error!void,
        query: *const fn (ptr: *anyopaque, arena: Allocator, statement: []const u8, diag: *Diagnostic) Error![]const Row,
        server: *const fn (ptr: *anyopaque) Server,
        close: *const fn (ptr: *anyopaque) void,
    };

    /// Where the connection went, as the driver resolved it.
    pub const Server = struct {
        /// A host name, an address, or a Unix socket directory.
        host: []const u8,
        port: []const u8,
    };

    /// Runs one statement and discards any rows.
    pub fn exec(db: Db, statement: []const u8, diag: *Diagnostic) Error!void {
        return db.vtable.exec(db.ptr, statement, diag);
    }

    /// Runs one statement and returns its rows, allocated in `arena`.
    pub fn query(db: Db, arena: Allocator, statement: []const u8, diag: *Diagnostic) Error![]const Row {
        return db.vtable.query(db.ptr, arena, statement, diag);
    }

    /// Valid until `close`.
    pub fn server(db: Db) Server {
        return db.vtable.server(db.ptr);
    }

    pub fn close(db: Db) void {
        db.vtable.close(db.ptr);
    }
};

/// The dialect for a URL's scheme, or null if no driver handles it.
pub fn dialectFor(url: []const u8) ?Dialect {
    const schemes = [_]struct { []const u8, Dialect }{
        .{ "postgres://", .postgres },
        .{ "postgresql://", .postgres },
    };
    for (schemes) |s| if (std.ascii.startsWithIgnoreCase(url, s[0])) return s[1];
    return null;
}

/// Where `create`, `drop`, `protect` and `unprotect` connect to act on a
/// database.
pub const Admin = struct {
    /// The database the URL names.
    database: []const u8,
    /// The URL rewritten to name the dialect's maintenance database.
    url: []const u8,
};

pub const AdminError = error{ NoDatabaseName, OutOfMemory };

/// Splits `url` for the commands above. `error.NoDatabaseName` when the
/// URL does not name a database in its path.
pub fn admin(arena: Allocator, dialect: Dialect, url: []const u8) AdminError!Admin {
    return switch (dialect) {
        .postgres => postgres.admin(arena, url),
    };
}

/// Connects with the driver for `dialect`. Error messages and the
/// connection's own state are allocated in `arena`.
pub fn connect(arena: Allocator, dialect: Dialect, url: []const u8, diag: *Diagnostic) Error!Db {
    return switch (dialect) {
        .postgres => (try postgres.Connection.open(arena, url, diag)).db(),
    };
}
