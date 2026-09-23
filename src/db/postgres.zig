//! PostgreSQL driver on libpq. Declares the few libpq functions it needs
//! instead of translating `libpq-fe.h`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("root.zig");
const Db = root.Db;
const Diagnostic = root.Diagnostic;
const Error = root.Error;

const PGconn = opaque {};
const PGresult = opaque {};
const NoticeProcessor = *const fn (arg: ?*anyopaque, message: [*:0]const u8) callconv(.c) void;

// `ConnStatusType` and `ExecStatusType` values from `libpq-fe.h`.
const CONNECTION_OK = 0;
const PGRES_COMMAND_OK = 1;
const PGRES_TUPLES_OK = 2;

extern "pq" fn PQconnectdb(conninfo: [*:0]const u8) ?*PGconn;
extern "pq" fn PQstatus(conn: *const PGconn) c_int;
extern "pq" fn PQerrorMessage(conn: *const PGconn) [*:0]const u8;
extern "pq" fn PQhost(conn: *const PGconn) [*:0]const u8;
extern "pq" fn PQport(conn: *const PGconn) [*:0]const u8;
extern "pq" fn PQfinish(conn: *PGconn) void;
extern "pq" fn PQsetNoticeProcessor(conn: *PGconn, proc: NoticeProcessor, arg: ?*anyopaque) ?NoticeProcessor;
extern "pq" fn PQexec(conn: *PGconn, query: [*:0]const u8) ?*PGresult;
extern "pq" fn PQresultStatus(res: *const PGresult) c_int;
extern "pq" fn PQresultErrorMessage(res: *const PGresult) [*:0]const u8;
extern "pq" fn PQntuples(res: *const PGresult) c_int;
extern "pq" fn PQgetvalue(res: *const PGresult, row: c_int, column: c_int) [*:0]const u8;
extern "pq" fn PQclear(res: *PGresult) void;

pub const Connection = struct {
    conn: *PGconn,
    arena: Allocator,

    /// `url` is a `postgres://` or `postgresql://` URL, which libpq
    /// accepts as a connection string.
    pub fn open(arena: Allocator, url: []const u8, diag: *Diagnostic) Error!*Connection {
        const url_z = try arena.dupeZ(u8, url);
        const conn = PQconnectdb(url_z) orelse return error.OutOfMemory;
        errdefer PQfinish(conn);
        if (PQstatus(conn) != CONNECTION_OK) return fail(arena, PQerrorMessage(conn), diag);
        // By default libpq prints notices such as "relation already
        // exists, skipping" to stderr.
        _ = PQsetNoticeProcessor(conn, ignoreNotice, null);

        const c = try arena.create(Connection);
        c.* = .{ .conn = conn, .arena = arena };
        return c;
    }

    pub fn db(c: *Connection) Db {
        return .{ .ptr = c, .vtable = &vtable };
    }

    const vtable: Db.VTable = .{ .exec = exec, .query = query, .server = server, .close = close };

    fn exec(ptr: *anyopaque, statement: []const u8, diag: *Diagnostic) Error!void {
        const c: *Connection = @ptrCast(@alignCast(ptr));
        const res = try c.run(statement, diag);
        PQclear(res);
    }

    fn query(ptr: *anyopaque, arena: Allocator, statement: []const u8, diag: *Diagnostic) Error![]const []const u8 {
        const c: *Connection = @ptrCast(@alignCast(ptr));
        const res = try c.run(statement, diag);
        defer PQclear(res);
        const rows = try arena.alloc([]const u8, @intCast(PQntuples(res)));
        for (rows, 0..) |*row, i| row.* = try arena.dupe(u8, std.mem.span(PQgetvalue(res, @intCast(i), 0)));
        return rows;
    }

    fn server(ptr: *anyopaque) Db.Server {
        const c: *Connection = @ptrCast(@alignCast(ptr));
        return .{ .host = std.mem.span(PQhost(c.conn)), .port = std.mem.span(PQport(c.conn)) };
    }

    fn close(ptr: *anyopaque) void {
        const c: *Connection = @ptrCast(@alignCast(ptr));
        PQfinish(c.conn);
    }

    fn run(c: *Connection, statement: []const u8, diag: *Diagnostic) Error!*PGresult {
        const statement_z = try c.arena.dupeZ(u8, statement);
        defer c.arena.free(statement_z);
        const res = PQexec(c.conn, statement_z) orelse return fail(c.arena, PQerrorMessage(c.conn), diag);
        switch (PQresultStatus(res)) {
            PGRES_COMMAND_OK, PGRES_TUPLES_OK => return res,
            else => {
                defer PQclear(res);
                return fail(c.arena, PQresultErrorMessage(res), diag);
            },
        }
    }
};

/// Database that `create`, `drop`, `protect` and `unprotect` connect to,
/// since `create` and `drop` cannot run while connected to the database
/// they act on.
pub const maintenance_database = "postgres";

/// Splits `url` into the database its path names, percent-decoded, and
/// the same URL with the path replaced by `maintenance_database`. Query
/// parameters such as `host` are kept.
pub fn admin(arena: Allocator, url: []const u8) root.AdminError!root.Admin {
    const scheme_end = (std.mem.indexOf(u8, url, "://") orelse return error.NoDatabaseName) + "://".len;
    const path_start = std.mem.indexOfAnyPos(u8, url, scheme_end, "/?#") orelse return error.NoDatabaseName;
    if (url[path_start] != '/') return error.NoDatabaseName;
    const path_end = std.mem.indexOfAnyPos(u8, url, path_start, "?#") orelse url.len;
    // libpq lets a `dbname` parameter override the path.
    if (hasParam(url[path_end..], "dbname")) return error.NoDatabaseName;
    const database = std.Uri.percentDecodeInPlace(try arena.dupe(u8, url[path_start + 1 .. path_end]));
    if (database.len == 0) return error.NoDatabaseName;
    return .{
        .database = database,
        .url = try std.mem.concat(arena, u8, &.{ url[0 .. path_start + 1], maintenance_database, url[path_end..] }),
    };
}

/// Whether the `?a=b&c=d` query in `rest` sets `name`.
fn hasParam(rest: []const u8, name: []const u8) bool {
    if (rest.len == 0 or rest[0] != '?') return false;
    const query = rest[1 .. std.mem.indexOfScalar(u8, rest, '#') orelse rest.len];
    var params = std.mem.splitScalar(u8, query, '&');
    while (params.next()) |p| {
        const key = p[0 .. std.mem.indexOfScalar(u8, p, '=') orelse p.len];
        if (std.mem.eql(u8, key, name)) return true;
    }
    return false;
}

fn ignoreNotice(_: ?*anyopaque, _: [*:0]const u8) callconv(.c) void {}

/// Copies libpq's message into `diag`, without the `ERROR:  ` severity
/// prefix of statement errors or the trailing newline.
fn fail(arena: Allocator, message: [*:0]const u8, diag: *Diagnostic) Error {
    var m = std.mem.trimEnd(u8, std.mem.span(message), "\n");
    if (std.mem.startsWith(u8, m, "ERROR:")) m = std.mem.trimStart(u8, m["ERROR:".len..], " ");
    diag.message = try arena.dupe(u8, m);
    return error.DatabaseError;
}
